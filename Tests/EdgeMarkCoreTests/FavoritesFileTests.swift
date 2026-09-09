@testable import FavoritesCore
import XCTest

final class FavoritesFileTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(FavoriteURL.normalize("example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(FavoriteURL.normalize("  https://a.b/c?d=1 ")?.absoluteString, "https://a.b/c?d=1")
        XCTAssertEqual(FavoriteURL.normalize("http://localhost:3000")?.absoluteString, "http://localhost:3000")
        XCTAssertNil(FavoriteURL.normalize(""))
        XCTAssertNil(FavoriteURL.normalize("not a url"))
        XCTAssertNil(FavoriteURL.normalize("justtext"))
    }

    func testDefaultTitleStripsWWW() {
        XCTAssertEqual(FavoriteURL.defaultTitle(for: URL(string: "https://www.github.com/x")!), "github.com")
        XCTAssertEqual(FavoriteURL.defaultTitle(for: URL(string: "https://docs.rs")!), "docs.rs")
    }

    func testEncodeDecodeRoundTrip() throws {
        let file = FavoritesFile(items: [
            Favorite(title: "GitHub", url: URL(string: "https://github.com")!, createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ])
        let data = try file.encode()
        let decoded = try FavoritesFile.decode(data)
        XCTAssertEqual(decoded, file)
        XCTAssertEqual(decoded.version, 1)
    }
}

final class FavoriteOrderTests: XCTestCase {
    private func favs(_ n: Int) -> [Favorite] {
        (0 ..< n).map { Favorite(title: "\($0)", url: URL(string: "https://\($0).com")!) }
    }

    func testMoveToIndex() {
        let items = favs(4)
        let out = FavoriteOrder.moved(items, id: items[3].id, to: 0)
        XCTAssertEqual(out.map(\.title), ["3", "0", "1", "2"])
    }

    func testMoveToIndexClampsInsteadOfCrashing() {
        let items = favs(3)
        XCTAssertEqual(FavoriteOrder.moved(items, id: items[0].id, to: 99).map(\.title), ["1", "2", "0"])
        XCTAssertEqual(FavoriteOrder.moved(items, id: items[2].id, to: -5).map(\.title), ["2", "0", "1"])
    }

    /// Drag-to-reorder calls this for every row the cursor crosses, so a move
    /// that changes nothing must be recognisable as a no-op and not written.
    func testNoOpMoveReturnsAnEqualList() {
        let items = favs(3)
        XCTAssertEqual(FavoriteOrder.moved(items, id: items[1].id, to: 1), items)
        XCTAssertEqual(FavoriteOrder.moved(items, id: UUID(), to: 0), items)
        XCTAssertEqual(FavoriteOrder.moved(items, id: UUID(), by: -1), items)
    }

    func testStepUpAndDown() {
        let items = favs(3)
        XCTAssertEqual(FavoriteOrder.moved(items, id: items[2].id, by: -1).map(\.title), ["0", "2", "1"])
        XCTAssertEqual(FavoriteOrder.moved(items, id: items[0].id, by: 1).map(\.title), ["1", "0", "2"])
    }

    func testStepStopsAtTheEndsRatherThanWrapping() {
        let items = favs(3)
        XCTAssertEqual(FavoriteOrder.moved(items, id: items[0].id, by: -1), items)
        XCTAssertEqual(FavoriteOrder.moved(items, id: items[2].id, by: 1), items)
    }
}
