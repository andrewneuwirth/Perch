import Cocoa
import OSLog

/// Detects a bare tap-and-release of the right Option key, ignoring it if any other
/// key was pressed during the hold (so Option-based combos, like accent entry, don't
/// misfire the toggle). Mirrors EdgeDetector's dual global+local monitor pattern —
/// a global monitor alone misses events while Perch's own panel is the key window.
final class SpecialKeyMonitor {
    /// Called when a clean tap-and-release completes.
    var onTapped: (() -> Void)?

    private static let rightOptionKeyCode: UInt16 = 61

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var isDown = false
    private var wasInterrupted = false

    func startMonitoring() {
        guard globalFlagsMonitor == nil else { return }
        Log.shortcuts.info("[SpecialKeyMonitor] started monitoring right-Option tap")

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
        guard event.keyCode == Self.rightOptionKeyCode else { return }
        let down = event.modifierFlags.contains(.option)

        if down, !isDown {
            isDown = true
            wasInterrupted = false
        } else if !down, isDown {
            isDown = false
            if !wasInterrupted {
                Log.shortcuts.debug("[SpecialKeyMonitor] right-Option tap detected")
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
