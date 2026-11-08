import SwiftUI
import AppKit

@main
struct EthersPrismApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Gives the app a normal Dock icon and keyboard focus when run from a Swift package.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Ethers Prism") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.newSession() }
                    .keyboardShortcut("n")
                Button("New from Template…") { model.showTemplates = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Import Session…") { model.importSession() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Explore") {
                Button("Preview") { model.generate(.preview, force: true) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Render Full Quality") { model.generate(.render, force: true) }
                    .keyboardShortcut("r")
                Button("Explore Nearby") { model.exploreNearby() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Compare States…") { model.showCompare = true }
                Button("Export…") { model.export() }
                    .keyboardShortcut("e")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
