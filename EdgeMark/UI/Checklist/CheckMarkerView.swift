import SwiftUI

/// Round glass checkbox used by checklist rows. Checked = accent fill with a white check.
struct CheckMarkerView: View {
    let isDone: Bool
    var size: CGFloat = 22
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.accentColor : (isHovered ? Color.glassInsetHover : Color.glassInset))
                Circle()
                    .strokeBorder(isDone ? Color.accentColor.opacity(0.9) : Color.glassHairline.opacity(isHovered ? 1.8 : 1.2), lineWidth: 1)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(isDone ? 1 : 0.3)
                    .opacity(isDone ? 1 : 0)
            }
            .frame(width: size, height: size)
            .scaleEffect(isHovered && !isDone ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: isDone)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
