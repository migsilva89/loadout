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
                Button("Nova skill") { model.isCreating = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Guardar") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isDirty)
            }
            CommandMenu("Loadout") {
                Button("Recarregar do disco") { model.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Indexar histórico completo") { model.refreshUsage(fullHistory: true) }
                Divider()
                Button("Revelar backups no Finder") { model.revealBackups() }
                Button("Revelar no Finder") { model.revealInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Apagar seleção") { model.isConfirmingDelete = true }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }
}
