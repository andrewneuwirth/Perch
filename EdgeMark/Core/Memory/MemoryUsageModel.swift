import Darwin
import Foundation
import Observation

/// Live memory readout. Same discipline as `DiskUsageModel`: the footer pill
/// only ever calls the cheap `snapshot()` (a couple of syscalls, microseconds),
/// and the per-process walk runs only while `MemoryView` is on screen —
/// `start()` on appear, `stop()` on disappear. Nothing polls in the background.
@Observable
@MainActor
final class MemoryUsageModel {

    private(set) var snapshot: MemorySnapshot?
    private(set) var apps: [AppMemory] = []
    private(set) var isSampling = false
    /// Processes the kernel wouldn't report a footprint for — almost always
    /// root-owned ones. Shown as a footnote rather than silently dropped.
    private(set) var deniedCount = 0

    private var expandedApps: Set<String> = []
    private var timer: Timer?
    private var sampleTask: Task<Void, Never>?

    /// Fast enough to feel live, slow enough that the walk (~15 ms) stays
    /// invisible. Only ticks while the screen is up.
    private let interval: TimeInterval = 2.0

    init() {
        snapshot = Self.systemSnapshot()
    }

    // MARK: - Lifecycle

    /// Begin sampling processes. Safe to call twice; the second call is a no-op.
    func start() {
        guard timer == nil else { return }
        refreshNow()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        // .common so the list keeps updating while a menu or scroll is active.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Tear everything down. The panel closing must never leave a timer or a
    /// process walk running.
    func stop() {
        timer?.invalidate()
        timer = nil
        sampleTask?.cancel()
        sampleTask = nil
        isSampling = false
    }

    func refreshNow() {
        snapshot = Self.systemSnapshot()
        guard sampleTask == nil else { return } // a walk is already in flight
        isSampling = apps.isEmpty
        sampleTask = Task { [weak self] in
            let sample = await Self.sampleProcesses()
            guard let self, !Task.isCancelled else { return }
            apps = ProcessGrouping.group(sample.processes)
            deniedCount = sample.denied
            isSampling = false
            sampleTask = nil
        }
    }

    // MARK: - Expansion

    func isExpanded(_ appName: String) -> Bool { expandedApps.contains(appName) }

    func toggleExpanded(_ appName: String) {
        if expandedApps.contains(appName) { expandedApps.remove(appName) }
        else { expandedApps.insert(appName) }
    }

    // MARK: - System snapshot

    /// Total, used, pressure. Two sysctls and one `host_statistics64` — cheap
    /// enough to call on every appear, which is all the footer pill does.
    static func systemSnapshot() -> MemorySnapshot? {
        guard let counters = vmCounters() else { return nil }
        return MemorySnapshot(
            total: Int64(ProcessInfo.processInfo.physicalMemory),
            counters: counters,
            swapUsed: swapUsed(),
            pressure: MemoryPressure(rawLevel: sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1),
        )
    }

    private static func vmCounters() -> VMCounters? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return VMCounters(
            pageSize: Int64(vm_kernel_page_size),
            internalPages: Int64(stats.internal_page_count),
            purgeablePages: Int64(stats.purgeable_count),
            wirePages: Int64(stats.wire_count),
            compressorPages: Int64(stats.compressor_page_count),
            externalPages: Int64(stats.external_page_count),
        )
    }

    private static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(usage.xsu_used)
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: - Per-process sampling

    private struct Sample {
        var processes: [ProcessMemory] = []
        var denied = 0
    }

    /// Walk every pid, ask for its phys footprint, and label it with the app
    /// bundle it belongs to. Runs off the main actor; ~15 ms for ~600 processes.
    private nonisolated static func sampleProcesses() async -> Sample {
        await Task.detached(priority: .utility) { () -> Sample in
            var pids = [pid_t](repeating: 0, count: 4096)
            let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { return Sample() }
            let count = Int(bytes) / MemoryLayout<pid_t>.size

            var sample = Sample()
            sample.processes.reserveCapacity(count)
            // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro itself isn't imported into Swift.
            var pathBuffer = [CChar](repeating: 0, count: 4 * 1024)

            for i in 0 ..< count {
                let pid = pids[i]
                guard pid > 0 else { continue }
                if Task.isCancelled { return sample }

                guard let footprint = footprint(of: pid) else {
                    sample.denied += 1
                    continue
                }
                // Anything under a megabyte is noise in a list of memory hogs.
                guard footprint >= 1_048_576 else { continue }

                let path = pathBuffer.withUnsafeMutableBufferPointer { buffer -> String in
                    guard proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count)) > 0 else { return "" }
                    return String(cString: buffer.baseAddress!)
                }
                let name = path.isEmpty ? processName(of: pid) : String(path.split(separator: "/").last ?? "")
                guard !name.isEmpty else { continue }

                sample.processes.append(ProcessMemory(
                    pid: pid,
                    name: name,
                    appName: path.isEmpty ? name : ProcessGrouping.appName(forExecutablePath: path),
                    footprint: footprint,
                ))
            }
            return sample
        }.value
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

    /// Last resort when `proc_pidpath` is denied. Truncated to 16 characters by
    /// the kernel, which is why the path is preferred.
    private nonisolated static func processName(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(2 * MAXCOMLEN))
        return buffer.withUnsafeMutableBufferPointer { b -> String in
            guard proc_name(pid, b.baseAddress, UInt32(b.count)) > 0 else { return "" }
            return String(cString: b.baseAddress!)
        }
    }
}
