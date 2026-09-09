import Foundation

/// Raw page counts straight out of `host_statistics64(HOST_VM_INFO64)`, kept as
/// a plain value type so the arithmetic below can be tested without a kernel.
struct VMCounters: Equatable {
    var pageSize: Int64 = 0
    /// Anonymous pages — memory apps allocated for themselves.
    var internalPages: Int64 = 0
    /// Anonymous pages the kernel may reclaim on demand; Activity Monitor
    /// counts these as cache, not as app memory.
    var purgeablePages: Int64 = 0
    /// Pages that can never be paged out (kernel, drivers).
    var wirePages: Int64 = 0
    /// Pages held by the memory compressor.
    var compressorPages: Int64 = 0
    /// File-backed pages — the disk cache.
    var externalPages: Int64 = 0
}

enum MemoryPressure: Equatable {
    case normal
    case warning
    case critical

    /// `kern.memorystatus_vm_pressure_level` reports 1 / 2 / 4, not 1 / 2 / 3.
    init(rawLevel: Int32) {
        switch rawLevel {
        case 2: self = .warning
        case 4: self = .critical
        default: self = .normal
        }
    }
}

/// One reading of system memory, using Activity Monitor's definitions so the
/// numbers Perch shows match the numbers the user can go and check.
struct MemorySnapshot: Equatable {
    let total: Int64
    let app: Int64
    let wired: Int64
    let compressed: Int64
    let cached: Int64
    let swapUsed: Int64
    let pressure: MemoryPressure

    /// "Memory Used" — app + wired + compressed. Cached files are excluded on
    /// purpose: that memory is available the moment something else wants it.
    var used: Int64 { app + wired + compressed }

    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(used) / Double(total), 1.0)
    }

    init(total: Int64, counters: VMCounters, swapUsed: Int64, pressure: MemoryPressure) {
        self.total = total
        let page = counters.pageSize
        app = max(counters.internalPages - counters.purgeablePages, 0) * page
        wired = counters.wirePages * page
        compressed = counters.compressorPages * page
        cached = (counters.externalPages + counters.purgeablePages) * page
        self.swapUsed = swapUsed
        self.pressure = pressure
    }
}

// MARK: - Processes

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

/// An app and every process it spawned, collapsed into one row.
struct AppMemory: Identifiable, Equatable {
    let name: String
    let footprint: Int64
    let processes: [ProcessMemory]

    var id: String { name }
    /// A one-process app has nothing interesting behind the disclosure arrow.
    var isExpandable: Bool { processes.count > 1 }
}

enum ProcessGrouping {

    /// The app a process belongs to is the *outermost* `.app` bundle in its
    /// executable path — Chrome's renderers live several bundles deep inside
    /// Google Chrome.app, and that outer one is the app the user recognises.
    /// Executables outside any bundle stand for themselves.
    static func appName(forExecutablePath path: String) -> String {
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return String(path.split(separator: "/").last ?? "")
    }

    /// Collapse processes into per-app rows, biggest first, children too.
    static func group(_ processes: [ProcessMemory]) -> [AppMemory] {
        Dictionary(grouping: processes, by: \.appName)
            .map { name, procs in
                AppMemory(
                    name: name,
                    footprint: procs.reduce(0) { $0 + $1.footprint },
                    processes: procs.sorted { $0.footprint > $1.footprint },
                )
            }
            .sorted { $0.footprint > $1.footprint }
    }
}

// MARK: - Formatting

extension Int64 {
    /// "18.2 GB" — decimal units, matching Activity Monitor and the disk screen.
    var memorySizeString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .memory)
    }
}
