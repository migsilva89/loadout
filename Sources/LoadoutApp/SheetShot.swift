import AppKit
import SwiftUI
import LoadoutCore

/// `LOADOUT_SHOT=<name>` writes a picture of one sheet and exits.
///
/// The window recorder cannot photograph a sheet — it says so in its own comments, and it returns
/// blank frames or stops emitting them. That left the two screens most in need of checking, the
/// welcome and the panels over the document, verifiable only by a person sitting in front of the
/// Mac and describing what they saw.
///
/// This does not photograph a sheet either. It builds the same view into a host of its own, off
/// screen, and reads that — which is enough to check a layout, a hierarchy and a piece of copy,
/// and is the only kind of check a script can make here. What it deliberately does not prove is
/// that the sheet is presented, or that its buttons are wired: those need the real window.
@MainActor
enum SheetShot {
    /// Names this understands, so a typo says so instead of writing nothing and exiting cleanly.
    static let names = ["welcome", "new-skill", "new-command"]

    static func run(_ name: String, to path: String) -> Never {
        guard names.contains(name) else {
            print("unknown sheet '\(name)'. Known: \(names.joined(separator: ", "))")
            exit(1)
        }

        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let model = AppModel(paths: Self.paths())

        let view: AnyView
        switch name {
        case "welcome": view = AnyView(WelcomeSheet(model: model, onClose: {}))
        case "new-skill":
            model.selection = .skills
            view = AnyView(NewSkillSheet(model: model))
        case "new-command":
            model.selection = .commands
            view = AnyView(NewSkillSheet(model: model))
        default: view = AnyView(EmptyView())
        }

        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        // Sized to what the view asks for rather than to a guess, so the picture shows the same
        // shape a person would get and a layout that overflows is visible as overflow.
        let fitting = host.fittingSize
        host.frame = CGRect(origin: .zero, size: CGSize(
            width: max(fitting.width, 320), height: max(fitting.height, 240)
        ))
        host.layoutSubtreeIfNeeded()

        // A window it can actually be drawn into: an unhosted view has no backing store, and
        // `cacheDisplay` on one produces an empty bitmap.
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        window.displayIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            print("couldn't make a bitmap for \(name)")
            exit(1)
        }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("couldn't encode the picture")
            exit(1)
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("\(name): \(Int(host.bounds.width))x\(Int(host.bounds.height)) → \(path)")
        exit(0)
    }

    /// The real home unless one was given, because the point of the picture is what the numbers and
    /// the folder suggestions actually look like on a machine with things on it.
    private static func paths() -> Paths {
        if let home = ProcessInfo.processInfo.environment["LOADOUT_HOME"] {
            return Paths(home: URL(fileURLWithPath: home))
        }
        return .live()
    }
}
