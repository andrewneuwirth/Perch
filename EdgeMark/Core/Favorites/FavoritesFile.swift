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

/// Reordering rules for the links list. Pure so drag-to-reorder and the
/// Move Up / Move Down menu items share one definition of "moved", and so the
/// edge cases can be pinned by tests rather than discovered by dragging.
enum FavoriteOrder {

    /// Put the item with `id` at `index`, clamped into range. Unknown ids and
    /// no-op moves return the list untouched, so callers can compare and skip
    /// a pointless write to disk.
    static func moved(_ items: [Favorite], id: UUID, to index: Int) -> [Favorite] {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return items }
        let to = max(0, min(index, items.count - 1))
        guard from != to else { return items }
        var out = items
        out.insert(out.remove(at: from), at: to)
        return out
    }

    /// One step up (-1) or down (+1). Stops at the ends rather than wrapping.
    static func moved(_ items: [Favorite], id: UUID, by direction: Int) -> [Favorite] {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return items }
        let to = from + direction
        guard items.indices.contains(to) else { return items }
        var out = items
        out.swapAt(from, to)
        return out
    }
}
