import SwiftUI
import AppKit

/// Brings the window back to the screen the user is actually looking at.
///
/// macOS restores the last frame, which on a multi-display desk means the app can keep
/// reopening on a monitor that is off to one side — or on one that is no longer connected.
/// If the saved frame does not sit mostly on the active screen, it gets centred there instead.
struct WindowPlacement: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            place(window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// The screen with the menu bar. Not `NSScreen.main`, which follows the window we are
    /// trying to move — a window stranded on a side monitor would always call itself home.
    private var primaryScreen: NSScreen? { NSScreen.screens.first }

    private func place(_ window: NSWindow) {
        // `LOADOUT_WINDOW=1760x1100` pins the window to an exact size. For the README animation:
        // whatever size the window happens to be left at is the size the picture comes out, and a
        // cramped window makes a spacious app look cramped.
        if let wanted = ProcessInfo.processInfo.environment["LOADOUT_WINDOW"] {
            let parts = wanted.lowercased().split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let screen = primaryScreen {
                let size = NSSize(
                    width: min(parts[0], screen.visibleFrame.width),
                    height: min(parts[1], screen.visibleFrame.height)
                )
                var frame = NSRect(origin: .zero, size: size)
                frame.origin.x = screen.visibleFrame.midX - size.width / 2
                frame.origin.y = screen.visibleFrame.midY - size.height / 2
                window.setFrame(frame, display: true)
                return
            }
        }
        guard let target = primaryScreen else { return }
        let frame = window.frame
        let visible = target.visibleFrame

        // Already mostly on the main display? Leave the frame exactly as the user left it.
        let overlap = frame.intersection(visible)
        let covered = overlap.isNull ? 0 : (overlap.width * overlap.height) / (frame.width * frame.height)
        guard covered < 0.6 else { return }

        let size = CGSize(
            width: min(frame.width, visible.width),
            height: min(frame.height, visible.height)
        )
        window.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }
}
