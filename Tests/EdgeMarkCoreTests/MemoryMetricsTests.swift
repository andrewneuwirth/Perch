@testable import MemoryCore
import XCTest

final class MemoryPressureTests: XCTestCase {
    /// The sysctl reports 1 / 2 / 4. Anything else means "we don't know",
    /// which must read as normal — a machine we can't measure is not in
    /// trouble, and colouring it red would cry wolf.
    func testKnownLevels() {
        XCTAssertEqual(MemoryPressure(rawLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(rawLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(rawLevel: 4), .critical)
    }

    func testUnknownLevelsReadAsNormal() {
        for level: Int32 in [0, 3, 5, -1, 99] {
            XCTAssertEqual(MemoryPressure(rawLevel: level), .normal, "level \(level)")
        }
    }
}

final class MemorySnapshotTests: XCTestCase {
    private let page: Int64 = 16384

    private func counters(internalP: Int64 = 0, purgeable: Int64 = 0, wire: Int64 = 0, compressor: Int64 = 0, external: Int64 = 0) -> VMCounters {
        VMCounters(pageSize: page, internalPages: internalP, purgeablePages: purgeable, wirePages: wire, compressorPages: compressor, externalPages: external)
    }

    func testAppMemoryExcludesPurgeablePages() {
        let s = MemorySnapshot(total: 100 * page, counters: counters(internalP: 40, purgeable: 10), swapUsed: 0, pressure: .normal)
        XCTAssertEqual(s.app, 30 * page)
    }

    /// Purgeable is a subset of internal, but the two counters are sampled
    /// independently, so the subtraction can go negative between reads.
    func testAppMemoryClampsAtZero() {
        let s = MemorySnapshot(total: 100 * page, counters: counters(internalP: 5, purgeable: 20), swapUsed: 0, pressure: .normal)
        XCTAssertEqual(s.app, 0)
    }

    func testCachedCountsFileBackedAndPurgeable() {
        let s = MemorySnapshot(total: 100 * page, counters: counters(purgeable: 10, external: 25), swapUsed: 0, pressure: .normal)
        XCTAssertEqual(s.cached, 35 * page)
    }

    func testUsedIsAppPlusWiredPlusCompressedAndExcludesCache() {
        let s = MemorySnapshot(
            total: 100 * page,
            counters: counters(internalP: 30, purgeable: 0, wire: 10, compressor: 5, external: 40),
            swapUsed: 0,
            pressure: .normal,
        )
        XCTAssertEqual(s.used, 45 * page)
    }

    func testUsedFraction() {
        let s = MemorySnapshot(total: 100 * page, counters: counters(internalP: 25), swapUsed: 0, pressure: .normal)
        XCTAssertEqual(s.usedFraction, 0.25, accuracy: 0.0001)
    }

    func testUsedFractionNeverExceedsOne() {
        let s = MemorySnapshot(total: 10 * page, counters: counters(internalP: 40), swapUsed: 0, pressure: .normal)
        XCTAssertEqual(s.usedFraction, 1.0)
    }

    func testUnknownTotalDoesNotDivideByZero() {
        let s = MemorySnapshot(total: 0, counters: counters(internalP: 40), swapUsed: 0, pressure: .normal)
        XCTAssertEqual(s.usedFraction, 0)
    }

    /// Swap in use is worth showing, but it is not by itself a problem — macOS
    /// swaps as a matter of course. Only `pressure` says whether to worry.
    func testSwapIsReportedNotJudged() {
        let s = MemorySnapshot(total: 100 * page, counters: counters(internalP: 20), swapUsed: 2_000_000_000, pressure: .normal)
        XCTAssertEqual(s.swapUsed, 2_000_000_000)
        XCTAssertEqual(s.pressure, .normal)
    }
}

final class ProcessGroupingTests: XCTestCase {

    // MARK: - App names

    func testOutermostBundleWins() {
        // Chrome's renderers are nested .app bundles inside the browser. The
        // row should say "Google Chrome", not the helper's own bundle name.
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/141/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        XCTAssertEqual(ProcessGrouping.appName(forExecutablePath: path), "Google Chrome")
    }

    func testPlainBundle() {
        XCTAssertEqual(ProcessGrouping.appName(forExecutablePath: "/Applications/Perch.app/Contents/MacOS/Perch"), "Perch")
    }

    func testExecutableOutsideAnyBundleStandsForItself() {
        // Claude Code runs from a versioned directory with no .app on the path,
        // so the version number genuinely is the executable's name.
        XCTAssertEqual(ProcessGrouping.appName(forExecutablePath: "/Users/someone/.local/share/claude/versions/2.1.266"), "2.1.266")
        XCTAssertEqual(ProcessGrouping.appName(forExecutablePath: "/usr/libexec/keybagd"), "keybagd")
    }

    // MARK: - Grouping

    private func proc(_ pid: Int32, _ name: String, _ app: String, _ footprint: Int64) -> ProcessMemory {
        ProcessMemory(pid: pid, name: name, appName: app, footprint: footprint)
    }

    func testProcessesCollapseIntoOneRowPerApp() {
        let apps = ProcessGrouping.group([
            proc(1, "Chrome", "Google Chrome", 300),
            proc(2, "Chrome Helper", "Google Chrome", 200),
            proc(3, "Perch", "Perch", 100),
        ])
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps.map(\.name), ["Google Chrome", "Perch"])
    }

    func testAppFootprintIsTheSumOfItsProcesses() {
        let apps = ProcessGrouping.group([
            proc(1, "Chrome", "Google Chrome", 300),
            proc(2, "Chrome Helper", "Google Chrome", 200),
        ])
        XCTAssertEqual(apps.first?.footprint, 500)
    }

    func testHeaviestAppFirstAndHeaviestProcessFirstWithinIt() {
        let apps = ProcessGrouping.group([
            proc(1, "Small", "Light App", 10),
            proc(2, "Helper", "Heavy App", 200),
            proc(3, "Main", "Heavy App", 900),
        ])
        XCTAssertEqual(apps.map(\.name), ["Heavy App", "Light App"])
        XCTAssertEqual(apps.first?.processes.map(\.name), ["Main", "Helper"])
    }

    /// A single-process app has nothing to expand into.
    func testSingleProcessAppIsNotExpandable() {
        XCTAssertEqual(ProcessGrouping.group([proc(1, "Perch", "Perch", 100)]).first?.isExpandable, false)
    }

    func testMultiProcessAppIsExpandable() {
        let apps = ProcessGrouping.group([
            proc(1, "Chrome", "Google Chrome", 300),
            proc(2, "Chrome Helper", "Google Chrome", 200),
        ])
        XCTAssertEqual(apps.first?.isExpandable, true)
    }

    func testEmptySampleGroupsToNothing() {
        XCTAssertTrue(ProcessGrouping.group([]).isEmpty)
    }
}
