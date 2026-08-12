// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loadout",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LoadoutCore"),
        .executableTarget(name: "LoadoutApp", dependencies: ["LoadoutCore"]),
        .testTarget(name: "LoadoutCoreTests", dependencies: ["LoadoutCore"]),
    ]
)
