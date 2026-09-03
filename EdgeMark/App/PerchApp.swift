import SwiftUI

@main
struct PerchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(L10n.shared)
                .environment(AppSettings.shared)
        }
    }
}
