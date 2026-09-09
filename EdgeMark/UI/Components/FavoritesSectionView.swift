import AppKit
import SwiftUI

/// "Links" section at the top of Home. Always present; collapsible; the chevron state is remembered.
struct LinksSectionView: View {
    @Environment(L10n.self) private var l10n
    @Environment(AppSettings.self) private var appSettings
    @Environment(NoteStore.self) private var noteStore
    private var store = FavoritesStore.shared

    @State private var editingID: UUID?
    @State private var editText = ""
    @State private var isHeaderHovered = false
    @FocusState private var titleFocused: Bool

    private var collapsed: Bool { appSettings.linksCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appSettings.linksCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                        .frame(width: 12)
                    Text(l10n["links.title"])
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundStyle(.secondary)
                    if !store.items.isEmpty {
                        Text("\(store.items.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        noteStore.isCreateModalPresented = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Color.glassInset, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(l10n["create.link"])
                    .opacity(isHeaderHovered || store.items.isEmpty ? 1 : 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHeaderHovered = $0 }

            if !collapsed {
                if store.items.isEmpty {
                    Text(l10n["links.empty"])
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 36)
                        .padding(.bottom, 8)
                } else {
                    VStack(spacing: 3) {
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
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
        }
    }
}

