import SwiftUI

struct AboutSettingsTab: View {
    @Environment(L10n.self) var l10n

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // App icon + name + version
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)

                Text("Perch")
                    .font(.title.bold())

                Text(l10n.t("settings.about.version", appVersion, buildNumber))
                    .foregroundStyle(.secondary)
            }

            Text(l10n["settings.about.basedOn"])
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
                .padding(.horizontal, 40)

            // Links
            VStack(spacing: 10) {
                // Points at the original open-source project this fork is built on —
                // not this customized build, which has no issue tracker of its own.
                Link(destination: URL(string: "https://github.com/Ender-Wang/EdgeMark")!) {
                    Label(l10n["settings.about.viewOriginalProject"], systemImage: "arrow.up.right.square")
                }
            }

            Spacer()

            // Copyright
            Text(l10n.t("settings.about.copyright", currentYear))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - App Info

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    private var currentYear: String {
        String(Calendar.current.component(.year, from: Date()))
    }
}
