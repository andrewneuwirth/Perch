import AppKit
import SwiftUI

extension Color {
    /// 1px highlight ring that makes translucent surfaces read as glass.
    /// Brighter in light mode, subtle in dark mode. Resolves per-appearance at draw time.
    static let glassHairline = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor.white.withAlphaComponent(isDark ? 0.14 : 0.55)
    })

    /// Soft fill for cards that sit on top of the glass panel (note cards, favorites rows).
    static let glassInset = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.04)
    })

    static let glassInsetHover = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.07)
    })
}

/// Panel-tinted material + rounded corners + hairline ring. Shared by the page cards,
/// the floating button, and the checklist marker so they read as one family.
struct GlassCard: ViewModifier {
    @Environment(AppSettings.self) private var appSettings
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background { VisualEffectView(tint: appSettings.panelTint.color, material: appSettings.panelStyle.material) }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.glassHairline, lineWidth: 1)
            }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }
}

/// Inset surface used for rows/cards that live inside a glass card.
struct GlassInset: ViewModifier {
    var cornerRadius: CGFloat = 8
    var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.glassInsetHover : Color.glassInset)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.glassHairline.opacity(0.6), lineWidth: 1)
            }
    }
}

extension View {
    func glassInset(cornerRadius: CGFloat = 8, isHovered: Bool = false) -> some View {
        modifier(GlassInset(cornerRadius: cornerRadius, isHovered: isHovered))
    }
}

/// Small trash control revealed on row hover. Turns red on its own hover.
struct RowTrashButton: View {
    let visible: Bool
    let action: () -> Void
    @State private var isHovered = false

    /// Width of the trailing area rows must leave click-free so this button gets the click.
    static let zoneWidth: CGFloat = 34

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Color.red : Color.secondary)
                .frame(width: 24, height: 24)
                .background(isHovered ? Color.red.opacity(0.12) : Color.glassInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.shared["common.moveToTrash"])
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .onHover { isHovered = $0 }
    }
}

/// Up/down controls revealed on row hover, for lists that can be reordered.
/// Buttons rather than a drag: the panel is `isMovableByWindowBackground`, so a
/// drag begun on a row moves the whole window before SwiftUI sees it.
struct RowMoveButtons: View {
    let visible: Bool
    let onUp: (() -> Void)?
    let onDown: (() -> Void)?

    /// Width the row must leave click-free for both buttons.
    static let zoneWidth: CGFloat = 44

    var body: some View {
        HStack(spacing: 2) {
            button("chevron.up", help: L10n.shared["checklist.moveUp"], action: onUp)
            button("chevron.down", help: L10n.shared["checklist.moveDown"], action: onDown)
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }

    @ViewBuilder
    private func button(_ symbol: String, help: String, action: (() -> Void)?) -> some View {
        // The end of the list keeps the slot but loses the control, so rows
        // don't reflow as you move an item up and down.
        if let action {
            RowMoveButton(symbol: symbol, help: help, action: action)
        } else {
            Color.clear.frame(width: 20, height: 24)
        }
    }
}

private struct RowMoveButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 24)
                .background(isHovered ? Color.accentColor.opacity(0.12) : Color.glassInset, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
    }
}
