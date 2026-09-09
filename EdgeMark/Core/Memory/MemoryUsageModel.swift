import Darwin
import Foundation
import Observation

/// Memory-hog finder, the twin of `DiskUsageModel`. Same rule about background
/// work: nothing samples unless `MemoryView` is on screen — `start()` on
/// appear, `stop()` on disappear. A sample is one pass over the process table
/// and costs a few milliseconds, so it can refresh on a timer while visible;
/// it must never keep ticking behind a closed panel.
@Observable
@MainActor
final class MemoryUsageModel {

    // MARK: - System

    /// The machine-wide numbers behind the summary bar, in the same terms
    /// Activity Monitor uses: memory *used* is app memory plus wired plus
    /// compressed, and cached files are excluded because the OS gives them
    /// back on demand.
    struct SystemMemory: Equatable {
        let total: Int64
        let app: Int64
        let wired: Int64
        let compressed: Int64
        let cached: Int64
        let swapUsed: Int64

        var used: Int64 { app + wired + compressed }
        var free: Int64 { max(total - used, 0) }
        var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
        /// Compressing and swapping means the machine is out of room, which is
        /// the thing worth showing in red — a high *used* number on its own is
        /// normal and healthy.
        var isUnderPressure: Bool { swapUsed > 0 || (total > 0 && Double(compressed) / Double(total) > 0.20) }
    }

    /// One pass over the process table.
    struct Sample: Equatable {
        var apps: [AppMemory] = []
        /// Processes the kernel refused to measure — see `footprint(of:)`.
        var denied = 0
        var takenAt = Date()

        var total: Int64 { apps.reduce(0) { $0 + $1.footprint } }
    }

    private(set) var system: SystemMemory?
    private(set) var sample = Sample()
    private(set) var isSampling = false
    private(set) var hasSampled = false

    /// Apps the user has opened the disclosure arrow on, by name. Held here
    /// rather than in the rows so it survives a resample.
    private(set) var expanded: Set<String> = []

    private var timerTask: Task<Void, Never>?

    /// How often the list refreshes while the screen is open.
    private static let refreshInterval: Duration = .seconds(3)

    // MARK: - Lifecycle

    /// Take a sample now, then keep refreshing until `stop()`.
    func start() {
        stop()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    /// Stop sampling. Called when the Memory screen leaves — the panel closing
    /// must never leave a sampler running.
    func stop() {
        timerTask?.cancel()
        timerTask = nil
        isSampling = false
    }

    /// One sample, off the main actor, applied when it lands.
    func refresh() async {
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }

        let fresh = await Task.detached(priority: .utility) { Self.takeSample() }.value
        guard !Task.isCancelled else { return }
        system = Self.systemMemory()
        sample = fresh
        hasSampled = true
    }

    func toggleExpanded(_ appName: String) {
        if expanded.contains(appName) {
            expanded.remove(appName)
        } else {
            expanded.insert(appName)
        }
    }

    func isExpanded(_ appName: String) -> Bool { expanded.contains(appName) }

    // MARK: - Sampling

    /// Walk every pid, measure what the kernel will let us measure, and group
    /// the result into app rows.
    nonisolated private static func takeSample() -> Sample {
        var sample = Sample()
        var processes: [ProcessMemory] = []

        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return sample }

        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is a C macro Swift can't import.
        var buffer = [CChar](repeating: 0, count: 4 * 1024)

        for i in 0 ..< Int(bytes) / MemoryLayout<pid_t>.size {
            let pid = pids[i]
            guard pid > 0 else { continue }

            guard let footprint = footprint(of: pid) else {
                sample.denied += 1
                continue
            }

            let path = buffer.withUnsafeMutableBufferPointer { b -> String in
                guard proc_pidpath(pid, b.baseAddress, UInt32(b.count)) > 0 else { return "" }
                return String(cString: b.baseAddress!)
            }
            guard !path.isEmpty else { continue }

            processes.append(ProcessMemory(
                pid: pid,
                name: MemoryMetrics.processName(forExecutablePath: path),
                appName: MemoryMetrics.appName(forExecutablePath: path),
                footprint: footprint,
            ))
        }

        sample.apps = MemoryMetrics.group(processes)
        return sample
    }

    /// Phys footprint — the same number Activity Monitor's Memory column shows.
    /// `nil` for processes owned by another user: the kernel gates both this and
    /// `proc_pidinfo` behind the same check, so there is no second way in from an
    /// unprivileged app. Those are counted and disclosed, never guessed at.
    private nonisolated static func footprint(of pid: pid_t) -> Int64? {
        var info = rusage_info_current()
        let ok = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard ok == 0 else { return nil }
        return Int64(info.ri_phys_footprint)
    }

    // MARK: - System totals

    nonisolated static func systemMemory() -> SystemMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        func bytes(_ pages: UInt64) -> Int64 { Int64(clamping: pages * page) }

        let purgeable = UInt64(stats.purgeable_count)
        let internalPages = UInt64(stats.internal_page_count)
        // Purgeable pages sit inside the internal count; app memory is what's
        // left once the OS-reclaimable part is taken out.
        let appPages = internalPages > purgeable ? internalPages - purgeable : 0

        return SystemMemory(
            total: Int64(clamping: ProcessInfo.processInfo.physicalMemory),
            app: bytes(appPages),
            wired: bytes(UInt64(stats.wire_count)),
            compressed: bytes(UInt64(stats.compressor_page_count)),
            cached: bytes(UInt64(stats.external_page_count) + purgeable),
            swapUsed: swapUsed(),
        )
    }

    /// Bytes currently on swap. Zero is the healthy answer.
    nonisolated private static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(clamping: usage.xsu_used)
    }
}
