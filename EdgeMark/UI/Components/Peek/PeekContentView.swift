import SwiftUI

/// Read-only preview body for the peek window. Renders a `Note` via the
/// engine-backed `ReadOnlyMarkdownView`, or a `Folder` as a compact
/// child-note list (header + rows styled like `NoteRowView`).
struct PeekContentView: View {
    @Environment(L10n.self) var l10n
    let content: PeekContent

    var body: some View {
        switch content {
        case let .note(note):
            notePreview(note)
        case let .folder(folder, subfolders, notes):
            folderPreview(folder: folder, subfolders: subfolders, notes: notes)
        }
    }

    // MARK: - Note

    private func notePreview(_ note: Note) -> some View {
        ReadOnlyMarkdownView(content: note.content, noteFolder: note.folder)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Folder

    private func folderPreview(folder: Folder, subfolders: [Folder], notes: [Note]) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(folder.color?.color ?? Color.accentColor)
                Text(folder.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text("\(folder.noteCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if subfolders.isEmpty, notes.isEmpty {
                emptyFolderPlaceholder
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Subfolders
                        ForEach(subfolders) { subfolder in
                            subfolderRow(subfolder)
                            Divider()
                                .padding(.horizontal, 16)
                        }
                        // Notes
                        ForEach(notes) { note in
                            folderNoteRow(note)
                            if note.id != notes.last?.id {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Compact row for a subfolder inside a folder preview.
    private func subfolderRow(_ subfolder: Folder) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(subfolder.color?.color ?? Color.accentColor)
                .frame(width: 22)

            Text(subfolder.displayName)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Text("\(subfolder.noteCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyFolderPlaceholder: some View {
        VStack(spacing: 6) {
            Spacer().frame(height: 32)
            Image(systemName: "folder")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(l10n["peek.emptyFolder"])
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Compact row for a child note inside a folder preview. Matches NoteRowView:
    /// check marker, wrapping title, done styling. Toggling posts a request that the
    /// note store handles, since the peek window has no store in its environment.
    private func folderNoteRow(_ note: Note) -> some View {
        PeekNoteRow(note: note)
    }
}

private struct PeekNoteRow: View {
    let note: Note
    @State private var isDone: Bool
    @State private var isHovered = false

    init(note: Note) {
        self.note = note
        _isDone = State(initialValue: note.isDone)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CheckMarkerView(isDone: isDone, size: 20) {
                isDone.toggle()
                NotificationCenter.default.post(name: .noteToggleDoneRequested, object: note.id)
            }
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    TagDotsView(tags: note.tags)
                    Text(note.title.isEmpty ? L10n.shared["common.untitled"] : note.title)
                        .font(.body)
                        .foregroundStyle(isDone ? .secondary : .primary)
                        .strikethrough(isDone, color: .secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(note.modifiedAt.homeDisplayFormat)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                    RowTrashButton(visible: isHovered) {
                        NotificationCenter.default.post(name: .noteTrashRequested, object: note.id)
                    }
                }
                if !note.previewText.isEmpty {
                    Text(note.previewText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(isDone ? 0.7 : 1)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
