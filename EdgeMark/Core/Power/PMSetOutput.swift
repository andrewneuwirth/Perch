import Foundation

/// What the system currently thinks about sleeping, as read back from `pmset`.
/// `nil` means "pmset didn't tell us", which is never treated as a `0`.
struct PMSetSettings: Equatable {
    /// System-wide `SleepDisabled` — what `pmset -a disablesleep 1` sets.
    /// While this is on the Mac stays awake even with the lid closed.
    var sleepDisabled = false

    var acSleepMinutes: Int?
    var batterySleepMinutes: Int?
    var acDisplaySleepMinutes: Int?
    var batteryDisplaySleepMinutes: Int?

    /// True only when every power source this Mac has reports a `0` idle-sleep
    /// timer. A machine we couldn't read is not "never sleeps".
    var neverSleeps: Bool {
        let timers = [acSleepMinutes, batterySleepMinutes].compactMap(\.self)
        return !timers.isEmpty && timers.allSatisfy { $0 == 0 }
    }
}

/// Parses `pmset -g` and `pmset -g custom`. Split out from the process-spawning
/// side because Apple's output format is the fragile part and this way it can
/// be pinned by tests.
enum PMSetOutput {

    /// `pmset -g custom` groups settings under a power-source heading.
    private enum Source {
        case ac, battery
    }

    static func parse(general: String, custom: String) -> PMSetSettings {
        var settings = PMSetSettings()
        settings.sleepDisabled = sleepDisabled(inGeneral: general)

        var source: Source?
        for line in custom.split(separator: "\n", omittingEmptySubsequences: false) {
            // Headings are flush left; settings are indented. Checking the
            // prefix keeps a value line containing "AC Power" from re-sectioning.
            if !line.hasPrefix(" "), !line.hasPrefix("\t") {
                if line.hasPrefix("AC Power") { source = .ac }
                else if line.hasPrefix("Battery Power") { source = .battery }
                else { source = nil }
                continue
            }
            guard let source, let (key, value) = keyValue(in: line) else { continue }
            switch (key, source) {
            case ("sleep", .ac): settings.acSleepMinutes = value
            case ("sleep", .battery): settings.batterySleepMinutes = value
            case ("displaysleep", .ac): settings.acDisplaySleepMinutes = value
            case ("displaysleep", .battery): settings.batteryDisplaySleepMinutes = value
            default: continue
            }
        }
        return settings
    }

    private static func sleepDisabled(inGeneral text: String) -> Bool {
        for line in text.split(separator: "\n") where line.contains("SleepDisabled") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if let last = fields.last, let n = Int(last) { return n != 0 }
        }
        return false
    }

    /// A settings line is `<key> <number> [trailing noise]`. Keys containing
    /// spaces ("Sleep On Power Button") fail the Int parse and are skipped,
    /// which is what we want — none of them are settings we touch.
    private static func keyValue(in line: some StringProtocol) -> (String, Int)? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let value = Int(fields[1]) else { return nil }
        return (String(fields[0]), value)
    }
}
