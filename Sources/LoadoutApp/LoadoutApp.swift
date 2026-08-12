import SwiftUI
import AppKit
import LoadoutCore

@main
struct LoadoutApp: App {
    @State private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--self-check") {
            MainActor.assumeIsolated { SelfCheck.run() }
        }
        // `LOADOUT_APPEARANCE=light` (or dark) pins the theme for this launch, so both can be
        // checked without touching the system-wide setting. Unset, the app follows macOS.
        switch ProcessInfo.processInfo.environment["LOADOUT_APPEARANCE"]?.lowercased() {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    var body: some Scene {
        Window("Loadout", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New skill") { model.isCreating = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isDirty)
            }
            CommandMenu("Loadout") {
                ForEach(model.assistants) { assistant in
                    Button("Sync all with \(assistant.label) (\(model.gaps(for: assistant).count))") {
                        model.syncAll(to: assistant)
                    }
                    .disabled(model.gaps(for: assistant).isEmpty)
                }
                Divider()
                Button("Reload from disk") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Index full history") { model.refreshUsage(fullHistory: true) }
                Divider()
                Button("Show backups in Finder") { model.revealBackups() }
                Button("Show in Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Move selection to Trash") { model.isConfirmingDelete = true }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }
}
