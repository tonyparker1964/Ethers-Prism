import SwiftUI
import AppKit

@main
struct EthersPrismApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Lets the app take a normal Dock icon and keyboard focus when run from a Swift package.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Ethers Prism") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 680)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.newSession() }
                    .keyboardShortcut("n")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
