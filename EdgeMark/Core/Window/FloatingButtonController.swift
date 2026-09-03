import Cocoa
import SwiftUI

/// Small always-on-top circular button parked in the bottom corner of the screen
/// (the corner matching the configured edge side). Clicking it toggles the panel.
/// Modelled on OpenWhispr's dictation pill: non-activating so it never steals focus.
final class FloatingButtonController {
    /// Height reserved at the bottom of the screen so the panel sits above the button.
    static let reservedHeight: CGFloat = 60
    static let windowSize: CGFloat = 60
    static let buttonSize: CGFloat = 44

    private let panel: NSPanel
    private let state = FloatingButtonState()
    private let onToggle: () -> Void
    private var observers: [Any] = []

    var windowFrame: NSRect? {
        panel.isVisible ? panel.frame : nil
    }

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        let size = Self.windowSize
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        state.side = ShortcutSettings.shared.edgeSide
        let hosting = NSHostingView(rootView: FloatingButtonView(state: state, action: { [onToggle] in onToggle() })
            .environment(AppSettings.shared))
        hosting.frame = NSRect(x: 0, y: 0, width: size, height: size)
        panel.contentView = hosting

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .panelVisibilityChanged, object: nil, queue: .main) { [weak self] note in
            self?.state.isPanelShown = (note.userInfo?["shown"] as? Bool) ?? false
        })
        observers.append(nc.addObserver(forName: .shortcutSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.state.side = ShortcutSettings.shared.edgeSide
            self?.reposition()
        })
        observers.append(nc.addObserver(forName: .floatingButtonSettingChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyEnabledState()
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reposition()
        })

        applyEnabledState()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func applyEnabledState() {
        if ShortcutSettings.shared.floatingButtonEnabled {
            reposition()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    /// Dock the window in the bottom corner of the main screen's visible frame.
    /// The 44pt button is centred in the 60pt window, leaving an 8pt margin to both screen edges.
    func reposition() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let size = Self.windowSize
        let x: CGFloat = switch ShortcutSettings.shared.edgeSide {
        case .right: vf.maxX - size
        case .left: vf.minX
        }
        // Nudged up 4pt so the button clears the very bottom of the screen.
        panel.setFrame(NSRect(x: x, y: vf.minY + 4, width: size, height: size), display: true)
    }
}

// MARK: - State

@Observable
final class FloatingButtonState {
    var isPanelShown = false
    var side: EdgeSide = .right
}

// MARK: - View

struct FloatingButtonView: View {
    let state: FloatingButtonState
    let action: () -> Void
    @Environment(AppSettings.self) private var appSettings
    @State private var isHovered = false
    @State private var isPressed = false

    private var symbol: String {
        switch state.side {
        case .right: state.isPanelShown ? "sidebar.trailing" : "sidebar.right"
        case .left: state.isPanelShown ? "sidebar.leading" : "sidebar.left"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .background {
                    VisualEffectView(tint: appSettings.panelTint.color, material: appSettings.panelStyle.material)
                        .clipShape(Circle())
                }
                .overlay {
                    Circle().strokeBorder(Color.glassHairline.opacity(isHovered ? 1.6 : 1), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.25), radius: isHovered ? 8 : 5, y: 2)

            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(state.isPanelShown ? Color.accentColor : .primary)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: FloatingButtonController.buttonSize, height: FloatingButtonController.buttonSize)
        .scaleEffect(isPressed ? 0.94 : (isHovered ? 1.06 : 1))
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in
                    isPressed = false
                    action()
                },
        )
        .help(L10n.shared["menu.toggle"])
        .frame(width: FloatingButtonController.windowSize, height: FloatingButtonController.windowSize)
    }
}
