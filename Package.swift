// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loadout",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Pinned because this framework installs executable code: it is what replaces Loadout.app
        // on somebody's disk. Moving off this version is a deliberate review, not something a
        // release build picks up on its own.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(name: "LoadoutCore"),
        .executableTarget(
            name: "LoadoutApp",
            dependencies: [
                "LoadoutCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            // The executable sits in Contents/MacOS and the framework is embedded in the standard
            // sibling Frameworks directory by Scripts/build-app.sh. Without this rpath the app
            // builds and then refuses to launch out of the bundle, because dyld has nowhere to
            // look for Sparkle.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks",
            ])]
        ),
        .testTarget(name: "LoadoutCoreTests", dependencies: ["LoadoutCore"]),
    ]
)
