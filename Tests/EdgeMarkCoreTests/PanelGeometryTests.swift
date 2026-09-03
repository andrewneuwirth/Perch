@testable import PanelGeometryCore
import XCTest

final class PanelGeometryTests: XCTestCase {
    let vf = CGRect(x: 0, y: 0, width: 1440, height: 875)

    func testFullHeightNoInset() {
        let f = PanelGeometry.frames(visibleFrame: vf, side: .right, width: 400, height: nil, bottomInset: 0)
        XCTAssertEqual(f.shown, CGRect(x: 1040, y: 0, width: 400, height: 875))
        XCTAssertEqual(f.hidden, CGRect(x: 1440, y: 0, width: 400, height: 875))
    }

    func testFullHeightWithInsetSitsAboveButton() {
        let f = PanelGeometry.frames(visibleFrame: vf, side: .left, width: 400, height: nil, bottomInset: 60)
        XCTAssertEqual(f.shown, CGRect(x: 0, y: 60, width: 400, height: 815))
        XCTAssertEqual(f.hidden, CGRect(x: -400, y: 60, width: 400, height: 815))
    }

    func testCustomHeightIncludesInset() {
        let f = PanelGeometry.frames(visibleFrame: vf, side: .right, width: 400, height: 500, bottomInset: 60)
        XCTAssertEqual(f.shown.height, 440)
        XCTAssertEqual(f.shown.minY, 60)
    }

    func testHeightClampsToScreenAndMinimum() {
        XCTAssertEqual(PanelGeometry.resolvedHeight(visibleFrame: vf, height: 5000, bottomInset: 0), 875)
        XCTAssertEqual(PanelGeometry.resolvedHeight(visibleFrame: vf, height: 100, bottomInset: 0), PanelGeometry.minHeight)
    }

    func testStoredHeightAfterDragSnapsToFull() {
        XCTAssertNil(PanelGeometry.storedHeightAfterDrag(frameTop: 870, frameHeight: 810, visibleFrame: vf, bottomInset: 60))
        XCTAssertEqual(PanelGeometry.storedHeightAfterDrag(frameTop: 500, frameHeight: 440, visibleFrame: vf, bottomInset: 60), 500)
    }

    func testClampedDragHeight() {
        XCTAssertEqual(PanelGeometry.clampedDragHeight(10, frameMinY: 60, visibleFrame: vf), PanelGeometry.minHeight)
        XCTAssertEqual(PanelGeometry.clampedDragHeight(2000, frameMinY: 60, visibleFrame: vf), 815)
        XCTAssertEqual(PanelGeometry.clampedDragHeight(500, frameMinY: 60, visibleFrame: vf), 500)
    }
}
