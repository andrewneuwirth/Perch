import Foundation
import OSLog

/// Keyboard backlight control via the private CoreBrightness framework
/// (KeyboardBrightnessClient). Private API — fine for this unsandboxed,
/// personal build; every call degrades to a silent no-op if Apple changes
/// the framework, so red mode itself can never break because of this.
final class KeyboardBacklight {
    static let shared = KeyboardBacklight()

    private var client: NSObject?

    private init() {
        guard let bundle = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"),
              bundle.load(),
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else {
            Log.shortcuts.error("[KeyboardBacklight] CoreBrightness unavailable")
            return
        }
        client = cls.init()
    }

    private var keyboardIDs: [UInt64] {
        guard let client else { return [] }
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard client.responds(to: sel),
              let ids = client.perform(sel)?.takeUnretainedValue() as? [NSNumber]
        else { return [] }
        return ids.map(\.uint64Value)
    }

    func brightness(forKeyboard id: UInt64) -> Float? {
        guard let client else { return nil }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard client.responds(to: sel), let method = client.method(for: sel) else { return nil }
        typealias Fn = @convention(c) (NSObject, Selector, UInt64) -> Float
        return unsafeBitCast(method, to: Fn.self)(client, sel, id)
    }

    func setBrightness(_ value: Float, forKeyboard id: UInt64) {
        guard let client else { return }
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        guard client.responds(to: sel), let method = client.method(for: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, Float, UInt64) -> Bool
        _ = unsafeBitCast(method, to: Fn.self)(client, sel, value, id)
    }

    // MARK: - Save / zero / restore (for red mode)

    private var savedLevels: [UInt64: Float] = [:]

    /// Remember current levels and switch every keyboard backlight off.
    func saveAndTurnOff() {
        savedLevels.removeAll()
        for id in keyboardIDs {
            if let current = brightness(forKeyboard: id) {
                savedLevels[id] = current
            }
            setBrightness(0, forKeyboard: id)
        }
        Log.shortcuts.info("[KeyboardBacklight] off (saved \(self.savedLevels.count) keyboard levels)")
    }

    /// Restore whatever the levels were when saveAndTurnOff() ran.
    func restore() {
        for (id, level) in savedLevels {
            setBrightness(level, forKeyboard: id)
        }
        Log.shortcuts.info("[KeyboardBacklight] restored")
        savedLevels.removeAll()
    }
}
