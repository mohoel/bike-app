import SwiftUI

@main
struct BikeAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Bike App", id: "main") {
            MainWindowView()
                .environment(appDelegate.model)
        }
        .defaultSize(width: 820, height: 760)

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(appDelegate.model)
        } label: {
            MenuBarLabel()
                .environment(appDelegate.model)
        }
    }
}
