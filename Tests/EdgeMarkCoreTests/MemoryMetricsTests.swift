@testable import MemoryCore
import XCTest

final class MemoryMetricsTests: XCTestCase {

    // MARK: - App names

    func testOutermostBundleWins() {
        // Chrome's renderers are nested .app bundles inside the browser. The
        // row should say "Google Chrome", not "Google Chrome Helper (Renderer)".
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/141/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        XCTAssertEqual(MemoryMetrics.appName(forExecutablePath: path), "Google Chrome")
        XCTAssertEqual(MemoryMetrics.processName(forExecutablePath: path), "Google Chrome Helper (Renderer)")
    }

    func testPlainBundle() {
        let path = "/Applications/Perch.app/Contents/MacOS/Perch"
        XCTAssertEqual(MemoryMetrics.appName(forExecutablePath: path), "Perch")
    }

    func testBinaryWithNoBundleIsItsOwnApp() {
        // Claude Code runs from a versioned directory with no .app anywhere on
        // the path, so the version number is genuinely the executable's name.
        let path = "/Users/someone/.local/share/claude/versions/2.1.266"
        XCTAssertEqual(MemoryMetrics.appName(forExecutablePath: path), "2.1.266")
        XCTAssertEqual(MemoryMetrics.processName(forExecutablePath: path), "2.1.266")
    }

    func testDaemonPath() {
        XCTAssertEqual(MemoryMetrics.appName(forExecutablePath: "/usr/libexec/keybagd"), "keybagd")
    }

    // MARK: - Grouping

    private func proc(_ pid: Int32, _ name: String, _ app: String, _ footprint: Int64) -> ProcessMemory {
        ProcessMemory(pid: pid, name: name, appName: app, footprint: footprint)
    }

    func testProcessesCollapseIntoOneRowPerApp() {
        let apps = MemoryMetrics.group([
            proc(1, "Chrome", "Google Chrome", 300),
            proc(2, "Chrome Helper", "Google Chrome", 200),
            proc(3, "Perch", "Perch", 100),
        ])
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps.map(\.appName), ["Google Chrome", "Perch"])
    }

    func testAppFootprintIsTheSumOfItsProcesses() {
        let apps = MemoryMetrics.group([
            proc(1, "Chrome", "Google Chrome", 300),
            proc(2, "Chrome Helper", "Google Chrome", 200),
        ])
        XCTAssertEqual(apps.first?.footprint, 500)
    }

    func testHeaviestAppFirstAndHeaviestProcessFirstWithinIt() {
        let apps = MemoryMetrics.group([
            proc(1, "Small", "Light App", 10),
            proc(2, "Helper", "Heavy App", 200),
            proc(3, "Main", "Heavy App", 900),
        ])
        XCTAssertEqual(apps.map(\.appName), ["Heavy App", "Light App"])
        XCTAssertEqual(apps.first?.processes.map(\.name), ["Main", "Helper"])
    }

    func testEqualFootprintsSortByNameSoRowsDontJitterBetweenSamples() {
        let apps = MemoryMetrics.group([
            proc(1, "b", "Beta", 100),
            proc(2, "a", "Alpha", 100),
        ])
        XCTAssertEqual(apps.map(\.appName), ["Alpha", "Beta"])
    }

    /// A single-process app has nothing to expand into.
    func testSingleProcessAppIsNotExpandable() {
        let apps = MemoryMetrics.group([proc(1, "Perch", "Perch", 100)])
        XCTAssertEqual(apps.first?.isExpandable, false)
    }

    func testMultiProcessAppIsExpandable() {
        let apps = MemoryMetrics.group([
            proc(1, "Chrome", "Google Chrome", 300),
            proc(2, "Chrome Helper", "Google Chrome", 200),
        ])
        XCTAssertEqual(apps.first?.isExpandable, true)
    }

    func testEmptySampleGroupsToNothing() {
        XCTAssertTrue(MemoryMetrics.group([]).isEmpty)
    }
}
