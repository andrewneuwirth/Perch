import Foundation

struct Favorite: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var url: URL
    var createdAt = Date()
}

/// On-disk shape of `.edgemark/favorites.json`. Pure Foundation so it is unit-testable.
struct FavoritesFile: Codable, Equatable {
    var version = 1
    var items: [Favorite] = []

    static func decode(_ data: Data) throws -> FavoritesFile {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(FavoritesFile.self, from: data)
    }

    func encode() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }
}

enum FavoriteURL {
    /// Turn user input into a URL. Adds `https://` when no scheme is present. Returns nil for junk.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") {
            s = "https://" + s
        }
        guard let url = URL(string: s), let host = url.host, host.contains(".") || host == "localhost" else { return nil }
        return url
    }

    /// Host without a leading "www." — the default favorite title.
    static func defaultTitle(for url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
