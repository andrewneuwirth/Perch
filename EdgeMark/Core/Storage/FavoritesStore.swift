import AppKit
import Foundation
import OSLog

/// Observable list of favorite links persisted to `.edgemark/favorites.json`
/// inside the notes storage directory.
@Observable
final class FavoritesStore {
    static let shared = FavoritesStore()

    private(set) var items: [Favorite] = []

    var fileURL: URL {
        FileStorage.rootURL
            .appendingPathComponent(".edgemark", isDirectory: true)
            .appendingPathComponent("favorites.json")
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            items = []
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            items = try FavoritesFile.decode(data).items
            Log.storage.info("[Favorites] loaded \(self.items.count) favorites")
        } catch {
            Log.storage.error("[Favorites] load failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FavoritesFile(items: items).encode().write(to: fileURL, options: .atomic)
        } catch {
            Log.storage.error("[Favorites] save failed — \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Add from raw user input. Returns nil if the input isn't a usable URL.
    @discardableResult
    func add(rawURL: String, title: String? = nil) -> Favorite? {
        guard let url = FavoriteURL.normalize(rawURL) else { return nil }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespaces) ?? ""
        let fav = Favorite(title: trimmedTitle.isEmpty ? FavoriteURL.defaultTitle(for: url) : trimmedTitle, url: url)
        items.append(fav)
        save()
        return fav
    }

    func rename(id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        items[i].title = t.isEmpty ? FavoriteURL.defaultTitle(for: items[i].url) : t
        save()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// direction: -1 = up, +1 = down
    func move(id: UUID, direction: Int) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let target = i + direction
        guard items.indices.contains(target) else { return }
        items.swapAt(i, target)
        save()
    }

    func open(_ favorite: Favorite) {
        NSWorkspace.shared.open(favorite.url)
    }

    /// URL currently on the pasteboard, if any — used to pre-fill the add field.
    static func pasteboardURL() -> URL? {
        let pb = NSPasteboard.general
        if let url = pb.readObjects(forClasses: [NSURL.self])?.first as? URL, url.scheme?.hasPrefix("http") == true {
            return url
        }
        if let s = pb.string(forType: .string), let url = FavoriteURL.normalize(s), s.contains(".") {
            return url
        }
        return nil
    }
}
