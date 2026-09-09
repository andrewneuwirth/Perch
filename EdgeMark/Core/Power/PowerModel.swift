import AppKit
import Foundation
import IOKit.pwr_mgt
import Observation

/// Sleep controls, in two halves that deliberately don't know about each other.
///
/// *Session* toggles hold IOKit power assertions — the same mechanism
/// `caffeinate -d` / `caffeinate -i` use, minus the subprocess. The kernel
/// releases them when Perch exits, so there is nothing to leak or orphan.
///
/// *Permanent* toggles are `pmset -a …`, which needs root. Those go through the
/// standard macOS authorisation dialog, and every write is followed by a fresh
/// read: what the toggle shows is what the system reports, never what we asked
/// for. Reading `pmset` needs no privileges and happens on appear.
@Observable
@MainActor
final class PowerModel {
    static let shared = PowerModel()

    // MARK: - Session assertions

    private(set) var keepDisplayAwake = false
    private(set) var keepSystemAwake = false

    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0

    // MARK: - Permanent settings

    private(set) var settings = PMSetSettings()
    private(set) var isReadingSettings = false
    private(set) var isApplying = false
    /// Set when a `pmset` write fails for a reason worth showing (not a
    /// cancelled password prompt, which is a normal thing to do).
    private(set) var lastError: String?

    private init() {}

    /// Re-arm whatever was on when Perch last quit, then read the real system
    /// state. Called once at launch.
    func restoreSessionAssertions(displayAwake: Bool, systemAwake: Bool) {
        setKeepDisplayAwake(displayAwake)
        setKeepSystemAwake(systemAwake)
    }

    // MARK: - Session toggles

    /// `caffeinate -d`: the display stays on. Lasts until it's switched off or
    /// Perch quits.
    func setKeepDisplayAwake(_ on: Bool) {
        keepDisplayAwake = apply(
            on,
            to: &displayAssertion,
            type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
            reason: "Perch: keep the display awake",
        )
    }

    /// `caffeinate -i`: the Mac keeps running, the display may still sleep.
    func setKeepSystemAwake(_ on: Bool) {
        keepSystemAwake = apply(
            on,
            to: &systemAssertion,
            type: kIOPMAssertionTypePreventUserIdleSystemSleep,
            reason: "Perch: keep the system awake",
        )
    }

    /// Create or release an assertion. Returns the state actually achieved, so
    /// a refused assertion leaves the toggle off rather than lying.
    private func apply(_ on: Bool, to id: inout IOPMAssertionID, type: String, reason: String) -> Bool {
        if on {
            guard id == 0 else { return true }
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &newID,
            )
            guard result == kIOReturnSuccess else {
                lastError = "The system refused to keep the Mac awake."
                return false
            }
            id = newID
            return true
        } else {
            if id != 0 {
                IOPMAssertionRelease(id)
                id = 0
            }
            return false
        }
    }

    // MARK: - Permanent settings

    /// Read the current `pmset` state. No privileges required, so this runs
    /// freely on appear and after every write.
    func refreshSettings() {
        guard !isReadingSettings else { return }
        isReadingSettings = true
        Task {
            let general = await Self.run("/usr/bin/pmset", ["-g"])
            let custom = await Self.run("/usr/bin/pmset", ["-g", "custom"])
            settings = PMSetOutput.parse(general: general ?? "", custom: custom ?? "")
            isReadingSettings = false
        }
    }

    /// `sudo pmset -a sleep 0`, and on the way back the timers that were there
    /// before it was switched on. The old behaviour wrote a flat `sleep 1`,
    /// which quietly turned a 15-minute battery timer into one minute — so the
    /// values are stashed at the moment the switch goes on and replayed
    /// per-source when it comes off.
    func setNeverSleep(_ on: Bool) async {
        if on {
            rememberCurrentSleepTimers()
            await runPrivileged(["pmset -a sleep 0"])
        } else {
            await runPrivileged(SleepRestore.commands(ac: rememberedACSleep, battery: rememberedBatterySleep))
            forgetRememberedSleepTimers()
        }
    }

    // MARK: - Remembering the timers we overwrote

    private static let acKey = "power.previousACSleepMinutes"
    private static let batteryKey = "power.previousBatterySleepMinutes"

    /// Only stash a reading we actually have. Storing a placeholder for an
    /// unreadable source would make the fallback impossible to tell apart from
    /// a real value of ten minutes.
    private func rememberCurrentSleepTimers() {
        let defaults = UserDefaults.standard
        if let ac = settings.acSleepMinutes { defaults.set(ac, forKey: Self.acKey) }
        if let battery = settings.batterySleepMinutes { defaults.set(battery, forKey: Self.batteryKey) }
    }

    private var rememberedACSleep: Int? {
        UserDefaults.standard.object(forKey: Self.acKey) as? Int
    }

    private var rememberedBatterySleep: Int? {
        UserDefaults.standard.object(forKey: Self.batteryKey) as? Int
    }

    /// Cleared once replayed, so a later read of a genuinely-never-sleeping Mac
    /// isn't overwritten by a stale value from months ago.
    private func forgetRememberedSleepTimers() {
        UserDefaults.standard.removeObject(forKey: Self.acKey)
        UserDefaults.standard.removeObject(forKey: Self.batteryKey)
    }

    /// `sudo pmset -a disablesleep 1` keeps the Mac awake with the lid shut;
    /// `0` restores normal clamshell behaviour.
    func setSleepOnLidClose(_ on: Bool) async {
        await runPrivileged(["pmset -a disablesleep \(on ? 0 : 1)"])
    }

    /// Run `pmset` as root through the standard macOS authorisation dialog,
    /// then re-read. A cancelled dialog is not an error — the toggle simply
    /// snaps back to what the system still reports.
    private func runPrivileged(_ commands: [String]) async {
        guard !isApplying else { return }
        isApplying = true
        defer { isApplying = false }

        let script = "do shell script \"\(commands.joined(separator: " ; "))\" with administrator privileges"
        let error = await Self.runAppleScript(script)
        if let error, !Self.isUserCancellation(error) {
            lastError = error
        }
        // Whatever happened, show what the system actually says now.
        refreshSettings()
    }

    func clearError() { lastError = nil }

    // MARK: - Process helpers

    /// -128 is `errAEWaitCanceled` — the user clicked Cancel on the password
    /// dialog, which is a decision, not a failure.
    private static func isUserCancellation(_ message: String) -> Bool {
        message.contains("-128")
    }

    private static func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            // NSAppleScript must run on the main thread.
            DispatchQueue.main.async {
                var errorInfo: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
                guard let errorInfo else { return continuation.resume(returning: nil) }
                let message = errorInfo[NSAppleScript.errorMessage] as? String
                let number = errorInfo[NSAppleScript.errorNumber] as? Int
                continuation.resume(returning: message ?? "Error \(number ?? 0)")
            }
        }
    }

    /// Run a tool and return stdout. `nil` if it couldn't be launched.
    private nonisolated static func run(_ path: String, _ arguments: [String]) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        }.value
    }
}
