import Foundation

/// Turning "never sleep" off has to put something back, and the honest answer
/// is whatever was there before it was turned on. This is the bookkeeping for
/// that: what to remember, and what to write when the switch comes back off.
///
/// Split out from `PowerModel` so the fallback rules can be pinned by tests
/// rather than discovered on someone's laptop.
enum SleepRestore {

    /// Only used for a power source we never managed to read — a machine where
    /// `pmset` was unreadable, or one whose sleep was already disabled before
    /// Perch first looked. macOS's own default idle timer, not a guess at the
    /// user's preference.
    static let fallbackMinutes = 10

    /// `pmset` writes to put the idle timers back. Per-source (`-c` charger,
    /// `-b` battery) rather than `-a`, so a Mac that slept at different
    /// intervals on power and battery keeps that difference.
    static func commands(ac: Int?, battery: Int?) -> [String] {
        [
            "pmset -c sleep \(ac ?? fallbackMinutes)",
            "pmset -b sleep \(battery ?? fallbackMinutes)",
        ]
    }

    /// What to stash before switching "never sleep" on.
    ///
    /// A `0` means that source already never slept, and is worth remembering as
    /// `0` — restoring it to 10 minutes would be us changing a setting the user
    /// never asked us to touch. `nil` (unreadable) is stored as nothing, so the
    /// fallback applies on the way back.
    static func timersWorthRemembering(ac: Int?, battery: Int?) -> (ac: Int?, battery: Int?) {
        (ac, battery)
    }
}
