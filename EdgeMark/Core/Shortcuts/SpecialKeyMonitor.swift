import Cocoa
import OSLog

/// Detects a bare tap-and-release of the right Option key, ignoring it if any other
/// key was pressed during the hold (so Option-based combos, like accent entry, don't
/// misfire the toggle). Mirrors EdgeDetector's dual global+local monitor pattern —
/// a global monitor alone misses events while Perch's own panel is the key window.
final class SpecialKeyMonitor {
    /// Called when a clean tap-and-release completes.
    var onTapped: (() -> Void)?

    private let watchedKeyCode: UInt16
    private let watchedFlag: NSEvent.ModifierFlags
    private let label: String

    /// Defaults preserve the original behavior: bare right-Option tap.
    init(keyCode: UInt16 = 61, flag: NSEvent.ModifierFlags = .option, label: String = "right-Option") {
        watchedKeyCode = keyCode
        watchedFlag = flag
        self.label = label
    }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var isDown = false
    private var wasInterrupted = false

    func startMonitoring() {
        guard globalFlagsMonitor == nil else { return }
        Log.shortcuts.info("[SpecialKeyMonitor] started monitoring \(self.label) tap")

        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            self?.handleOtherKeyDown()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleOtherKeyDown()
            return event
        }
    }

    func stopMonitoring() {
        Log.shortcuts.info("[SpecialKeyMonitor] stopped monitoring")
        for monitor in [globalFlagsMonitor, localFlagsMonitor, globalKeyMonitor, localKeyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
        isDown = false
        wasInterrupted = false
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == watchedKeyCode else { return }
        let down = event.modifierFlags.contains(watchedFlag)

        if down, !isDown {
            isDown = true
            wasInterrupted = false
        } else if !down, isDown {
            isDown = false
            if !wasInterrupted {
                Log.shortcuts.debug("[SpecialKeyMonitor] \(self.label) tap detected")
                onTapped?()
            }
        }
    }

    private func handleOtherKeyDown() {
        guard isDown, !wasInterrupted else { return }
        wasInterrupted = true
    }

    deinit {
        stopMonitoring()
    }
}
