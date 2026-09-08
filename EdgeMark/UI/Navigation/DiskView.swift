import Cocoa
import SwiftUI

/// Disk-space screen. Opened from the footer pill; the only place the app
/// ever walks directories. Scans on appear, cancels on disappear.
struct DiskView: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(L10n.self) var l10n

    @State private var model = DiskUsageModel()
    @State private var pendingDelete: DiskUsageModel.Item?
    @State private var deleteError: String?
    @State private var isDeleting = false

    private let iconWidth: CGFloat = 22

    var body: some View {
        PageLayout(onSwipeBack: { noteStore.closeDisk() }) {
            HStack {
                HeaderIconButton(systemName: "chevron.left", help: l10n["common.back"]) {
                    noteStore.closeDisk()
                }
                Spacer()
                PinButton()
                HeaderIconButton(systemName: "arrow.clockwise", help: l10n["disk.rescan"]) {
                    model.scan()
                }
                .disabled(model.isScanning)
                .opacity(model.isScanning ? 0.3 : 1)
            }
            .overlay {
                Text(l10n["disk.title"])
                    .font(.headline)
            }
        } content: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        volumeSummary
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 10)

                        Divider().padding(.horizontal, 12)

                        ForEach(model.items) { item in
                            targetRow(item)
                            if item.isExpanded {
                                childrenList(for: item)
                            }
                        }
                        .padding(.vertical, 6)

                        if model.items.isEmpty, !model.isScanning {
                            Text(l10n["disk.nothingFound"])
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 24)
                        }
                    }
                }

                Divider().padding(.horizontal, 12)

                ContentFooterBar()
            }
        }
        .onAppear { model.scan() }
        .onDisappear { model.cancel() }
        .alert(l10n["alert.disk.delete.title"], isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } },
        ), presenting: pendingDelete) { item in
            Button(l10n["common.deletePermanently"], role: .destructive) {
                confirmDelete(item)
            }
            Button(l10n["common.cancel"], role: .cancel) {}
        } message: { item in
            Text(deleteMessage(for: item))
        }
        .alert(l10n["alert.disk.failed.title"], isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } },
        )) {
            Button(l10n["common.ok"], role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Volume summary

    @ViewBuilder
    private var volumeSummary: some View {
        if let v = model.volume {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(v.free.diskSizeString)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(v.isLow ? Color.red : Color.primary)
                    Text(l10n["disk.free"])
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(l10n.t("disk.usedOf", v.used.diskSizeString, v.total.diskSizeString))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.glassInset)
                        Capsule()
                            .fill(v.isLow ? Color.red : Color.accentColor)
                            .frame(width: max(geo.size.width * v.usedFraction, 4))
                        // What the listed folders account for, on the same scale.
                        if model.measuredTotal > 0 {
                            Capsule()
                                .fill(Color.orange.opacity(0.85))
                                .frame(width: max(geo.size.width * Double(model.measuredTotal) / Double(v.total), 2))
                        }
                    }
                }
                .frame(height: 6)

                HStack(spacing: 6) {
                    Circle().fill(Color.orange.opacity(0.85)).frame(width: 6, height: 6)
                    Text(model.isScanning
                        ? l10n["disk.scanning"]
                        : l10n.t("disk.measured", model.measuredTotal.diskSizeString))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if model.isScanning {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func targetRow(_ item: DiskUsageModel.Item) -> some View {
        DiskRowView(
            item: item,
            iconWidth: iconWidth,
            indent: 0,
            isExpandable: item.isDirectory,
            onTap: { model.toggleExpanded(item.id) },
            onDelete: item.risk == .viewOnly ? nil : { pendingDelete = item },
        )
        .nsContextMenu { [l10n] in
            let menu = NSMenu()
            menu.addActionItem(title: l10n["common.showInFinder"], icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            if item.risk != .viewOnly {
                menu.addItem(.separator())
                menu.addActionItem(title: l10n["common.deletePermanently"], icon: "trash.slash") {
                    pendingDelete = item
                }
            }
            return menu
        }
    }

    @ViewBuilder
    private func childrenList(for parent: DiskUsageModel.Item) -> some View {
        if let children = parent.children {
            if children.isEmpty {
                Text(l10n["disk.empty"])
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16 + iconWidth + 10 + 18)
                    .padding(.vertical, 6)
            }
            ForEach(children) { child in
                DiskRowView(
                    item: child,
                    iconWidth: iconWidth,
                    indent: 18,
                    isExpandable: false,
                    onTap: { NSWorkspace.shared.activateFileViewerSelecting([child.url]) },
                    onDelete: { pendingDelete = child },
                )
                .nsContextMenu { [l10n] in
                    let menu = NSMenu()
                    menu.addActionItem(title: l10n["common.showInFinder"], icon: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([child.url])
                    }
                    menu.addItem(.separator())
                    menu.addActionItem(title: l10n["common.deletePermanently"], icon: "trash.slash") {
                        pendingDelete = child
                    }
                    return menu
                }
            }
        } else if parent.isLoadingChildren {
            HStack {
                ProgressView().controlSize(.small)
                Text(l10n["disk.scanning"])
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 16 + iconWidth + 10 + 18)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Delete

    private func deleteMessage(for item: DiskUsageModel.Item) -> String {
        let size = item.size.bytes?.diskSizeString ?? "—"
        let what = item.deletesContents
            ? l10n.t("alert.disk.delete.contents", item.name, size)
            : l10n.t("alert.disk.delete.item", item.name, size)
        let risk: String = switch item.risk {
        case .safe: l10n["disk.risk.safe"]
        case .caution: l10n["disk.risk.caution"]
        case .destructive: l10n["disk.risk.destructive"]
        case .viewOnly: ""
        }
        return risk.isEmpty ? what : "\(what)\n\n\(risk)"
    }

    private func confirmDelete(_ item: DiskUsageModel.Item) {
        guard !isDeleting else { return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                try await model.delete(item)
            } catch {
                deleteError = error.localizedDescription
            }
        }
    }
}

// MARK: - Row

private struct DiskRowView: View {
    let item: DiskUsageModel.Item
    let iconWidth: CGFloat
    let indent: CGFloat
    let isExpandable: Bool
    let onTap: () -> Void
    let onDelete: (() -> Void)?

    @State private var isHovered = false

    private var riskTint: Color? {
        switch item.risk {
        case .destructive: .red
        case .caution: .orange
        case .safe, .viewOnly: nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: iconWidth)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(indent > 0 ? .callout : .body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail = item.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    sizeLabel

                    if isExpandable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(item.isExpanded ? 90 : 0))
                            .frame(width: 12)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onDelete {
                RowTrashButton(visible: isHovered, action: onDelete)
            } else {
                Color.clear.frame(width: 24, height: 24)
            }
        }
        .padding(.leading, 16 + indent)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background(isHovered ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
        .help(item.url.path)
    }

    @ViewBuilder
    private var sizeLabel: some View {
        switch item.size {
        case .pending:
            Text("—").font(.caption).foregroundStyle(.quaternary).monospacedDigit()
        case .scanning:
            ProgressView().controlSize(.mini)
        case let .done(bytes):
            Text(bytes.diskSizeString)
                .font(.system(.callout, design: .rounded, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(riskTint ?? .secondary)
        case .failed:
            Image(systemName: "questionmark")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
