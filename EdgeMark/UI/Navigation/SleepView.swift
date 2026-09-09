import Cocoa
import SwiftUI

/// Sleep controls. Two halves, kept visibly apart because they cost different
/// things: the session toggles are instant and vanish when Perch quits, while
/// the system ones rewrite Energy Saver for every user and ask for a password.
struct SleepView: View {
    @Environment(NoteStore.self) var noteStore
    @Environment(L10n.self) var l10n

    private var model = PowerModel.shared

    var body: some View {
        PageLayout(onSwipeBack: { noteStore.closeSleep() }) {
            HStack {
                HeaderIconButton(systemName: "chevron.left", help: l10n["common.back"]) {
                    noteStore.closeSleep()
                }
                Spacer()
                PinButton()
                HeaderIconButton(systemName: "arrow.clockwise", help: l10n["sleep.reread"]) {
                    model.refreshSettings()
                }
                .disabled(model.isReadingSettings)
                .opacity(model.isReadingSettings ? 0.3 : 1)
            }
            .overlay {
                Text(l10n["sleep.title"])
                    .font(.headline)
            }
        } content: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        section(
                            title: l10n["sleep.session"],
                            note: l10n["sleep.session.note"],
                        ) {
                            toggleRow(
                                title: l10n["sleep.keepDisplayAwake"],
                                detail: l10n["sleep.keepDisplayAwake.detail"],
                                icon: "sun.max",
                                isOn: model.keepDisplayAwake,
                                set: { model.setKeepDisplayAwake($0) },
                            )
                            toggleRow(
                                title: l10n["sleep.keepSystemAwake"],
                                detail: l10n["sleep.keepSystemAwake.detail"],
                                icon: "bolt",
                                isOn: model.keepSystemAwake,
                                set: { model.setKeepSystemAwake($0) },
                            )
                        }

                        section(
                            title: l10n["sleep.system"],
                            note: l10n["sleep.system.note"],
                        ) {
                            toggleRow(
                                title: l10n["sleep.neverSleep"],
                                detail: idleSummary,
                                icon: "moon.zzz",
                                isOn: model.settings.neverSleeps,
                                busy: model.isApplying,
                                set: { on in Task { await model.setNeverSleep(on) } },
                            )
                            toggleRow(
                                title: l10n["sleep.lidClose"],
                                detail: l10n["sleep.lidClose.detail"],
                                icon: "laptopcomputer",
                                // `sleepDisabled` is the inverse: it's what
                                // stops the Mac sleeping with the lid shut.
                                isOn: !model.settings.sleepDisabled,
                                busy: model.isApplying,
                                set: { on in Task { await model.setSleepOnLidClose(on) } },
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                Divider().padding(.horizontal, 12)

                ContentFooterBar()
            }
        }
        .onAppear { model.refreshSettings() }
        .alert(l10n["alert.sleep.failed.title"], isPresented: Binding(
            get: { model.lastError != nil },
            set: { if !$0 { model.clearError() } },
        )) {
            Button(l10n["common.ok"], role: .cancel) { model.clearError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    /// What the system reports right now, so the toggle is never the only
    /// source of truth about a setting we don't own — plus the line that says
    /// what this switch does *not* cover, which is the lid.
    private var idleSummary: String {
        let ac = minutes(model.settings.acSleepMinutes)
        let battery = minutes(model.settings.batterySleepMinutes)
        return l10n.t("sleep.idleTimers", ac, battery) + "\n" + l10n["sleep.neverSleep.note"]
    }

    private func minutes(_ value: Int?) -> String {
        guard let value else { return l10n["sleep.unknown"] }
        return value == 0 ? l10n["sleep.never"] : l10n.t("sleep.minutes", "\(value)")
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func section(title: String, note: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            VStack(spacing: 4) { rows() }
            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toggleRow(
        title: String,
        detail: String,
        icon: String,
        isOn: Bool,
        busy: Bool = false,
        set: @escaping (Bool) -> Void,
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(isOn ? Color.accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if busy {
                ProgressView().controlSize(.small)
            }

            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(busy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassInset(cornerRadius: 8)
    }
}
