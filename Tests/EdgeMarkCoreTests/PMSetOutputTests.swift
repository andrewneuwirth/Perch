@testable import PowerCore
import XCTest

/// Fixtures are verbatim `pmset -g` / `pmset -g custom` output from a MacBook
/// on AC with a battery, including the parenthesised "sleep prevented by …"
/// tail that a naive split would choke on.
final class PMSetOutputTests: XCTestCase {

    private let general = """
    System-wide power settings:
     SleepDisabled\t\t0
    Currently in use:
     standby              1
     Sleep On Power Button 1
     hibernatefile        /var/vm/sleepimage
     powernap             1
     disksleep            0
     sleep                0 (sleep prevented by coreaudiod, powerd, caffeinate, Google Chrome)
     hibernatemode        3
     displaysleep         10
     womp                 1
    """

    private let custom = """
    Battery Power:
     Sleep On Power Button 1
     hibernatemode        3
     hibernatefile        /var/vm/sleepimage
     displaysleep         10
     sleep                15
     lessbright           1
     disksleep            0
    AC Power:
     Sleep On Power Button 1
     hibernatemode        3
     hibernatefile        /var/vm/sleepimage
     displaysleep         10
     sleep                0
     disksleep            0
    """

    func testReadsPerSourceSleepTimers() {
        let s = PMSetOutput.parse(general: general, custom: custom)
        XCTAssertEqual(s.batterySleepMinutes, 15)
        XCTAssertEqual(s.acSleepMinutes, 0)
        XCTAssertEqual(s.batteryDisplaySleepMinutes, 10)
        XCTAssertEqual(s.acDisplaySleepMinutes, 10)
    }

    func testSleepDisabledFlag() {
        XCTAssertFalse(PMSetOutput.parse(general: general, custom: custom).sleepDisabled)
        let on = general.replacingOccurrences(of: "SleepDisabled\t\t0", with: "SleepDisabled\t\t1")
        XCTAssertTrue(PMSetOutput.parse(general: on, custom: custom).sleepDisabled)
    }

    /// "sleep 0 (sleep prevented by …)" must not leak the parenthesised tail
    /// into the value, and the general section must not be read as a source.
    func testParentheticalTailIsIgnored() {
        let s = PMSetOutput.parse(general: general, custom: custom)
        XCTAssertEqual(s.acSleepMinutes, 0)
    }

    /// Only "never sleeps" when every source we could read says 0. AC alone
    /// at 0 while the battery sleeps after 15 minutes is not never-sleeps.
    func testNeverSleepsRequiresEverySource() {
        XCTAssertFalse(PMSetOutput.parse(general: general, custom: custom).neverSleeps)

        let bothZero = custom.replacingOccurrences(of: " sleep                15", with: " sleep                0")
        XCTAssertTrue(PMSetOutput.parse(general: general, custom: bothZero).neverSleeps)
    }

    /// A machine whose settings we could not read is not "never sleeps".
    func testUnreadableSettingsAreNotNeverSleeps() {
        let s = PMSetOutput.parse(general: "", custom: "")
        XCTAssertNil(s.acSleepMinutes)
        XCTAssertNil(s.batterySleepMinutes)
        XCTAssertFalse(s.neverSleeps)
        XCTAssertFalse(s.sleepDisabled)
    }

    /// Keys with spaces ("Sleep On Power Button") are skipped, not misparsed.
    func testMultiWordKeysAreSkipped() {
        let s = PMSetOutput.parse(general: general, custom: custom)
        XCTAssertEqual(s.acSleepMinutes, 0)
        XCTAssertEqual(s.acDisplaySleepMinutes, 10)
    }
}

final class SleepRestoreTests: XCTestCase {

    /// The bug this replaces: switching "never sleep" off wrote a flat
    /// `pmset -a sleep 1`, turning a 15-minute battery timer into one minute.
    func testRestoresTheTimersThatWereThere() {
        XCTAssertEqual(
            SleepRestore.commands(ac: 0, battery: 15),
            ["pmset -c sleep 0", "pmset -b sleep 15"],
        )
    }

    /// Per-source, so a Mac that slept at different intervals on power and
    /// battery keeps the difference instead of being flattened by `-a`.
    func testWritesEachPowerSourceSeparately() {
        let commands = SleepRestore.commands(ac: 30, battery: 5)
        XCTAssertTrue(commands.contains("pmset -c sleep 30"))
        XCTAssertTrue(commands.contains("pmset -b sleep 5"))
        XCTAssertFalse(commands.contains { $0.contains("-a") })
    }

    /// A source we never read falls back to macOS's own default, and only
    /// that source — a known value beside it is still honoured.
    func testUnreadableSourceFallsBackWithoutDisturbingTheOther() {
        XCTAssertEqual(
            SleepRestore.commands(ac: nil, battery: 15),
            ["pmset -c sleep \(SleepRestore.fallbackMinutes)", "pmset -b sleep 15"],
        )
        XCTAssertEqual(
            SleepRestore.commands(ac: nil, battery: nil),
            ["pmset -c sleep \(SleepRestore.fallbackMinutes)", "pmset -b sleep \(SleepRestore.fallbackMinutes)"],
        )
    }

    /// A source that already never slept is remembered as 0, not treated as
    /// missing — putting it back to ten minutes would change a setting the
    /// user never asked us to touch.
    func testZeroIsARealValueNotAMissingOne() {
        let remembered = SleepRestore.timersWorthRemembering(ac: 0, battery: 0)
        XCTAssertEqual(remembered.ac, 0)
        XCTAssertEqual(remembered.battery, 0)
        XCTAssertEqual(SleepRestore.commands(ac: remembered.ac, battery: remembered.battery),
                       ["pmset -c sleep 0", "pmset -b sleep 0"])
    }

    /// End to end on this machine's real numbers: AC never, battery 15.
    func testRoundTripFromParsedSettings() {
        let parsed = PMSetOutput.parse(
            general: "System-wide power settings:\n SleepDisabled\t\t0",
            custom: "Battery Power:\n sleep                15\nAC Power:\n sleep                0",
        )
        let remembered = SleepRestore.timersWorthRemembering(ac: parsed.acSleepMinutes, battery: parsed.batterySleepMinutes)
        XCTAssertEqual(SleepRestore.commands(ac: remembered.ac, battery: remembered.battery),
                       ["pmset -c sleep 0", "pmset -b sleep 15"])
    }
}

final class SleepPresetTests: XCTestCase {

    /// The overnight case the whole preset exists for: the machine keeps
    /// working, the screen is allowed to go dark on its own timer.
    func testOvernightKeepsTheMachineUpAndLetsTheScreenSleep() {
        XCTAssertTrue(SleepPreset.overnight.keepSystemAwake)
        XCTAssertFalse(SleepPreset.overnight.keepDisplayAwake)
    }

    func testScreenOnHoldsBoth() {
        XCTAssertTrue(SleepPreset.screenOn.keepSystemAwake)
        XCTAssertTrue(SleepPreset.screenOn.keepDisplayAwake)
    }

    func testNormalHoldsNothing() {
        XCTAssertFalse(SleepPreset.normal.keepSystemAwake)
        XCTAssertFalse(SleepPreset.normal.keepDisplayAwake)
    }

    /// Round-trips, so selecting a preset and reading the assertions back
    /// lands on the same preset.
    func testEveryPresetRoundTrips() {
        for preset in SleepPreset.allCases {
            XCTAssertEqual(
                SleepPreset.matching(keepSystemAwake: preset.keepSystemAwake, keepDisplayAwake: preset.keepDisplayAwake),
                preset,
                "\(preset.rawValue) did not round-trip",
            )
        }
    }

    /// A held display assertion keeps the system awake as a side effect, so
    /// display-only is the same situation as screenOn, not a fourth state.
    func testDisplayHeldAloneReadsAsScreenOn() {
        XCTAssertEqual(SleepPreset.matching(keepSystemAwake: false, keepDisplayAwake: true), .screenOn)
    }

    func testMatchingIsTotal() {
        XCTAssertEqual(SleepPreset.matching(keepSystemAwake: false, keepDisplayAwake: false), .normal)
        XCTAssertEqual(SleepPreset.matching(keepSystemAwake: true, keepDisplayAwake: false), .overnight)
        XCTAssertEqual(SleepPreset.matching(keepSystemAwake: true, keepDisplayAwake: true), .screenOn)
    }
}
