import SwiftUI
import AppKit
import LoadoutCore

@main
struct LoadoutApp: App {
    @State private var model = AppModel(paths: LoadoutApp.launchPaths())

    /// `LOADOUT_HOME=<dir>` points the whole app at a fixture home — the scenario hooks'
    /// sibling, for exercising states the real inventory doesn't have (validation errors,
    /// empty sources) without touching the real ~/.claude.
    private static func launchPaths() -> Paths {
        if let home = ProcessInfo.processInfo.environment["LOADOUT_HOME"] {
            return Paths(home: URL(fileURLWithPath: home))
        }
        return .live()
    }

    init() {
        if CommandLine.arguments.contains("--self-check") {
            MainActor.assumeIsolated { SelfCheck.run() }
        }
        // The v2 design is one deliberate dark theme; pinning the whole app keeps AppKit
        // chrome (menus, popovers, sheets) agreeing with the SwiftUI colour scheme.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        Window("Loadout", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 824, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 920)
        // No system title bar at all: the v2 design draws its own 52pt bar — traffic lights
        // at the left, the kind tabs at the window's optical centre, actions at the right —
        // and a native toolbar under that would be two title bars stacked.
        .windowStyle(.hiddenTitleBar)
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
            CommandGroup(after: .textEditing) {
                // ⌘F goes to whichever search the eye is on: the editor's own find bar while
                // the Edit mode is up, and otherwise the list's search field.
                Button("Find") {
                    if !model.showsPreview, model.selected?.isEditable == true {
                        NotificationCenter.default.post(name: .loadoutEditorFind, object: nil)
                    } else {
                        // A hidden sidebar has no field to focus — reveal it first. The
                        // stored key is the same one ContentView's @AppStorage watches.
                        UserDefaults.standard.set(true, forKey: "sidebarVisible")
                        model.searchFocused = true
                    }
                }
                .keyboardShortcut("f", modifiers: .command)
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
                    // MCP servers live inside ~/.claude.json, not in a folder of their own,
                    // so there is nothing to trash; with no selection there is nothing at all.
                    .disabled(!(model.selected?.isEditable ?? false))
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

