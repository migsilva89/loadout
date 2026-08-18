import SwiftUI
import AppKit
import LoadoutCore

@main
struct LoadoutApp: App {
    /// Built in `init`, not as a property's initial value: a stored initializer runs *before*
    /// the body of `init`, so `--self-check` used to construct a model against the real home —
    /// and now that a launch also migrates Loadout's own files, that meant a self-check moving
    /// the owner's data. The check runs first and exits; this is only reached by a real launch.
    @State private var model: AppModel

    /// The reading size, shared with the pane and the Aa popover through the same stored key — the
    /// menu is another way to set the one preference, not a second copy of it.
    @AppStorage("readerFontSize") private var readerFontSize = LoadoutApp.defaultReadingSize
    /// The fold's one preference, read here so the menu item can name the direction it will move.
    @AppStorage(DetailsDisclosure.key) private var detailsCollapsed = false

    /// The same bounds the Aa popover's slider works in.
    static let readingSizes: ClosedRange<Double> = 13...20
    static let defaultReadingSize: Double = 15

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
        // `LOADOUT_SHOT=welcome LOADOUT_SHOT_TO=/tmp/x.png` writes a picture of one sheet and
        // exits — the only way a script can check a screen the window recorder cannot photograph.
        if let sheet = ProcessInfo.processInfo.environment["LOADOUT_SHOT"] {
            let path = ProcessInfo.processInfo.environment["LOADOUT_SHOT_TO"] ?? "/tmp/loadout-shot.png"
            MainActor.assumeIsolated { SheetShot.run(sheet, to: path) }
        }
        // All five themes are dark ones; pinning the whole app keeps AppKit chrome (menus,
        // popovers, sheets) agreeing with the SwiftUI colour scheme whichever is on.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        Self.acceptEqualsAsBigger()
        _model = State(initialValue: MainActor.assumeIsolated { AppModel(paths: Self.launchPaths()) })
    }

    /// Makes ⌘= a synonym for ⌘+.
    ///
    /// A menu shortcut matches on the characters typed, and "+" is shift-equals — so the menu item
    /// answers ⌘⇧+ and stays silent for the plain ⌘= that most hands actually press. Every Mac app
    /// takes both; SwiftUI can't hide an alternate menu item, so one monitor covers the synonym
    /// without putting a duplicate line in the menu.
    private static func acceptEqualsAsBigger() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "="
            else { return event }
            let defaults = UserDefaults.standard
            let current = defaults.object(forKey: "readerFontSize") as? Double ?? defaultReadingSize
            defaults.set(min(readingSizes.upperBound, current + 1), forKey: "readerFontSize")
            return nil
        }
    }

    var body: some Scene {
        Window("Loadout", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 824, minHeight: 640)
                // After the window is up and the inventory has been read, so a version check can
                // never be the reason a launch feels slow.
                .task { UpdateNotice.checkOnLaunch() }
                // After the inventory has been read, so the welcome can state what was found
                // rather than open on zeroes.
                .task { model.showWelcomeIfNeeded() }
                // Quietly, in the background, after everything the window needs is on screen.
                .task { model.sweepInBackground() }
        }
        .defaultSize(width: 1440, height: 920)
        // No system title bar at all: the v2 design draws its own 52pt bar — traffic lights
        // at the left, the kind tabs at the window's optical centre, actions at the right —
        // and a native toolbar under that would be two title bars stacked.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Directly under "About Loadout", where every Mac app puts it and where a hand
            // looking for it goes first.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdateNotice.checkNow() }
                Divider()
                Button(model.showsSettings ? "Hide Settings" : "Settings…") {
                    model.showsSettings.toggle()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("New skill") { model.isCreating = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!model.isDirty)
            }
            // The reading size, on the shortcuts every Mac app uses for it. The Aa popover still
            // owns the typeface and the background; this is only the size, which is the one of the
            // three the hand reaches for mid-sentence.
            CommandGroup(before: .toolbar) {
                // In the View menu, with a shortcut, because the seam and the chip are both things
                // you have to see before you can use them — and the menu is also where the state is
                // legible without looking at the pane: the item names the direction it will move.
                Button(detailsCollapsed ? "Show Details" : "Hide Details") {
                    withAnimation(DetailsDisclosure.easing) { detailsCollapsed.toggle() }
                }
                .keyboardShortcut("i", modifiers: [.option, .command])
                Divider()
                Button("Bigger Text") { readerFontSize = min(Self.readingSizes.upperBound, readerFontSize + 1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(readerFontSize >= Self.readingSizes.upperBound)
                Button("Smaller Text") { readerFontSize = max(Self.readingSizes.lowerBound, readerFontSize - 1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(readerFontSize <= Self.readingSizes.lowerBound)
                Button("Actual Size") { readerFontSize = Self.defaultReadingSize }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(readerFontSize == Self.defaultReadingSize)
                Divider()
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
            // Where macOS has taught everybody to look when an app misbehaves. The same report as
            // the one in Settings › Help, so there is one door in two places rather than two doors.
            CommandGroup(replacing: .help) {
                Button("Loadout Guide") { BugReport.openGuide() }
                Button("Report a Bug…") { BugReport.open(model) }
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
        // No `Settings` scene any more: ⌘, opens the pane instead, so there is one Settings and
        // one place it appears. The shortcut is added by hand because the scene was what gave it
        // to the app menu for free.

    }
}

