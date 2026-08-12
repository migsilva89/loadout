import SwiftUI
import AppKit

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

    /// Whichever app would open this file if it were double-clicked.
    static func editor(for url: URL?) -> String? {
        guard let url else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: url)?.path
    }
}
