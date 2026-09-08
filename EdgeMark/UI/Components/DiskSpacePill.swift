import SwiftUI

/// Free-space readout in the footer. One `statfs` on appear — no timer, no
/// directory walks. Turns red under 10% free. Click opens the Disk screen,
/// which is where the real measuring happens.
struct DiskSpacePill: View {
    @Environment(NoteStore.self) var noteStore

    @State private var volume: DiskUsageModel.VolumeInfo?
    @State private var isHovered = false

    var body: some View {
        Button {
            noteStore.openDisk()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 10, weight: .medium))
                if let volume {
                    Text(L10n.shared.t("disk.pill", volume.free.diskSizeString))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (volume?.isLow == true ? Color.red.opacity(isHovered ? 0.18 : 0.12) : (isHovered ? Color.primary.opacity(0.08) : Color.glassInset)),
                in: Capsule(),
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.shared["disk.pill.help"])
        .onHover { isHovered = $0 }
        .onAppear { volume = DiskUsageModel.volumeInfo() }
        // Re-read when the panel comes back — still just one cheap call.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            volume = DiskUsageModel.volumeInfo()
        }
    }

    private var tint: Color {
        if volume?.isLow == true { return .red }
        return isHovered ? .primary : .secondary
    }
}
