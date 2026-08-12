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
        // checked without touching the system-wide setting or the stored Settings › Appearance
        // choice. Unset, the stored choice applies — System by default, which follows macOS.
        switch ProcessInfo.processInfo.environment["LOADOUT_APPEARANCE"]?.lowercased() {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default:
            let stored = UserDefaults.standard.string(forKey: "appearance")
                .flatMap(AppAppearance.init(rawValue:)) ?? .system
            stored.apply()
        }
    }

    var body: some Scene {
        Window("Loadout", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 824, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 920)
        // The unified toolbar prints the window title next to the leading items by default —
        // that's the literal "Loadout" this redesign replaces with the app's own icon.
        .windowToolbarStyle(UnifiedCompactWindowToolbarStyle(showsTitle: false))
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
                // The search field lives in the list column now, with no menu of its own to
                // hang ⌘F on — this asks the model, which the field itself is watching.
                Button("Find") { model.searchFocused = true }
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
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

// MARK: - Appearance

/// The three choices Settings › Appearance offers, and what each means for `NSApp.appearance`.
/// `.system` maps to `nil` rather than to a named appearance, which is what makes the app
/// follow a live switch of the Mac's own light/dark setting instead of freezing at launch.
enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    func apply() {
        NSApplication.shared.appearance = nsAppearance
    }
}
