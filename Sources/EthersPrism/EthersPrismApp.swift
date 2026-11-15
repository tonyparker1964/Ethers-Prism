import SwiftUI
import AppKit
import MachO
import EthersPrismCore

@main
struct EthersPrismApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Gives the app a normal Dock icon and keyboard focus when run from a Swift package.
        NSApplication.shared.setActivationPolicy(.regular)
        if let icon = AppIcon.image { NSApplication.shared.applicationIconImage = icon }
    }

    var body: some Scene {
        WindowGroup("Ethers Prism") {
            RootView()
                .environmentObject(model)
                .environmentObject(model.autoImport)
                .environmentObject(model.studio)
                .environmentObject(model.scriptLab)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Ethers Prism") {
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
                    if let icon = AppIcon.image { options[.applicationIcon] = icon }
                    options[.applicationVersion] = AppVersion.number
                    options[.version] = "build \(AppVersion.build)"
                    NSApplication.shared.orderFrontStandardAboutPanel(options: options)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.newSession() }
                    .keyboardShortcut("n")
                Button("New from Template…") { model.showTemplates = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Import Session…") { model.importSession() }
                    .keyboardShortcut("o")
                Divider()
                Button("ChatGPT Imports…") { model.studio.section = .library }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Edit Studio") { model.studio.section = .edit }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("Create") { model.studio.section = .create }
                    .keyboardShortcut("1", modifiers: [.command, .option])
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
                .environmentObject(model.autoImport)
                .environmentObject(model.studio)
                .preferredColorScheme(.dark)
                .tint(PrismTheme.teal)
        }
    }
}

/// The Ether's Prism logo, embedded in the executable at link time (see Package.swift),
/// so it is there however the app is launched.
enum AppIcon {
    static let image: NSImage? = {
        var size: UInt = 0
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(header, "__TEXT", "__app_icon", &size), size > 0 else { return nil }
        return NSImage(data: Data(bytes: bytes, count: Int(size)))
    }()
}

/// The logo at any size; shows nothing if it couldn't be read.
struct AppLogo: View {
    var size: CGFloat

    var body: some View {
        if let img = AppIcon.image {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel("Ether's Prism")
        }
    }
}
