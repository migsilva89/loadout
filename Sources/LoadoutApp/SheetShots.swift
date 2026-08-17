import SwiftUI
import AppKit

/// Draws the app's sheets to PNG files, so they can be checked without anyone sitting in front of
/// the app.
///
/// A sheet cannot be photographed the way the window recorder photographs the main window: its
/// content is drawn by a layer tree that `cacheDisplay` reads back blank. Rendering it offscreen
/// with `ImageRenderer` was worse than useless — it lost the window's background and drew AppKit
/// checkboxes as "no entry" glyphs, which is a picture of a bug that does not exist.
///
/// So the sheet's own view is put in an ordinary window, which draws and captures exactly like the
/// main one: same views, same dark appearance, same controls. What it does not prove is the
/// presentation — that the sheet appears when the switch is flipped — and that is covered by the
/// self-check, which drives the model and sees `restoring` fill and empty.
///
/// `LOADOUT_SHEET_SHOTS=<dir>` writes them there and quits.
@MainActor
enum SheetShots {
    static func write(to directory: URL, model: AppModel) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let shared = model.items.first(where: { $0.kind == .skill && $0.assistants.count > 1 })
            ?? model.items.first(where: { $0.kind == .skill }) {
            model.restoring = RestoringSkill(
                item: shared, chosen: Set(shared.assistants), remembered: true
            )
            capture(RestoreSkillSheet(model: model), size: CGSize(width: 420, height: 300),
                    to: directory.appendingPathComponent("restore.png"))
            model.restoring = nil
        }

        if let any = model.items.first(where: { $0.kind == .skill }) {
            model.pendingProjectDisable = any
            capture(ProjectSkillWarningSheet(model: model), size: CGSize(width: 440, height: 260),
                    to: directory.appendingPathComponent("project-warning.png"))
            model.pendingProjectDisable = nil
        }

        model.selection = .commands
        capture(NewSkillSheet(model: model), size: CGSize(width: 460, height: 320),
                to: directory.appendingPathComponent("new-command.png"))
        model.selection = .skills

        // Settings is a window of its own too. Its tabs draw one at a time, so the one worth
        // checking is drawn on its own rather than whichever the TabView happens to open on.
        capture(HelpTab(model: model), size: CGSize(width: 520, height: 400),
                to: directory.appendingPathComponent("settings-help.png"))
        // The live pane, not the one it replaced. Shooting `SettingsView` left the window people
        // actually open unchecked, and the two drifted apart while the picture stayed green.
        capture(SettingsPane(model: model), size: CGSize(width: 760, height: 560),
                to: directory.appendingPathComponent("settings-pane.png"))
    }

    /// Puts the view in a real window, lets it lay out and draw, then reads the window's backing
    /// store — the same capture the recorder uses, which needs no permission of any kind.
    private static func capture(_ view: some View, size: CGSize, to file: URL) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.appearance = NSApp.effectiveAppearance
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        // One turn of the run loop: SwiftUI lays out on the next pass, and capturing before that
        // catches an empty view.
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))

        guard let content = window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
        else { return }
        rep.size = content.bounds.size
        // Force a draw before reading: a hosting view that has never been asked to display gives
        // back an empty buffer, which is what a blank frame really is.
        content.display()
        content.cacheDisplay(in: content.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: file)
        }
        window.orderOut(nil)
    }
}
