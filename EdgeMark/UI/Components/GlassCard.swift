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
