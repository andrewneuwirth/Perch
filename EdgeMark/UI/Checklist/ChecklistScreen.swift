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
    @State private var isArchivedExpanded = false
    /// One debouncer per item mid-countdown: checked-off items waiting to auto-archive,
    /// archived items waiting to auto-restore. Keyed by item id so re-toggling the same
    /// item within the window cancels and restarts (or cancels outright) its own timer
    /// without touching anyone else's.
    @State private var archiveDebouncers: [UUID: Debouncer] = [:]
    @State private var restoreDebouncers: [UUID: Debouncer] = [:]
    private let archiveDelay: TimeInterval = 3.0
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
            listBody
        }
        .onAppear {
            noteStore.onNeedEditorReload = { content in
                cancelAllPendingArchiving()
                doc = ChecklistDocument.parse(content)
            }
        }
        .onDisappear {
            cancelAllPendingArchiving()
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
                        goBack()
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
                            cancelAllPendingArchiving()
                            withAnimation(.easeInOut(duration: 0.2)) { doc.clearCompleted() }
                            commit()
                        } label: {
                            Label(l10n["checklist.clearCompleted"], systemImage: "trash.slash")
                        }
                        .disabled(doc.doneCount == 0)
                        Button {
                            noteStore.convertChecklistToNote(note)
                        } label: {
                            Label(l10n["checklist.convertToNote"], systemImage: "doc.text")
                        }
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

                if !doc.groups.isEmpty {
                    addGroupRow
                }

                if !doc.archived.isEmpty {
                    archivedSection
                }
            }
            .padding(.vertical, 8)
        }
    }

    /// Completed items that sat checked-off long enough to auto-archive.
    /// Collapsed by default — this is meant to be out of the way, not a second list.
    private var archivedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isArchivedExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isArchivedExpanded ? 90 : 0))
                    Image(systemName: "archivebox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(l10n["checklist.archived"])
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(doc.archived.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isArchivedExpanded {
                ForEach(doc.archived) { item in
                    ChecklistRowView(
                        item: item,
                        onToggle: { toggleArchivedItem(item) },
                        onOpen: {},
                        onRename: { _ in },
                        onDelete: {
                            restoreDebouncers[item.id]?.cancel()
                            restoreDebouncers[item.id] = nil
                            withAnimation(.easeInOut(duration: 0.2)) { doc.removeArchivedItem(id: item.id) }
                            commit()
                        },
                        moveTargets: [],
                        onMove: { _ in },
                        canRename: false,
                    )
                }
                .padding(.bottom, 4)
            }
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
                    onToggle: { toggleItem(item) },
                    onOpen: {},
                    onRename: { newTitle in
                        var updated = item
                        updated.title = newTitle
                        doc.update(updated)
                        commit()
                    },
                    onDelete: {
                        archiveDebouncers[item.id]?.cancel()
                        archiveDebouncers[item.id] = nil
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

    // MARK: - Archiving

    /// Check an item off (or back on). If it's now done, start the
    /// auto-archive countdown; re-toggling it off before the countdown ends
    /// (this cancels via the same code path) is the undo.
    private func toggleItem(_ item: ChecklistItem) {
        archiveDebouncers[item.id]?.cancel()
        archiveDebouncers[item.id] = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            doc.toggle(itemID: item.id)
        }
        commit()
        guard doc.item(id: item.id)?.isDone == true else { return }

        let id = item.id
        let debouncer = Debouncer(delay: archiveDelay)
        archiveDebouncers[id] = debouncer
        debouncer.call { [self] in
            guard doc.item(id: id)?.isDone == true else { return }
            withAnimation(.easeInOut(duration: 0.3)) { doc.archiveItem(id: id) }
            commit()
            archiveDebouncers[id] = nil
        }
    }

    /// Un-check an archived item (or re-check it). If it's now not done, start
    /// the auto-restore countdown back to its original group.
    private func toggleArchivedItem(_ item: ChecklistItem) {
        restoreDebouncers[item.id]?.cancel()
        restoreDebouncers[item.id] = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            doc.toggleArchivedDone(id: item.id)
        }
        commit()
        guard doc.archived.first(where: { $0.id == item.id })?.isDone == false else { return }

        let id = item.id
        let debouncer = Debouncer(delay: archiveDelay)
        restoreDebouncers[id] = debouncer
        debouncer.call { [self] in
            guard doc.archived.first(where: { $0.id == id })?.isDone == false else { return }
            withAnimation(.easeInOut(duration: 0.3)) { doc.restoreItem(id: id) }
            commit()
            restoreDebouncers[id] = nil
        }
    }

    /// Stop every pending archive/restore countdown without applying them —
    /// called when the note closes or its content is replaced out from under
    /// us, so a timer never fires against a `doc` the user has moved on from.
    private func cancelAllPendingArchiving() {
        for d in archiveDebouncers.values { d.cancel() }
        for d in restoreDebouncers.values { d.cancel() }
        archiveDebouncers.removeAll()
        restoreDebouncers.removeAll()
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
        cancelAllPendingArchiving()
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
    /// False for archived rows — their title isn't a live document position,
    /// so renaming would silently discard whatever was typed.
    var canRename: Bool = true

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
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { if canRename { beginRename() } }

                Spacer(minLength: 4)

                if !item.links.isEmpty {
                    Button {
                        if let url = item.links.first?.url { NSWorkspace.shared.open(url) }
                    } label: {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.links.first?.url.absoluteString ?? "")
                }
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
            if canRename {
                Button { beginRename() } label: { Label(l10n["common.rename"], systemImage: "pencil") }
            }
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
