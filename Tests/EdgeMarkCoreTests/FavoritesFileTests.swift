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
