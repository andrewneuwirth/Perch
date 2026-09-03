import AppKit
import SwiftUI

/// Header star that toggles the Favorites section on the Home screen.
struct FavoritesButton: View {
    @Environment(NoteStore.self) private var noteStore
    @Environment(L10n.self) private var l10n
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) {
                noteStore.showFavorites.toggle()
            }
        } label: {
            Image(systemName: noteStore.showFavorites ? "star.fill" : "star")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(noteStore.showFavorites ? Color.yellow : (isHovered ? .primary : .secondary))
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(.primary.opacity(isHovered ? 0.1 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(noteStore.showFavorites ? l10n["favorites.hide"] : l10n["favorites.show"])
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }
}

/// Collapsible list of favorite links shown above the folder list.
struct FavoritesSectionView: View {
    @Environment(L10n.self) private var l10n
    private var store = FavoritesStore.shared

    @State private var isAdding = false
    @State private var newURL = ""
    @State private var editingID: UUID?
    @State private var editText = ""
    @FocusState private var urlFocused: Bool
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Color.yellow)
                Text(l10n["favorites.title"])
                    .font(.subheadline.weight(.semibold))
                if !store.items.isEmpty {
                    Text("\(store.items.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    beginAdd()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(l10n["favorites.add"])
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)

            if store.items.isEmpty, !isAdding {
                Text(l10n["favorites.empty"])
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 4) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, fav in
                    LinkRowView(
                        label: fav.title,
                        url: fav.url,
                        isEditing: editingID == fav.id,
                        editText: $editText,
                        editFocus: $titleFocused,
                        onOpen: { store.open(fav) },
                        onEditLabel: {
                            editText = fav.title
                            editingID = fav.id
                            DispatchQueue.main.async { titleFocused = true }
                        },
                        onCommitLabel: {
                            store.rename(id: fav.id, to: editText)
                            editingID = nil
                        },
                        onCancelLabel: { editingID = nil },
                        onCopy: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fav.url.absoluteString, forType: .string)
                        },
                        onDelete: {
                            withAnimation(.easeInOut(duration: 0.15)) { store.remove(id: fav.id) }
                        },
                        onMoveUp: index > 0 ? { store.move(id: fav.id, direction: -1) } : nil,
                        onMoveDown: index < store.items.count - 1 ? { store.move(id: fav.id, direction: 1) } : nil,
                        copyLabel: l10n["favorites.copyLink"],
                        editLabel: l10n["favorites.editTitle"],
                        deleteLabel: l10n["common.delete"],
                    )
                }

                if isAdding {
                    HStack(spacing: 8) {
                        Image(systemName: "link.badge.plus")
                            .foregroundStyle(.secondary)
                        TextField(l10n["favorites.urlPlaceholder"], text: $newURL)
                            .textFieldStyle(.plain)
                            .focused($urlFocused)
                            .onSubmit(finishAdd)
                            .onExitCommand { isAdding = false; newURL = "" }
                            .onChange(of: urlFocused) { _, f in if !f, isAdding { finishAdd() } }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .glassInset(cornerRadius: 8)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private func beginAdd() {
        newURL = FavoritesStore.pasteboardURL()?.absoluteString ?? ""
        isAdding = true
        DispatchQueue.main.async { urlFocused = true }
    }

    private func finishAdd() {
        if FavoriteURL.normalize(newURL) != nil {
            withAnimation(.easeInOut(duration: 0.15)) { store.add(rawURL: newURL) }
        }
        isAdding = false
        newURL = ""
    }
}
