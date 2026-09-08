import Cocoa
import OSLog

/// Screen-wide "red mode" for night eyes: suppresses the green and blue
/// channels at the display-gamma level (the redshift/f.lux technique), so the
/// whole screen — every app, every window — renders in deep red. No overlay
/// window, no compositing cost.
///
/// Toggled by a bare right-Command tap (see SidePanelController wiring).
/// macOS automatically restores normal gamma if the app quits or crashes,
/// so red mode can never get stuck.
final class RedModeController {
    static let shared = RedModeController()

    private(set) var isActive = false

    /// How much green/blue survives. Tuned toward melatonin research rather
    /// than pure eye comfort: blue (450-470nm) is the dominant suppressor of
    /// melatonin, so it's cut hardest; green is the secondary contributor.
    /// Red passes through untouched (>600nm barely affects melatonin at all).
    /// 0 = pure red (most sleep-friendly), higher = more readable but more
    /// circadian signal leaks through. Tune to taste.
    private let greenCeiling: CGGammaValue = 0.12
    private let blueCeiling: CGGammaValue = 0.03

    private var screenObserver: NSObjectProtocol?

    private init() {}

    func toggle() {
        isActive ? deactivate() : activate()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        applyToAllDisplays()
        KeyboardBacklight.shared.saveAndTurnOff()
        // Displays plugged in / woken while active get tinted too.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive else { return }
            self.applyToAllDisplays()
        }
        Log.shortcuts.info("[RedMode] activated")
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        CGDisplayRestoreColorSyncSettings()
        KeyboardBacklight.shared.restore()
        Log.shortcuts.info("[RedMode] deactivated")
    }

    private func applyToAllDisplays() {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetOnlineDisplayList(16, &displays, &displayCount) == .success else {
            Log.shortcuts.error("[RedMode] failed to enumerate displays")
            return
        }
        for i in 0 ..< Int(displayCount) {
            // Per channel: (min, max, gamma). Red passes through untouched;
            // green/blue are capped low so whites become red, not pink.
            CGSetDisplayTransferByFormula(
                displays[i],
                0, 1.0, 1.0,             // red
                0, greenCeiling, 1.0,    // green
                0, blueCeiling, 1.0      // blue
            )
        }
    }
}
