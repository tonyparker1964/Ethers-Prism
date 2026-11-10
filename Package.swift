// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Embeds Support/Info.plist in the executable so macOS sees a stable app identity
// (bundle id, name) even when the app runs straight from Xcode or `swift run`.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "EthersPrism",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EthersPrism", targets: ["EthersPrism"]),
        .library(name: "EthersPrismCore", targets: ["EthersPrismCore"])
    ],
    targets: [
        // The engine: no UI, no vendor SDKs. Fully testable.
        .target(name: "EthersPrismCore"),
        // The SwiftUI Mac app.
        .executableTarget(
            name: "EthersPrism",
            dependencies: ["EthersPrismCore"],
            resources: [.copy("Resources/AppIcon.png")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", infoPlist])]),
        .testTarget(name: "EthersPrismCoreTests", dependencies: ["EthersPrismCore"])
    ]
)
