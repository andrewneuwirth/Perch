import SwiftUI

struct NoteCardView: View {
    let note: Note
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(note.title.isEmpty ? "Untitled" : note.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(note.createdAt.homeDisplayFormat)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if note.kind == .checklist, let progress = note.checklistProgress {
                ChecklistProgressBadge(done: progress.done, total: progress.total)
            } else {
                Text(note.previewText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glassInset(cornerRadius: 8, isHovered: isHovered)
        .offset(y: isHovered ? -1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

/// Compact "3/7" progress indicator shown on checklist cards.
struct ChecklistProgressBadge: View {
    let done: Int
    let total: Int

    private var fraction: Double {
        total == 0 ? 0 : Double(done) / Double(total)
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: total > 0 && done == total ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(total > 0 && done == total ? Color.accentColor : .secondary)
            Text("\(done)/\(total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Capsule()
                .fill(Color.glassInsetHover)
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(maxWidth: 80)
        }
    }
}
