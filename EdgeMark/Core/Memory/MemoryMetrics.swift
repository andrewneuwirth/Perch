import Foundation

/// One running process and what it costs. `footprint` is the phys-footprint
/// figure Activity Monitor's Memory column shows.
struct ProcessMemory: Identifiable, Equatable {
    let pid: Int32
    /// Executable name, e.g. "Google Chrome Helper (Renderer)".
    let name: String
    /// Bundle this process belongs to, e.g. "Google Chrome".
    let appName: String
    let footprint: Int64

    var id: Int32 { pid }
}

/// Every process that belongs to one app, and their combined cost. This is the
/// unit the list shows — a browser with forty helpers is one row, not forty.
struct AppMemory: Identifiable, Equatable {
    let appName: String
    /// Largest first, same as the app rows themselves.
    var processes: [ProcessMemory]

    var id: String { appName }
    var footprint: Int64 { processes.reduce(0) { $0 + $1.footprint } }
    /// A one-process app has nothing interesting behind the disclosure arrow.
    var isExpandable: Bool { processes.count > 1 }
}

/// Pure shaping rules for the memory list: how an executable path becomes an
/// app name, and how processes collapse into app rows. Kept free of Darwin
/// calls so it can be tested without sampling the live machine.
enum MemoryMetrics {

    /// The app a process belongs to, derived from its executable path.
    ///
    /// The *first* `.app` on the path wins, not the last: Chrome's renderers
    /// live at `Google Chrome.app/…/Google Chrome Helper (Renderer).app/…`, and
    /// the outermost bundle is the one a person thinks of as "the app". A
    /// binary with no bundle at all — a CLI tool, a versioned helper — is its
    /// own app, which is why Claude Code shows up under its version number.
    static func appName(forExecutablePath path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if let bundle = components.first(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }
        return components.last.map(String.init) ?? path
    }

    /// The executable's own name — the leaf of the path.
    static func processName(forExecutablePath path: String) -> String {
        String(path.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
    }

    /// Collapse processes into app rows, heaviest app first, and heaviest
    /// process first inside each app. Ties break on name so the order is
    /// stable between samples and rows don't jitter while you read them.
    static func group(_ processes: [ProcessMemory]) -> [AppMemory] {
        Dictionary(grouping: processes, by: \.appName)
            .map { name, procs in
                AppMemory(appName: name, processes: procs.sorted(by: byFootprintDescending))
            }
            .sorted { a, b in
                a.footprint == b.footprint
                    ? a.appName.localizedCaseInsensitiveCompare(b.appName) == .orderedAscending
                    : a.footprint > b.footprint
            }
    }

    private static func byFootprintDescending(_ a: ProcessMemory, _ b: ProcessMemory) -> Bool {
        a.footprint == b.footprint ? a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending : a.footprint > b.footprint
    }
}

// MARK: - Formatting

extension Int64 {
    /// "1.2 GB" / "340 MB" — decimal units, matching the disk screen and
    /// Activity Monitor's Memory column.
    var memorySizeString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .memory)
    }
}
