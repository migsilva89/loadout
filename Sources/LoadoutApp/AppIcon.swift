import SwiftUI
import AppKit
import LoadoutCore

/// The real icon of the app a button is going to hand the file to.
///
/// This is where colour belongs on that row: not a tint invented for a button, but the mark of
/// the application that will actually open — which also answers a question the label alone
/// cannot, namely *which* editor "Open in editor" means on this machine.
struct AppIconView: View {
    let path: String?
    var size: CGFloat = 14

    var body: some View {
        if let icon = AppIconCache.icon(atPath: path) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }
}

@MainActor
enum AppIconCache {
    // Icons are only ever fetched while drawing, so main-actor isolation costs nothing and
    // keeps the cache off the concurrency checker's list of shared mutable state.
    private static var cache: [String: NSImage] = [:]

    static func icon(atPath path: String?) -> NSImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        if let hit = cache[path] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        cache[path] = icon
        return icon
    }

    static let finder = "/System/Library/CoreServices/Finder.app"
    static let claude = "/Applications/Claude.app"

    /// Icons the user drops in for assistants that ship no Mac app — Trae, Kiro, Factory,
    /// opencode and friends are CLIs, so there is nothing on disk to read. Consulted before the
    /// app lookup, which also lets a chosen icon override an app's own.
    ///
    /// Set once at launch from the app's `Paths`, rather than derived from the home directory
    /// here: it is Loadout's own folder, and the one place that knows where that is is `Paths`.
    static var userIconDirectory = Paths.live().cliIcons

    /// `<id>.png`, `.jpg` or `.icns` in that directory, whichever exists.
    static func userIcon(for id: String) -> NSImage? {
        let fm = FileManager.default
        for ext in ["png", "jpg", "jpeg", "icns"] {
            let candidate = userIconDirectory.appendingPathComponent("\(id).\(ext)")
            if fm.fileExists(atPath: candidate.path), let image = NSImage(contentsOf: candidate) {
                image.size = NSSize(width: 32, height: 32)
                return image
            }
        }
        return nil
    }

    /// The icon for an assistant or CLI id: the user's own file first, then the installed app,
    /// then nothing — and the caller draws initials.
    static func icon(forID id: String, appPath: String?) -> NSImage? {
        if let key = cache["id:\(id)"] { return key }
        if let mine = userIcon(for: id) {
            cache["id:\(id)"] = mine
            return mine
        }
        if let fromApp = icon(atPath: appPath) {
            cache["id:\(id)"] = fromApp
            return fromApp
        }
        return nil
    }

    /// Where a given id's icon came from, so the UI never has to leave it a mystery.
    static func iconSource(for id: String, appPath: String?) -> String {
        if userIcon(for: id) != nil { return "Custom" }
        if let appPath, FileManager.default.fileExists(atPath: appPath) {
            return "From \(URL(fileURLWithPath: appPath).lastPathComponent)"
        }
        return "No icon"
    }

    /// Copies a chosen image in as `<id>.png`. Copies, never moves: the original stays put.
    @discardableResult
    static func installIcon(from source: URL, for id: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: userIconDirectory, withIntermediateDirectories: true)
        guard let image = NSImage(contentsOf: source),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else {
            throw LoadoutError.io("Couldn't read \(source.lastPathComponent) as an image.")
        }
        let destination = userIconDirectory.appendingPathComponent("\(id).png")
        try png.write(to: destination, options: .atomic)
        cache.removeValue(forKey: "id:\(id)")
        return destination
    }

    /// Removes only the user's file, so the next source in the chain takes over again.
    static func removeIcon(for id: String) {
        let fm = FileManager.default
        for ext in ["png", "jpg", "jpeg", "icns"] {
            let candidate = userIconDirectory.appendingPathComponent("\(id).\(ext)")
            try? fm.removeItem(at: candidate)
        }
        cache.removeValue(forKey: "id:\(id)")
    }

}
