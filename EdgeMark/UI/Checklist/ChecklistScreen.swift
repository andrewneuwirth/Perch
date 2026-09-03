import AppKit
import SwiftUI

/// Native list UI for `NoteKind.checklist` notes. Replaces the markdown editor.
/// Every edit re-serializes the in-memory `ChecklistDocument` back into the note's markdown.
struct ChecklistScreen: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(AppSettings.self) var appSettings
    @Environment(L10n.self) var l10n

    let noteID: UUID
    @State private var doc: ChecklistDocument
    @State private var openItemID: UUID?
    @State private var showDeleteConfirm = false
    @State private var groupPendingDelete: ChecklistGroup?
    @State private var isAddingGroup = false
    @State private var newGroupName = ""
    @State private var renamingGroupID: UUID?
    @State private var renameGroupText = ""
    @State private var saveDebouncer = Debouncer(delay: 1.0)
    @FocusState private var newGroupFocused: Bool
    @FocusState private var renameGroupFocused: Bool

    init(note: Note) {
        noteID = note.id
        _doc = State(initialValue: ChecklistDocument.parse(note.content))
    }

    private var note: Note? { noteStore.selectedNote }

    private var backLabel: String {
        noteStore.selectedFolder?.name ?? l10n["common.home"]
    }

    var body: some View {
        PageLayout(onSwipeBack: { goBack() }) {
            header
        } content: {
            ZStack {
                if let id = openItemID, let item = doc.item(id: id) {
                    ChecklistItemDetailView(
                        item: item,
                        onChange: { updated in
                            doc.update(updated)
                            commit()
                        },
                        onBack: { withAnimation(.easeInOut(duration: 0.2)) { openItemID = nil } },
                    )
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                } else {
                    listBody
                        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
                }
            }
            .clipped()
        }
        .onAppear {
            noteStore.onNeedEditorReload = { content in
                doc = ChecklistDocument.parse(content)
            }
        }
        .alert(l10n["alert.deleteNote.title"], isPresented: $showDeleteConfirm) {
            Button(l10n["common.delete"], role: .destructive) {
                if let note {
                    noteStore.closeNote()
                    noteStore.deleteNote(note)
                }
            }
            Button(l10n["common.cancel"], role: .cancel) {}
        }
        .alert(
            l10n["checklist.deleteGroup.title"],
            isPresented: Binding(get: { groupPendingDelete != nil }, set: { if !$0 { groupPendingDelete = nil } }),
        ) {
            Button(l10n["common.delete"], role: .destructive) {
                if let g = groupPendingDelete {
                    doc.removeGroup(id: g.id)
                    commit()
                }
                groupPendingDelete = nil
            }
            Button(l10n["common.cancel"], role: .cancel) { groupPendingDelete = nil }
        } message: {
            Text(l10n.t("checklist.deleteGroup.message", String(groupPendingDelete?.items.count ?? 0)))
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let note {
            VStack(spacing: 6) {
                HStack {
                    HeaderIconButton(systemName: "chevron.left", help: backLabel) {
                        if openItemID != nil {
                            withAnimation(.easeInOut(duration: 0.2)) { openItemID = nil }
                        } else {
                            goBack()
                        }
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(note.title.isEmpty ? l10n["common.untitled"] : note.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(note.displayDirectory)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    HeaderMenuButton(help: l10n["header.more"]) {
                        PinMenuItem()
                        Divider()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { doc.clearCompleted() }
                            commit()
                        } label: {
                            Label(l10n["checklist.clearCompleted"], systemImage: "trash.slash")
                        }
                        .disabled(doc.doneCount == 0)
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label(l10n["editor.deleteNote"], systemImage: "trash")
                        }
                    }
                }

                HStack(spacing: 8) {
                    Capsule()
                        .fill(Color.glassInsetHover)
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Color.accentColor.opacity(0.85))
                                    .frame(width: geo.size.width * progressFraction)
                                    .animation(.easeInOut(duration: 0.25), value: progressFraction)
                            }
                        }
                    Text(l10n.t("checklist.progress", String(doc.doneCount), String(doc.totalCount)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
    }

    private var progressFraction: Double {
        doc.totalCount == 0 ? 0 : Double(doc.doneCount) / Double(doc.totalCount)
    }

    // MARK: - List

    private var listBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if doc.ungrouped.isEmpty, doc.groups.isEmpty {
                    Text(l10n["checklist.empty"])
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }

                groupSection(group: nil)

                ForEach(doc.groups) { group in
                    groupSection(group: group)
                }

                addGroupRow
            }
            .padding(.vertical, 8)
        }
    }

    /// Section for one group (nil = ungrouped items).
    @ViewBuilder
    private func groupSection(group: ChecklistGroup?) -> some View {
        let groupIndex: Int? = group.flatMap { g in doc.groups.firstIndex(where: { $0.id == g.id }) }
        let items = doc.items(inGroup: groupIndex)

        if let group {
            groupHeader(group)
        }

        if group != nil || !items.isEmpty {
            ForEach(items) { item in
                ChecklistRowView(
                    item: item,
                    onToggle: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            doc.toggle(itemID: item.id)
                        }
                        commit()
                    },
                    onOpen: { withAnimation(.easeInOut(duration: 0.2)) { openItemID = item.id } },
                    onRename: { newTitle in
                        var updated = item
                        updated.title = newTitle
                        doc.update(updated)
                        commit()
                    },
                    onDelete: {
                        withAnimation(.easeInOut(duration: 0.2)) { doc.removeItem(id: item.id) }
                        commit()
                    },
                    moveTargets: moveTargets(excluding: groupIndex),
                    onMove: { target in
                        withAnimation(.easeInOut(duration: 0.2)) { doc.moveItem(id: item.id, toGroup: target) }
                        commit()
                    },
                )
            }

            AddItemField(placeholder: l10n["checklist.addItem"]) { title in
                withAnimation(.easeInOut(duration: 0.15)) {
                    doc.addItem(title: title, toGroup: groupIndex)
                }
                commit()
            }
            .padding(.bottom, group == nil ? 8 : 4)
        }
    }

    /// (label, group index) pairs an item can be moved to.
    private func moveTargets(excluding current: Int?) -> [(String, Int?)] {
        var targets: [(String, Int?)] = []
        if current != nil { targets.append((l10n["checklist.ungrouped"], nil)) }
        for (i, g) in doc.groups.enumerated() where i != current {
            targets.append((g.name, i))
        }
        return targets
    }

    private func groupHeader(_ group: ChecklistGroup) -> some View {
        HStack(spacing: 6) {
            if renamingGroupID == group.id {
                TextField(l10n["checklist.groupName"], text: $renameGroupText)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.semibold))
                    .focused($renameGroupFocused)
                    .onSubmit { finishRenameGroup(group) }
                    .onExitCommand { renamingGroupID = nil }
                    .onChange(of: renameGroupFocused) { _, focused in
                        if !focused, renamingGroupID == group.id { finishRenameGroup(group) }
                    }
            } else {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                let done = group.items.filter(\.isDone).count
                if !group.items.isEmpty {
                    Text("\(done)/\(group.items.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button { beginRenameGroup(group) } label: { Label(l10n["checklist.renameGroup"], systemImage: "pencil") }
            Button { doc.moveGroup(id: group.id, direction: -1); commit() } label: { Label(l10n["checklist.moveUp"], systemImage: "arrow.up") }
                .disabled(doc.groups.first?.id == group.id)
            Button { doc.moveGroup(id: group.id, direction: 1); commit() } label: { Label(l10n["checklist.moveDown"], systemImage: "arrow.down") }
                .disabled(doc.groups.last?.id == group.id)
            Divider()
            Button(role: .destructive) {
                if group.items.isEmpty {
                    withAnimation(.easeInOut(duration: 0.2)) { doc.removeGroup(id: group.id) }
                    commit()
                } else {
                    groupPendingDelete = group
                }
            } label: { Label(l10n["checklist.deleteGroup"], systemImage: "trash") }
        }
    }

    private var addGroupRow: some View {
        Group {
            if isAddingGroup {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .foregroundStyle(.secondary)
                    TextField(l10n["checklist.groupName"], text: $newGroupName)
                        .textFieldStyle(.plain)
                        .focused($newGroupFocused)
                        .onSubmit(finishAddGroup)
                        .onExitCommand { isAddingGroup = false; newGroupName = "" }
                        .onChange(of: newGroupFocused) { _, focused in
                            if !focused, isAddingGroup { finishAddGroup() }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else {
                Button {
                    isAddingGroup = true
                    newGroupName = ""
                    DispatchQueue.main.async { newGroupFocused = true }
                } label: {
                    Label(l10n["checklist.addGroup"], systemImage: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.top, 10)
            }
        }
    }

    // MARK: - Actions

    private func beginRenameGroup(_ group: ChecklistGroup) {
        renameGroupText = group.name
        renamingGroupID = group.id
        DispatchQueue.main.async { renameGroupFocused = true }
    }

    private func finishRenameGroup(_ group: ChecklistGroup) {
        let name = renameGroupText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { doc.renameGroup(id: group.id, to: name); commit() }
        renamingGroupID = nil
    }

    private func finishAddGroup() {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            withAnimation(.easeInOut(duration: 0.15)) { doc.addGroup(name: name) }
            commit()
        }
        isAddingGroup = false
        newGroupName = ""
    }

    private func commit() {
        var d = doc
        if let title = note?.title, !title.isEmpty { d.title = title }
        noteStore.updateContent(for: noteID, content: d.serialize())
        saveDebouncer.call { [noteStore] in noteStore.saveDirtyNotes() }
    }

    private func goBack() {
        saveDebouncer.cancel()
        noteStore.closeNote()
    }
}

// MARK: - Row

private struct ChecklistRowView: View {
    let item: ChecklistItem
    let onToggle: () -> Void
    let onOpen: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let moveTargets: [(String, Int?)]
    let onMove: (Int?) -> Void

    @Environment(L10n.self) private var l10n
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var hasDetails: Bool {
        !item.notes.isEmpty || !item.links.isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            CheckMarkerView(isDone: item.isDone, action: onToggle)

            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($renameFocused)
                    .onSubmit(finishRename)
                    .onExitCommand { isRenaming = false }
                    .onChange(of: renameFocused) { _, f in if !f, isRenaming { finishRename() } }
            } else {
                Text(item.title)
                    .font(.body)
                    .strikethrough(item.isDone, color: .secondary)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginRename() }
                    .onTapGesture(count: 1) { onOpen() }

                Spacer(minLength: 4)

                if hasDetails {
                    HStack(spacing: 4) {
                        if !item.notes.isEmpty {
                            Image(systemName: "text.alignleft")
                        }
                        if !item.links.isEmpty {
                            Image(systemName: "link")
                            Text("\(item.links.count)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .opacity(item.isDone ? 0.6 : 1)
        .glassInset(cornerRadius: 8, isHovered: isHovered)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
        .contextMenu {
            Button { onOpen() } label: { Label(l10n["checklist.openDetail"], systemImage: "info.circle") }
            Button { beginRename() } label: { Label(l10n["common.rename"], systemImage: "pencil") }
            if !moveTargets.isEmpty {
                Menu {
                    ForEach(Array(moveTargets.enumerated()), id: \.offset) { _, target in
                        Button(target.0) { onMove(target.1) }
                    }
                } label: {
                    Label(l10n["checklist.moveToGroup"], systemImage: "folder")
                }
            }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label(l10n["common.delete"], systemImage: "trash") }
        }
    }

    private func beginRename() {
        renameText = item.title
        isRenaming = true
        DispatchQueue.main.async { renameFocused = true }
    }

    private func finishRename() {
        let t = renameText.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, t != item.title { onRename(t) }
        isRenaming = false
    }
}

// MARK: - Add item field

private struct AddItemField: View {
    let placeholder: String
    let onCommit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(focused ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 22)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    onCommit(t)
                    text = ""
                    // Keep focus for rapid entry
                    DispatchQueue.main.async { focused = true }
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }
}
