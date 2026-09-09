import Foundation

/// The three states worth having, instead of two independent switches that can
/// be set to contradict each other.
///
/// The pair behind them is not orthogonal: holding the *display* awake keeps
/// the system awake as a side effect, because a lit screen is not an idle
/// machine. So of the four combinations only three mean anything, and this
/// names them.
enum SleepPreset: String, CaseIterable, Identifiable {
    /// Nothing held. The Mac sleeps exactly as its own settings say.
    case normal
    /// Processes keep running; the screen still goes dark on its usual timer.
    /// The overnight case: leave a build or a download going, lock the screen
    /// yourself, and let the display switch off as it always does.
    case overnight
    /// Screen and machine both stay up — presenting, or watching something.
    case screenOn

    var id: String { rawValue }

    /// `kIOPMAssertionTypePreventUserIdleSystemSleep`.
    var keepSystemAwake: Bool {
        switch self {
        case .normal: false
        case .overnight, .screenOn: true
        }
    }

    /// `kIOPMAssertionTypePreventUserIdleDisplaySleep`. Off for overnight —
    /// that is the whole point of it, and the difference from `screenOn`.
    var keepDisplayAwake: Bool {
        switch self {
        case .normal, .overnight: false
        case .screenOn: true
        }
    }

    /// Read a preset back from the assertions actually held, so the control
    /// reflects the real state even if something set them separately.
    ///
    /// Display first: a held display assertion means the screen is staying on
    /// whatever else is true, and that is `screenOn` regardless of whether the
    /// system assertion happened to be taken as well.
    static func matching(keepSystemAwake: Bool, keepDisplayAwake: Bool) -> SleepPreset {
        if keepDisplayAwake { return .screenOn }
        return keepSystemAwake ? .overnight : .normal
    }
}
