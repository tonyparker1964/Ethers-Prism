// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EthersPrism",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EthersPrism", targets: ["EthersPrism"]),
        .library(name: "EthersPrismCore", targets: ["EthersPrismCore"])
    ],
    targets: [
        // The engine: goals, dials, history, adapters, providers. No UI, fully testable.
        .target(name: "EthersPrismCore"),
        // The SwiftUI Mac app.
        .executableTarget(name: "EthersPrism", dependencies: ["EthersPrismCore"]),
        .testTarget(name: "EthersPrismCoreTests", dependencies: ["EthersPrismCore"])
    ]
)
