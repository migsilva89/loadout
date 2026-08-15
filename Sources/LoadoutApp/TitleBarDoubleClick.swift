import SwiftUI
import AppKit

/// Gives the design's own title bar the double-click the system one has.
///
/// With `.windowStyle(.hiddenTitleBar)` the bar is ordinary content, so AppKit never sees a
/// double-click on a title bar and the window doesn't zoom. This puts that back — and puts the
/// *setting* back with it: System Settings › Desktop & Dock offers Zoom, Minimise or nothing for
/// this gesture, and an app that always zooms is as wrong as one that never does.
enum TitleBarDoubleClick {
    /// Main-actor, because everything it touches is: `NSApp`, the window, and the two AppKit
    /// calls below. It was already only ever called from the main thread — saying so is what
    /// stops a stricter compiler from treating the call as an implicit `await` and failing.
    @MainActor
    static func perform() {
        // Normally the window the click landed in is key by the time this runs. Normally — a click
        // that also activates the app can arrive before the window is, and then `keyWindow` is nil
        // and the gesture silently does nothing. `mainWindow` is the same window either way.
        guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible })
        else { return }
        // `NSGlobalDomain`'s own key. Absent means the system default, which is Zoom.
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}
