import AppKit
import SwiftUI

/// What the create modal can make.
enum CreateKind: String, CaseIterable, Identifiable {
    case note, checklist, folder, link
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .note: "doc.text"
        case .checklist: "checklist"
        case .folder: "folder"
        case .link: "link"
        }
    }

    var titleKey: String { "create.\(rawValue)" }
    var hintKey: String { "create.\(rawValue).hint" }
}

/// Accent-filled "+" — the one bold control in the header. Opens the create modal.
struct AddButton: View {
    @Environment(NoteStore.self) private var noteStore
    @Environment(L10n.self) private var l10n
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                noteStore.isCreateModalPresented = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(isHovered ? 1 : 0.9), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .scaleEffect(isHovered ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(l10n["create.title"])
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovered = h } }
    }
}

/// "⋯" header control whose menu content is supplied by the caller.
struct HeaderMenuButton<Content: View>: View {
    let help: String
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.primary.opacity(isHovered ? 0.1 : 0))
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { isHovered = h } }
    }
}

/// In-panel modal: pick what to create, name it, create. Presented over the whole panel
/// by ContentView; dismissed by Cancel, Escape, or clicking the backdrop.
struct CreateItemModal: View {
    @Environment(NoteStore.self) private var noteStore
    @Environment(L10n.self) private var l10n

    @State private var kind: CreateKind = .note
    @State private var name = ""
    @State private var url = ""
    @State private var destination: String = ""
    @State private var showError = false
    @FocusState private var nameFocused: Bool
    @FocusState private var urlFocused: Bool

    /// Folder the new item goes in. Starts at the current folder; editable via the Where picker.
    private var folderName: String { destination }

    private var folderChoices: [String] {
        noteStore.folders.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var canCreate: Bool {
        switch kind {
        case .link: FavoriteURL.normalize(url) != nil
        case .folder: !name.trimmingCharacters(in: .whitespaces).isEmpty
        case .note, .checklist: true
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(l10n["create.title"])
                        .font(.system(.title3, design: .rounded).weight(.bold))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Color.glassInset, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                }

                // Type picker: 2×2 tiles
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(CreateKind.allCases) { k in
                        KindTile(kind: k, isSelected: kind == k, title: l10n[k.titleKey], hint: l10n[k.hintKey]) {
                            kind = k
                            showError = false
                            DispatchQueue.main.async { if k == .link { urlFocused = true } else { nameFocused = true } }
                        }
                    }
                }

                // Fields
                VStack(spacing: 8) {
                    if kind != .link {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(l10n["create.where"])
                                .foregroundStyle(.secondary)
                            Spacer()
                            Picker("", selection: $destination) {
                                Text(l10n["common.home"]).tag("")
                                ForEach(folderChoices, id: \.self) { f in
                                    Text(f).tag(f)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .fixedSize()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassInset(cornerRadius: 8)
                    }

                    if kind == .link {
                        field(icon: "link", placeholder: l10n["create.urlPlaceholder"], text: $url, focus: $urlFocused)
                    }
                    field(
                        icon: kind == .link ? "textformat" : kind.symbol,
                        placeholder: kind == .link ? l10n["create.linkTitlePlaceholder"] : l10n["create.namePlaceholder"],
                        text: $name,
                        focus: $nameFocused,
                    )
                }

                if showError {
                    Text(l10n["create.invalidURL"])
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button(l10n["common.cancel"]) { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Button {
                        create()
                    } label: {
                        Text(l10n["create.create"])
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(Color.accentColor.opacity(canCreate ? 1 : 0.4), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCreate)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(width: 320)
            .glassCard(cornerRadius: 16)
            .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .onAppear {
            destination = noteStore.selectedFolder?.name ?? ""
            if let pasted = FavoritesStore.pasteboardURL() {
                url = pasted.absoluteString
            }
            DispatchQueue.main.async { nameFocused = true }
        }
    }

    private func field(icon: String, placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused(focus)
                .onSubmit { if canCreate { create() } }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassInset(cornerRadius: 8)
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.18)) {
            noteStore.isCreateModalPresented = false
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .note, .checklist:
            let note = kind == .note ? noteStore.createNote(in: folderName) : noteStore.createChecklist(in: folderName)
            if !trimmed.isEmpty, !noteStore.noteTitleExists(trimmed, in: folderName, excluding: note.id) {
                noteStore.renameNote(note, to: trimmed)
            }
            dismiss()
            if let created = noteStore.notes.first(where: { $0.id == note.id }) {
                noteStore.openNote(created)
            }
        case .folder:
            guard !trimmed.isEmpty else { return }
            noteStore.createFolder(named: trimmed, in: folderName)
            dismiss()
        case .link:
            guard FavoritesStore.shared.add(rawURL: url, title: trimmed) != nil else {
                showError = true
                return
            }
            AppSettings.shared.linksCollapsed = false
            dismiss()
        }
    }
}

private struct KindTile: View {
    let kind: CreateKind
    let isSelected: Bool
    let title: String
    let hint: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(isSelected ? Color.accentColor : Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.14) : (isHovered ? Color.glassInsetHover : Color.glassInset))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.glassHairline.opacity(0.6), lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
    }
}
