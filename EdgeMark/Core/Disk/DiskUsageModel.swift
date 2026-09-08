import Foundation
import Observation

/// Disk-space hog finder. Deliberately does NO background work: the footer
/// pill only reads free space (one `statfs`, microseconds), and the heavy
/// directory walks run only while `DiskView` is on screen — `scan()` on
/// appear, `cancel()` on disappear. Nothing polls, nothing runs when the
/// panel is closed.
@Observable
@MainActor
final class DiskUsageModel {

    // MARK: - Volume

    struct VolumeInfo: Equatable {
        let total: Int64
        let free: Int64
        var used: Int64 { max(total - free, 0) }
        var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
        /// Free space is getting tight — the pill turns red.
        var isLow: Bool { total > 0 && Double(free) / Double(total) < 0.10 }
    }

    /// Free/total for the boot volume. Cheap enough to call on every appear.
    static func volumeInfo() -> VolumeInfo? {
        let url = URL(fileURLWithPath: "/")
        guard let v = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]),
            let total = v.volumeTotalCapacity,
            let free = v.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return VolumeInfo(total: Int64(total), free: free)
    }

    // MARK: - Targets

    /// How much it hurts to delete this.
    enum Risk {
        /// Pure cache — regenerated silently next time it's needed.
        case safe
        /// Regenerates, but costs time or a download (archives, model caches).
        case caution
        /// Real data goes away (simulator contents, Docker disk).
        case destructive
        /// Show the size, never offer to delete the folder itself (Downloads).
        case viewOnly
    }

    struct Target: Identifiable, Hashable {
        var id: String { url.path }
        let name: String
        let detail: String
        let icon: String
        let url: URL
        let risk: Risk
        /// Delete only what's inside, keep the folder (DerivedData, ~/Library/Caches).
        let deletesContents: Bool

        static func == (a: Target, b: Target) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    private static func home(_ rel: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rel)
    }

    /// Curated, disjoint list of the usual suspects on a dev Mac. Paths that
    /// don't exist on this machine are hidden from the list.
    static let knownTargets: [Target] = [
        Target(name: "Xcode DerivedData", detail: "Build cache · rebuilds on next build",
               icon: "hammer", url: home("Library/Developer/Xcode/DerivedData"), risk: .safe, deletesContents: true),
        Target(name: "Xcode Archives", detail: "Archived builds · needed to symbolicate old crash logs",
               icon: "archivebox", url: home("Library/Developer/Xcode/Archives"), risk: .caution, deletesContents: true),
        Target(name: "iOS DeviceSupport", detail: "Symbols per iOS version · re-downloads when a device connects",
               icon: "iphone", url: home("Library/Developer/Xcode/iOS DeviceSupport"), risk: .safe, deletesContents: true),
        Target(name: "Xcode Previews", detail: "SwiftUI preview cache",
               icon: "eye", url: home("Library/Developer/Xcode/UserData/Previews"), risk: .safe, deletesContents: true),
        Target(name: "Simulator caches", detail: "Runtime caches · safe",
               icon: "square.stack.3d.up", url: home("Library/Developer/CoreSimulator/Caches"), risk: .safe, deletesContents: true),
        Target(name: "Simulators", detail: "Every simulator's data — apps, settings, photos",
               icon: "ipad.and.iphone", url: home("Library/Developer/CoreSimulator/Devices"), risk: .destructive, deletesContents: true),
        Target(name: "App caches", detail: "~/Library/Caches · apps rebuild what they need",
               icon: "tray.full", url: home("Library/Caches"), risk: .caution, deletesContents: true),
        Target(name: "Logs", detail: "~/Library/Logs",
               icon: "doc.text", url: home("Library/Logs"), risk: .safe, deletesContents: true),
        Target(name: "npm cache", detail: "Package tarballs · re-downloads",
               icon: "shippingbox", url: home(".npm/_cacache"), risk: .safe, deletesContents: true),
        Target(name: "Cargo registry", detail: "Rust crate sources · re-downloads",
               icon: "shippingbox", url: home(".cargo/registry"), risk: .safe, deletesContents: true),
        Target(name: "Gradle caches", detail: "Android build deps · re-downloads",
               icon: "shippingbox", url: home(".gradle/caches"), risk: .safe, deletesContents: true),
        Target(name: "Hugging Face cache", detail: "Downloaded models · large re-downloads",
               icon: "brain", url: home(".cache/huggingface"), risk: .caution, deletesContents: true),
        Target(name: "Ollama models", detail: "Local LLM weights · large re-downloads",
               icon: "brain", url: home(".ollama/models"), risk: .caution, deletesContents: true),
        Target(name: "Docker disk", detail: "All images, containers and volumes",
               icon: "shippingbox.fill", url: home("Library/Containers/com.docker.docker/Data/vms/0/data"), risk: .destructive, deletesContents: true),
        Target(name: "Trash", detail: "Emptying frees the space immediately",
               icon: "trash", url: home(".Trash"), risk: .safe, deletesContents: true),
        Target(name: "Downloads", detail: "Expand to find the big ones",
               icon: "arrow.down.circle", url: home("Downloads"), risk: .viewOnly, deletesContents: false),
    ]

    // MARK: - Items

    enum SizeState: Equatable {
        case pending
        case scanning
        case done(Int64)
        case failed

        var bytes: Int64? { if case let .done(b) = self { return b }; return nil }
    }

    struct Item: Identifiable {
        let id: String
        let name: String
        let detail: String?
        let icon: String
        let url: URL
        let risk: Risk
        let deletesContents: Bool
        let isDirectory: Bool
        var size: SizeState = .pending
        var isExpanded = false
        var children: [Item]? = nil
        var isLoadingChildren = false

        init(target: Target) {
            id = target.id
            name = target.name
            detail = target.detail
            icon = target.icon
            url = target.url
            risk = target.risk
            deletesContents = target.deletesContents
            isDirectory = true
        }

        init(childOf parent: Item, url: URL, isDirectory: Bool) {
            id = url.path
            name = url.lastPathComponent
            detail = nil
            icon = isDirectory ? "folder" : "doc"
            self.url = url
            // Children inherit the parent's risk, except view-only parents
            // (Downloads) whose files you clearly do want to be able to kill.
            risk = parent.risk == .viewOnly ? .caution : parent.risk
            deletesContents = false
            self.isDirectory = isDirectory
        }
    }

    private(set) var volume: VolumeInfo?
    private(set) var items: [Item] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?

    private var scanTask: Task<Void, Never>?
    private var childTasks: [String: Task<Void, Never>] = [:]

    init() {
        refreshVolume()
    }

    func refreshVolume() {
        volume = Self.volumeInfo()
    }

    /// Total of everything measured so far — "what these folders are eating".
    var measuredTotal: Int64 {
        items.compactMap { $0.size.bytes }.reduce(0, +)
    }

    // MARK: - Scanning

    /// Walk every known target that exists. Cancels any scan in flight.
    func scan() {
        cancel()
        refreshVolume()
        let fm = FileManager.default
        items = Self.knownTargets
            .filter { fm.fileExists(atPath: $0.url.path) }
            .map(Item.init(target:))
        isScanning = true
        let urls = items.map(\.url)

        scanTask = Task { [weak self] in
            await Self.sizes(of: urls, concurrency: 4) { index, size in
                guard let self, !Task.isCancelled else { return }
                // Look up by URL: the list re-sorts as sizes land, so the
                // original index no longer points at the same row.
                if let i = self.items.firstIndex(where: { $0.url == urls[index] }) {
                    self.items[i].size = size.map(SizeState.done) ?? .failed
                }
                self.items.sort(by: Self.bySizeDescending)
            }
            guard let self, !Task.isCancelled else { return }
            self.isScanning = false
            self.lastScan = Date()
            self.refreshVolume()
        }
    }

    /// Stop all walks. Called when the Disk screen leaves — the panel closing
    /// must never leave a directory walk running.
    func cancel() {
        scanTask?.cancel()
        scanTask = nil
        for task in childTasks.values { task.cancel() }
        childTasks.removeAll()
        isScanning = false
        for i in items.indices {
            if items[i].size == .scanning { items[i].size = .pending }
            items[i].isLoadingChildren = false
        }
    }

    private static func bySizeDescending(_ a: Item, _ b: Item) -> Bool {
        (a.size.bytes ?? -1) > (b.size.bytes ?? -1)
    }

    // MARK: - Expand

    func toggleExpanded(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].isExpanded.toggle()
        if items[i].isExpanded, items[i].children == nil {
            loadChildren(at: i)
        }
    }

    /// Immediate children with sizes, largest first. Files count too — a
    /// 12 GB .dmg in Downloads is exactly what you're looking for.
    private func loadChildren(at index: Int) {
        let parent = items[index]
        items[index].isLoadingChildren = true
        childTasks[parent.id]?.cancel()

        childTasks[parent.id] = Task { [weak self] in
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.isDirectoryKey]
            let entries = (try? fm.contentsOfDirectory(at: parent.url, includingPropertiesForKeys: keys, options: [])) ?? []
            let children = entries.map { url -> Item in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                var item = Item(childOf: parent, url: url, isDirectory: isDir)
                item.size = .scanning
                return item
            }
            guard let self, !Task.isCancelled else { return }
            self.setChildren(children, for: parent.id)

            let urls = children.map(\.url)
            await Self.sizes(of: urls, concurrency: 4) { i, size in
                guard !Task.isCancelled,
                      let pi = self.items.firstIndex(where: { $0.id == parent.id }),
                      var kids = self.items[pi].children,
                      let ci = kids.firstIndex(where: { $0.url == urls[i] })
                else { return }
                kids[ci].size = size.map(SizeState.done) ?? .failed
                self.items[pi].children = kids.sorted(by: Self.bySizeDescending)
            }
            guard !Task.isCancelled else { return }
            if let pi = self.items.firstIndex(where: { $0.id == parent.id }) {
                self.items[pi].isLoadingChildren = false
            }
            self.childTasks[parent.id] = nil
        }
    }

    private func setChildren(_ children: [Item], for parentID: String) {
        guard let pi = items.firstIndex(where: { $0.id == parentID }) else { return }
        items[pi].children = children
    }

    // MARK: - Delete

    enum DeleteError: LocalizedError {
        case viewOnly
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .viewOnly: "This folder is shown for reference only."
            case let .failed(m): m
            }
        }
    }

    /// Permanently remove a top-level target (its contents, or the folder
    /// itself) or one child. Re-measures the affected row afterwards so the
    /// freed space shows up without a full rescan.
    func delete(_ item: Item) async throws {
        guard item.risk != .viewOnly else { throw DeleteError.viewOnly }
        let fm = FileManager.default
        do {
            if item.deletesContents {
                for child in (try fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil, options: [])) {
                    try fm.removeItem(at: child)
                }
            } else {
                try fm.removeItem(at: item.url)
            }
        } catch {
            throw DeleteError.failed(error.localizedDescription)
        }

        refreshVolume()

        if let pi = items.firstIndex(where: { $0.id == item.id }) {
            // Top-level: folder is now empty (or gone). Re-measure.
            items[pi].children = nil
            items[pi].isExpanded = false
            items[pi].size = .done(0)
            items.sort(by: Self.bySizeDescending)
        } else if let pi = items.firstIndex(where: { $0.children?.contains { $0.id == item.id } ?? false }) {
            items[pi].children?.removeAll { $0.id == item.id }
            let remaining = items[pi].children?.compactMap { $0.size.bytes }.reduce(0, +) ?? 0
            if items[pi].size.bytes != nil { items[pi].size = .done(remaining) }
            items.sort(by: Self.bySizeDescending)
        }
    }

    // MARK: - Measuring

    /// Sum allocated size of everything under `url`. Runs off the main actor;
    /// checks for cancellation every few hundred files so leaving the screen
    /// stops it promptly. `nil` means cancelled or unreadable.
    nonisolated static func directorySize(_ url: URL) async -> Int64? {
        await Task.detached(priority: .utility) { () -> Int64? in
            let fm = FileManager.default
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            if !isDir.boolValue {
                let v = try? url.resourceValues(forKeys: keys)
                return Int64(v?.totalFileAllocatedSize ?? 0)
            }
            guard let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) else { return nil }
            var total: Int64 = 0
            var n = 0
            while let f = e.nextObject() as? URL {
                n += 1
                if n & 0xFF == 0, Task.isCancelled { return nil }
                guard let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
                total += Int64(v.totalFileAllocatedSize ?? 0)
            }
            return Task.isCancelled ? nil : total
        }.value
    }

    /// Measure many paths with bounded concurrency, reporting each as it lands.
    nonisolated private static func sizes(
        of urls: [URL],
        concurrency: Int,
        onEach: @MainActor @escaping (Int, Int64?) -> Void,
    ) async {
        await withTaskGroup(of: (Int, Int64?).self) { group in
            var next = 0
            func enqueue() {
                guard next < urls.count else { return }
                let i = next
                next += 1
                group.addTask { (i, await directorySize(urls[i])) }
            }
            for _ in 0 ..< min(concurrency, urls.count) { enqueue() }
            for await (i, size) in group {
                if Task.isCancelled { group.cancelAll(); return }
                await onEach(i, size)
                enqueue()
            }
        }
    }
}

// MARK: - Formatting

extension Int64 {
    /// "1.2 GB" / "340 MB" — decimal units like Finder.
    var diskSizeString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
