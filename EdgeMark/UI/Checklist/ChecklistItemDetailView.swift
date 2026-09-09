import AppKit
import SwiftUI

/// Detail page for a single checklist item: title, free-form notes, and links.
struct ChecklistItemDetailView: View {
    let item: ChecklistItem
    let onChange: (ChecklistItem) -> Void
    let onBack: () -> Void

    @Environment(L10n.self) private var l10n
    @State private var draft: ChecklistItem
    @State private var isAddingLink = false
    @State private var newLinkURL = ""
    @State private var editingLinkID: UUID?
    @State private var editLabelText = ""
    @FocusState private var linkFieldFocused: Bool
    @FocusState private var labelFieldFocused: Bool

    init(item: ChecklistItem, onChange: @escaping (ChecklistItem) -> Void, onBack: @escaping () -> Void) {
        self.item = item
        self.onChange = onChange
        self.onBack = onBack
        _draft = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Title row
                HStack(spacing: 10) {
                    CheckMarkerView(isDone: draft.isDone, size: 24) {
                        draft.isDone.toggle()
                        push()
                    }
                    TextField(l10n["common.untitled"], text: $draft.title)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .strikethrough(draft.isDone, color: .secondary)
                        .onSubmit { push() }
                        .onChange(of: draft.title) { _, _ in push() }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)

                // Notes
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(l10n["checklist.notes"], systemImage: "text.alignleft")
                    ZStack(alignment: .topLeading) {
                        if draft.notes.isEmpty {
                            Text(l10n["checklist.notesPlaceholder"])
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $draft.notes)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .background(.clear)
                            .frame(minHeight: 90)
                            .padding(4)
                            .onChange(of: draft.notes) { _, _ in push() }
                    }
                    .glassInset(cornerRadius: 8)
                }
                .padding(.horizontal, 16)

                // Links
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        sectionLabel(l10n["checklist.links"], systemImage: "link")
                        Spacer()
                        Button {
                            beginAddLink()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(l10n["checklist.addLink"])
                    }

                    VStack(spacing: 4) {
                        ForEach(draft.links) { link in
                            linkRow(link)
                        }
                        if isAddingLink {
                            HStack(spacing: 8) {
                                Image(systemName: "link.badge.plus")
                                    .foregroundStyle(.secondary)
                                TextField(l10n["checklist.urlPlaceholder"], text: $newLinkURL)
                                    .textFieldStyle(.plain)
                                    .focused($linkFieldFocused)
                                    .onSubmit(finishAddLink)
                                    .onExitCommand { isAddingLink = false; newLinkURL = "" }
                                    .onChange(of: linkFieldFocused) { _, f in if !f, isAddingLink { finishAddLink() } }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .glassInset(cornerRadius: 8)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .onChange(of: item) { _, new in
            // External reload (file changed on disk) — refresh draft if it differs
            if new != draft { draft = new }
        }
    }

    private func sectionLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func linkRow(_ link: ChecklistLink) -> some View {
        LinkRowView(
            label: link.label,
            url: link.url,
            isEditing: editingLinkID == link.id,
            editText: $editLabelText,
            editFocus: $labelFieldFocused,
            onOpen: { NSWorkspace.shared.open(link.url) },
            onEditLabel: {
                editLabelText = link.label
                editingLinkID = link.id
                DispatchQueue.main.async { labelFieldFocused = true }
            },
            onCommitLabel: {
                let t = editLabelText.trimmingCharacters(in: .whitespaces)
                if let i = draft.links.firstIndex(where: { $0.id == link.id }) {
                    draft.links[i].label = t.isEmpty ? ChecklistLink.defaultLabel(for: link.url) : t
                    push()
                }
                editingLinkID = nil
            },
            onCancelLabel: { editingLinkID = nil },
            onCopy: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            },
            onDelete: {
                withAnimation(.easeInOut(duration: 0.15)) { draft.links.removeAll { $0.id == link.id } }
                push()
            },
            onMoveUp: draft.links.first?.id == link.id ? nil : { moveLink(link.id, by: -1) },
            onMoveDown: draft.links.last?.id == link.id ? nil : { moveLink(link.id, by: 1) },
            copyLabel: l10n["checklist.copyLink"],
            editLabel: l10n["checklist.editLabel"],
            deleteLabel: l10n["common.delete"],
        )
    }

    private func moveLink(_ id: UUID, by direction: Int) {
        guard let from = draft.links.firstIndex(where: { $0.id == id }) else { return }
        let to = from + direction
        guard draft.links.indices.contains(to) else { return }
        withAnimation(.easeInOut(duration: 0.15)) { draft.links.swapAt(from, to) }
        push()
    }

    private func beginAddLink() {
        newLinkURL = FavoritesStore.pasteboardURL()?.absoluteString ?? ""
        isAddingLink = true
        DispatchQueue.main.async { linkFieldFocused = true }
    }

    private func finishAddLink() {
        if let url = FavoriteURL.normalize(newLinkURL) {
            withAnimation(.easeInOut(duration: 0.15)) {
                draft.links.append(ChecklistLink(label: ChecklistLink.defaultLabel(for: url), url: url))
            }
            push()
        }
        isAddingLink = false
        newLinkURL = ""
    }

    private func push() {
        onChange(draft)
    }
}

/// Shared link row used by checklist item details and the favorites section.
struct LinkRowView: View {
    let label: String
    let url: URL
    var isEditing: Bool = false
    var editText: Binding<String> = .constant("")
    var editFocus: FocusState<Bool>.Binding
    let onOpen: () -> Void
    let onEditLabel: () -> Void
    let onCommitLabel: () -> Void
    let onCancelLabel: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    let copyLabel: String
    let editLabel: String
    let deleteLabel: String

    @State private var isHovered = false

    private var host: String {
        FavoriteURL.defaultTitle(for: url)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.callout)
                .foregroundStyle(isHovered ? Color.accentColor : .secondary)
                .frame(width: 18)

            if isEditing {
                TextField("", text: editText)
                    .textFieldStyle(.plain)
                    .focused(editFocus)
                    .onSubmit(onCommitLabel)
                    .onExitCommand(perform: onCancelLabel)
                    .onChange(of: editFocus.wrappedValue) { _, f in if !f, isEditing { onCommitLabel() } }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.body)
                        .lineLimit(1)
                    if label != host {
                        Text(host)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
                RowTrashButton(visible: isHovered, action: onDelete)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassInset(cornerRadius: 8, isHovered: isHovered)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
        .onTapGesture { if !isEditing { onOpen() } }
        .help(url.absoluteString)
        .contextMenu {
            Button { onOpen() } label: { Label(L10n.shared["common.open"], systemImage: "safari") }
            Button { onCopy() } label: { Label(copyLabel, systemImage: "doc.on.doc") }
            Button { onEditLabel() } label: { Label(editLabel, systemImage: "pencil") }
            if onMoveUp != nil || onMoveDown != nil {
                Divider()
                if let onMoveUp { Button { onMoveUp() } label: { Label(L10n.shared["checklist.moveUp"], systemImage: "arrow.up") } }
                if let onMoveDown { Button { onMoveDown() } label: { Label(L10n.shared["checklist.moveDown"], systemImage: "arrow.down") } }
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label(deleteLabel, systemImage: "trash") }
        }
    }
}
