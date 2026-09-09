import Cocoa
import SwiftUI

/// Memory screen — what's eating RAM right now, grouped by app. Twin of
/// `DiskView`: samples on appear, stops on disappear, and never runs while the
/// panel is closed. Read-only by design; killing processes is Activity
/// Monitor's job, not a notes app's.
struct MemoryView: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(L10n.self) var l10n

    @State private var model = MemoryUsageModel()

    private let iconWidth: CGFloat = 22

    var body: some View {
        PageLayout(onSwipeBack: { noteStore.closeMemory() }) {
            HStack {
                HeaderIconButton(systemName: "chevron.left", help: l10n["common.back"]) {
                    noteStore.closeMemory()
                }
                Spacer()
                PinButton()
                HeaderIconButton(systemName: "arrow.clockwise", help: l10n["memory.resample"]) {
                    Task { await model.refresh() }
                }
                .disabled(model.isSampling)
                .opacity(model.isSampling ? 0.3 : 1)
            }
            .overlay {
                Text(l10n["memory.title"])
                    .font(.headline)
            }
        } content: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        systemSummary
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 10)

                        Divider().padding(.horizontal, 12)

                        ForEach(model.sample.apps) { app in
                            appRow(app)
                            if model.isExpanded(app.appName) {
                                processList(for: app)
                            }
                        }
                        .padding(.vertical, 6)

                        if model.sample.apps.isEmpty, model.hasSampled {
                            Text(l10n["memory.nothingFound"])
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 24)
                        }

                        if model.sample.denied > 0 {
                            Text(l10n.t("memory.denied", "\(model.sample.denied)"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.top, 4)
                                .padding(.bottom, 14)
                        }
                    }
                }

                Divider().padding(.horizontal, 12)

                ContentFooterBar()
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - System summary

    @ViewBuilder
    private var systemSummary: some View {
        if let s = model.system {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(s.used.memorySizeString)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(s.isUnderPressure ? Color.red : Color.primary)
                    Text(l10n["memory.used"])
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(l10n.t("memory.ofTotal", s.total.memorySizeString))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.glassInset)
                        Capsule()
                            .fill(s.isUnderPressure ? Color.red : Color.accentColor)
                            .frame(width: max(geo.size.width * s.usedFraction, 4))
                        // Compressed memory rides on the same scale — when this
                        // band grows the machine is running out of room.
                        if s.compressed > 0, s.total > 0 {
                            Capsule()
                                .fill(Color.orange.opacity(0.85))
                                .frame(width: max(geo.size.width * Double(s.compressed) / Double(s.total), 2))
                        }
                    }
                }
                .frame(height: 6)

                HStack(spacing: 6) {
                    Circle().fill(Color.orange.opacity(0.85)).frame(width: 6, height: 6)
                    Text(breakdown(s))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if model.isSampling {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
        }
    }

    private func breakdown(_ s: MemoryUsageModel.SystemMemory) -> String {
        var parts = [
            l10n.t("memory.breakdown.app", s.app.memorySizeString),
            l10n.t("memory.breakdown.wired", s.wired.memorySizeString),
            l10n.t("memory.breakdown.compressed", s.compressed.memorySizeString),
        ]
        if s.swapUsed > 0 {
            parts.append(l10n.t("memory.breakdown.swap", s.swapUsed.memorySizeString))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Rows

    private func appRow(_ app: AppMemory) -> some View {
        MemoryRowView(
            name: app.appName,
            detail: app.isExpandable ? l10n.t("memory.processCount", "\(app.processes.count)") : nil,
            footprint: app.footprint,
            icon: "app.dashed",
            iconWidth: iconWidth,
            indent: 0,
            isExpandable: app.isExpandable,
            isExpanded: model.isExpanded(app.appName),
            onTap: { if app.isExpandable { model.toggleExpanded(app.appName) } },
        )
    }

    @ViewBuilder
    private func processList(for app: AppMemory) -> some View {
        ForEach(app.processes) { process in
            MemoryRowView(
                name: process.name,
                detail: l10n.t("memory.pid", "\(process.pid)"),
                footprint: process.footprint,
                icon: "gearshape",
                iconWidth: iconWidth,
                indent: 18,
                isExpandable: false,
                isExpanded: false,
                onTap: {},
            )
        }
    }
}

// MARK: - Row

private struct MemoryRowView: View {
    let name: String
    let detail: String?
    let footprint: Int64
    let icon: String
    let iconWidth: CGFloat
    let indent: CGFloat
    let isExpandable: Bool
    let isExpanded: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: iconWidth)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(indent > 0 ? .callout : .body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    Text(footprint.memorySizeString)
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    if isExpandable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12)
                    } else {
                        Color.clear.frame(width: 12, height: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isExpandable && indent > 0)

            Color.clear.frame(width: 24, height: 24)
        }
        .padding(.leading, 16 + indent)
        .padding(.trailing, 10)
        .padding(.vertical, 7)
        .background(isHovered && isExpandable ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .onHover { isHovered = $0 }
    }
}
