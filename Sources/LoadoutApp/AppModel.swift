import Foundation
import AppKit
import Observation
import LoadoutCore

/// Everything the window reads from and writes to. One object, one source of truth.
@MainActor
@Observable
final class AppModel {
    // Inventory
    private(set) var items: [Item] = []
    private(set) var plugins: [PluginInfo] = []
    private(set) var projects: [Project] = []

    // Selection and filters
    var context: Project?
    /// The third position of the scope button: your own, every project's, and the plugins', in one
    /// list. A place to search — and it says so on screen, because no assistant ever loads more
    /// than one project at a time.
    var showsEverything = false
    /// Switching kind resets the filters — an assistant or over-budget filter set on Skills
    /// would silently empty Commands, with the control that caused it not even rendered
    /// there — and moves the selection to the new list, so the detail pane never shows a
    /// skill while the Commands tab is lit.
    var selection: Selection = .skills {
        didSet {
            guard oldValue != selection else { return }
            filter = .all
            assistantFilter = .any
            selectedID = visibleItems.first?.id
            selectFirstPluginIfNeeded()
            loadDraft()
        }
    }
    /// The origin/state filter behind the funnel.
    var filter: ItemFilter = .all {
        didSet { followSelectionIntoView() }
    }
    /// The assistant menu next to sort. Independent of `filter`, and only meaningful for
    /// skills — resets to `.any` alongside `filter` whenever the sidebar row changes.
    var assistantFilter: AssistantFilter = .any {
        didSet { followSelectionIntoView() }
    }
    var selectedID: String?
    var query: String = "" {
        didSet { followSelectionIntoView() }
    }
    var order: ItemSort = .usage
    /// Bridges ⌘F (a window-level command, with no view of its own) to the search field's
    /// `@FocusState`, which can only live inside the view that owns the field.
    var searchFocused: Bool = false

    // Editing
    var draft: String = ""
    /// The file exactly as it sits on disk, refreshed on load and on save — what the editor's
    /// gutter diffs the draft against to mark modified lines.
    private(set) var diskDraft: String = ""
    var isDirty = false
    /// Reading mode: the same pane renders the markdown instead of showing the source.
    var showsPreview = true

    // Status
    var errorMessage: String?
    var statusMessage: String?
    var indexProgress: Double?

    // Sheets
    var isCreating = false
    var isConfirmingDelete = false
    /// The CLI the "Ask" sheet is targeting. Presenting the sheet and picking a CLI are the
    /// same action — setting this to non-nil is what shows it.
    var askCLI: AssistantCLI?
    var isAddingAssistantCLI = false
    var editingCustomAssistantCLI: CustomAssistantCLI?
    /// The skill being switched back on, and the assistants ticked for it. Non-nil is what shows
    /// the sheet, the same way `askCLI` works.
    var restoring: RestoringSkill?
    /// A project skill waiting on the one-time "this will show up in your repository" warning.
    var pendingProjectDisable: Item?
    /// The plugin whose detail the Plugins tab is showing.
    var selectedPluginID: String?

    let paths: Paths
    /// Re-made on every reload rather than kept for the life of the app: it discovers the
    /// assistants on the machine at the moment it is built, and installing one — or giving an
    /// existing one its first `skills` folder — used to need a relaunch to be seen.
    private(set) var scanner: InventoryScanner
    let mutations: Mutations
    let copilot = Copilot()
    /// The conversation beside the editor. It proposes; this object still owns the text and the
    /// writing, so accepting a block lands in `draft` and Save stays Miguel's gesture.
    let ask: AskModel
    /// Both present only while the recording hooks are set, which is never in normal use.
    private var recorder: WindowRecorder?
    /// Where a walkthrough writes down what its step was about. Nothing else may reach the
    /// recorder: the frames are its own business.
    func markForRecording(_ key: String, _ rect: CGRect) { recorder?.mark(key, rect) }
    private var sceneRunner: WalkthroughRunner?
    private var usageIndex: UsageIndex?
    private var watcher: Watcher?
    private var indexTask: Task<Void, Never>?

    /// Every CLI on this machine right now: the built-ins that are actually installed, plus
    /// whatever the owner added by hand in Settings. Computed fresh each time rather than
    /// cached, since Settings can add or remove a custom entry at any moment.
    var assistantCLIs: [AssistantCLI] {
        AssistantCLIRegistry.discover(customEntries: customAssistantCLIs)
    }

    /// The assistants the Ask panel offers: the ones Loadout knows how to hold a conversation
    /// with: `claude`, `codex` and `opencode`. `cursor-agent` is left out because it wants an
    /// interactive login, which a panel cannot give it. It still appears everywhere else in the app,
    /// and still counts towards usage.
    var askableCLIs: [AssistantCLI] {
        assistantCLIs.filter { AskModel.canChat($0) }
    }

    /// The custom entries the owner added in Settings › Assistants › Ask CLIs, persisted as
    /// JSON under one `UserDefaults` key.
    private(set) var customAssistantCLIs: [CustomAssistantCLI] {
        didSet { CustomAssistantCLIStore.save(customAssistantCLIs) }
    }

    /// Remembers which CLI was asked last, so both the plain-button path (one CLI installed)
    /// and the menu (several) default to the same one next time.
    private static let lastAssistantCLIKey = "lastAssistantCLI"
    var lastAssistantCLIID: String? {
        didSet { UserDefaults.standard.set(lastAssistantCLIID, forKey: Self.lastAssistantCLIKey) }
    }

    /// Warned once, not every time: the repository note only tells you something the first time.
    ///
    /// Stored beside Loadout's other records rather than in `UserDefaults`, so it belongs to the
    /// home the app was pointed at — every other thing it knows already does.
    var hasSeenProjectSkillWarning: Bool {
        get { mutations.records.hasSeenProjectWarning }
        set { if newValue { try? mutations.records.rememberProjectWarning() } }
    }

    /// Assistants Settings › Assistants has hidden from the rows and the detail panel.
    /// Stored under the same UserDefaults key the Settings tab reads with `@AppStorage`, so
    /// either side changing it is seen by the other immediately.
    private static let hiddenAssistantsKey = "hiddenAssistants"
    var hiddenAssistantIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(
                hiddenAssistantIDs.sorted().joined(separator: ","), forKey: Self.hiddenAssistantsKey
            )
            guard hiddenAssistantIDs != oldValue else { return }
            // The same checkbox decides what shows and what counts, so the numbers have to move
            // with it. No reindex: the filter lives in the query, so this is a re-read of an index
            // that still holds every assistant's history.
            reload()
        }
    }

    init(paths: Paths = .live()) {
        // Before anything opens a file: Loadout's own backups, index and icons used to sit
        // inside ~/.claude, and this is the launch that moves them into the app's own folder.
        // Ahead of `UsageIndex` above all — opening the index first would create an empty one
        // at the new path, and the move would then decline to overwrite it.
        let migration = paths.migrateOutOfClaudeDirectory()
        self.paths = paths
        // Where the owner's own assistant icons are read from, told once rather than looked up
        // from the home directory again — a fixture home gets its own, like everything else.
        AppIconCache.userIconDirectory = paths.cliIcons
        self.scanner = InventoryScanner(paths: paths)
        self.mutations = Mutations(paths: paths)
        self.usageIndex = try? UsageIndex(paths: paths)
        self.projects = ProjectsIndex(paths: paths).load()
        self.hiddenAssistantIDs = Set(
            (UserDefaults.standard.string(forKey: Self.hiddenAssistantsKey) ?? "")
                .split(separator: ",").map(String.init)
        )
        self.customAssistantCLIs = CustomAssistantCLIStore.load()
        self.lastAssistantCLIID = UserDefaults.standard.string(forKey: Self.lastAssistantCLIKey)
        self.ask = AskModel(paths: paths)
        // The assistant's working copies belong to the conversations. Sweeping the ones whose
        // conversation is gone happens here because nothing else knows those folders exist.
        ask.removeOrphanWorkspaces()
        reload()
        // Accepting a block in the conversation edits the document being edited, and nothing else:
        // one owner for the text, one Save.
        ask.applyToDraft = { [weak self] text in
            guard let self else { return }
            draft = text
            isDirty = draft != diskDraft
        }
        ask.report = { [weak self] message in self?.statusMessage = message }
        // A proposed change is shown in the document itself, which the reading mode cannot do. So
        // the pane switches to editing when there is something to decide — otherwise the change
        // would be waiting on a screen nobody is looking at.
        ask.onProposals = { [weak self] hasPending in
            guard let self, hasPending else { return }
            showsPreview = false
        }
        startWatching()
        refreshUsage()
        // Said out loud in the footer, once, on the launch that did it: files moving on their
        // own behind someone's back is exactly the surprise this was meant to end.
        if let summary = migration.summary { statusMessage = summary }
        // A launch-time hook for exercising real scenarios from the outside — screenshots of
        // the project scope, a given tab or an assistant filter — without synthetic clicks
        // on a live window. Harmless in normal use: the variables are simply absent.
        applyScenarioEnvironment()
    }

    /// Prints the conversation and the blocks it produced once the assistant stops, then quits.
    /// Only ever reached from `LOADOUT_ASK_MESSAGE`, which exists for exercising the real loop.
    private func watchAskForReporting() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard !ask.isRunning else { return watchAskForReporting() }
            print("--- conversation ---")
            for entry in ask.entries { print(describeForReporting(entry)) }
            print("--- changed files ---")
            for proposal in ask.proposals {
                print("\(proposal.id): \(proposal.blocks.count) block(s), \(proposal.pending.count) pending")
                for block in proposal.blocks {
                    print("  line \(block.start + 1): \(block.summary)")
                    for line in block.removedText { print("    - \(line)") }
                    for line in block.addedText { print("    + \(line)") }
                }
            }
            // While recording, hold on the undecided change before taking it. That moment — the old
            // line struck through above the new one, with Accept and Reject beside it — is the whole
            // point of the feature, and at full speed it is on screen for less than a frame.
            let pause = recorder == nil ? 0.0 : 4.0
            DispatchQueue.main.asyncAfter(deadline: .now() + pause) { [self] in
                for proposal in ask.proposals { ask.acceptAll(in: proposal.id) }
                finishReporting()
            }
        }
    }

    private func finishReporting() {
        print("--- after accepting ---")
        print("dirty: \(isDirty)")
        print("draft description: \(Frontmatter.parse(draft).description ?? "—")")
        print("file on disk still: \(Frontmatter.parse(diskDraft).description ?? "—")")
        guard let recorder else { exit(0) }
        // A beat on the accepted change, so the animation does not cut the moment it lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            print("frames: \(recorder.finish())")
            exit(0)
        }
    }

    private func describeForReporting(_ entry: AskModel.Entry) -> String {
        let text = entry.text.replacingOccurrences(of: "\n", with: " ").prefix(140)
        switch entry.kind {
        case .you: return "you> \(text)"
        case .assistant: return "assistant> \(text)"
        case .reasoning: return "(thinking) \(text)"
        case .activity(let tool): return "[\(tool)] \(text)"
        case .notice: return "note: \(text)"
        case .failure: return "FAILED: \(text)"
        }
    }

    /// `LOADOUT_SCOPE=<project name>`, `LOADOUT_TAB=<skills|commands|agents|mcp|plugins>`,
    /// `LOADOUT_ASSISTANT=<assistant id>` — each applied only when present and valid.
    private func applyScenarioEnvironment() {
        let env = ProcessInfo.processInfo.environment
        // First, before any of the hooks below, because several of them return early once they
        // have set their scene going — and a recorder started after that records nothing.
        //
        // `LOADOUT_RECORD=<dir>` writes the window to PNG frames while whatever else was asked for
        // happens. The app draws its own window, so this needs no screen-recording permission,
        // which is what makes it usable from a script with nobody at the keyboard.
        if let directory = env["LOADOUT_RECORD"] {
            recorder = WindowRecorder(directory: URL(fileURLWithPath: directory))
            // Only now do the controls start reporting where they are. See Spotlight.swift: it is
            // a recording aid, and the app in someone's hands should not pay for it.
            Spotlight.isOn = true
        }
        // `LOADOUT_SHEET_SHOTS=<dir>` draws the sheets to that directory and quits — the one way to
        // check what a sheet looks like without a person in front of the app.
        if let directory = env["LOADOUT_SHEET_SHOTS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                SheetShots.write(to: URL(fileURLWithPath: directory), model: self)
                exit(0)
            }
            return
        }
        // `LOADOUT_DRIVE=<steps>` plays a script through the same calls the buttons make, writes
        // what happened to `LOADOUT_DUMP`, and quits. It is how the interface gets tested from
        // outside on a machine where synthetic clicks are not permitted.
        if let script = env["LOADOUT_DRIVE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                DriveScript.run(script, model: self, dump: env["LOADOUT_DUMP"].map(URL.init(fileURLWithPath:)))
                exit(0)
            }
            return
        }
        if env["LOADOUT_SCOPE"] == "everything" { showEverything() }
        if let name = env["LOADOUT_SCOPE"],
           let project = projects.first(where: { $0.name == name }) {
            changeContext(to: project)
        }
        if let tab = env["LOADOUT_TAB"], let selection = Selection(rawValue: tab) {
            self.selection = selection
        }
        if let id = env["LOADOUT_ASSISTANT"] {
            assistantFilter = .one(id)
        }
        if let raw = env["LOADOUT_FILTER"], let chip = ItemFilter(rawValue: raw) {
            filter = chip
        }
        if env["LOADOUT_VIEW"] == "edit" {
            showsPreview = false
        }
        // `LOADOUT_ASK=claude` opens the conversation beside the document on launch, so the panel
        // can be seen and photographed without driving the toolbar by hand.
        if let id = env["LOADOUT_ASK"], let cli = assistantCLIs.first(where: { $0.id == id }) {
            // The conversation binds to whatever is selected when it opens, so for a recording —
            // where the message is sent seconds later, by itself — the choice has to be made here
            // rather than by a scene step that runs afterwards. The skill with the least
            // description on it is the one worth asking about, measured rather than named.
            if env["LOADOUT_ASK_MESSAGE"] != nil {
                let worst = items
                    .filter { $0.kind == .skill && $0.isEditable && $0.enabled }
                    .min { $0.description.count < $1.description.count }
                if let worst { select(worst.id) }
            }
            askAssistant(cli)
        }
        // `LOADOUT_ASK_MESSAGE=<text>` sends that message through the panel as soon as the window
        // is up, and prints what came back. It drives the same calls the Send button does, against
        // the real CLI — the only way to prove the whole loop without a hand on the mouse.
        // `LOADOUT_ASK_DUMP=1` prints the conversation the panel reopened with, then quits — for
        // checking that a conversation really does come back, rather than assuming it.
        if env["LOADOUT_ASK_DUMP"] != nil, showsAskPanel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                print("--- reopened with \(ask.entries.count) message(s) ---")
                for entry in ask.entries { print(describeForReporting(entry)) }
                print("--- history: \(ask.history.count) conversation(s) ---")
                for conversation in ask.history {
                    let mark = conversation.id == ask.sessionID ? "› " : "  "
                    print("\(mark)\(conversation.title)")
                }
                exit(0)
            }
        }
        // `LOADOUT_SCENE=<browse|toggle|share|ask|all>` plays a scripted walkthrough, driving the
        // app through the same calls its buttons make. With `LOADOUT_RECORD` it is how the
        // pictures are made; on its own it is a way to watch a flow without clicking it.
        if let name = env["LOADOUT_SCENE"], !Walkthrough.steps(named: name).isEmpty {
            let endsInConversation = name == "ask" || name == "all"
            sceneRunner = WalkthroughRunner(model: self, steps: Walkthrough.steps(named: name)) { [self] in
                guard endsInConversation, env["LOADOUT_ASK_MESSAGE"] != nil else {
                    // No conversation to wait for, so the recording ends here — after a beat, so
                    // the last step is on screen long enough to see.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                        print("frames: \(recorder?.finish() ?? 0)")
                        exit(0)
                    }
                    return
                }
                if let id = env["LOADOUT_ASK"],
                   let cli = assistantCLIs.first(where: { $0.id == id }) {
                    askAssistant(cli)
                }
                ask.draftMessage = env["LOADOUT_ASK_MESSAGE"] ?? ""
                sendAskMessage()
                watchAskForReporting()
            }
            sceneRunner?.start()
            return
        }
        // `LOADOUT_NEW_SKILL=<name>` walks the New skill sheet's "Create and ask" path: make the
        // skill, then have the assistant write it. `LOADOUT_NEW_INTENT` is the sentence typed into
        // the description box, and may be absent.
        if let name = env["LOADOUT_NEW_SKILL"],
           let cli = assistantCLIs.first(where: { $0.id == (env["LOADOUT_ASK"] ?? "claude") }) {
            DispatchQueue.main.async { [self] in
                createSkillAndAsk(name: name, description: env["LOADOUT_NEW_INTENT"] ?? "", cli: cli)
                watchAskForReporting()
            }
            return
        }
        // `LOADOUT_ASK_NEW=1` starts a fresh conversation before sending, for checking that the
        // previous one is kept rather than thrown away.
        if env["LOADOUT_ASK_NEW"] != nil, showsAskPanel {
            ask.startNewConversation()
        }
        if let message = env["LOADOUT_ASK_MESSAGE"], showsAskPanel {
            ask.draftMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                sendAskMessage()
                watchAskForReporting()
            }
        }
    }

    // MARK: - Reading

    func reload() {
        // A machine can gain an assistant while the app is open. Discovering them costs one
        // directory listing, and doing it here is what lets a new one appear without a relaunch.
        scanner = InventoryScanner(paths: paths)
        let inventory = showsEverything
            ? scanner.scanEverything(projects: projects)
            : scanner.scanAll(project: context)
        apply(inventory)
    }

    /// The same reload, with the disk read moved off the main thread.
    ///
    /// A rescan opens and parses every file the app lists, which is tens of milliseconds of I/O —
    /// nothing, until it happens while somebody is scrolling. The watcher fires on writes the user
    /// did not make (Claude Code rewrites `~/.claude.json` constantly), so on the busy path the
    /// reading is done elsewhere and only the result lands on the main actor.
    private func reloadOffMainThread() {
        let scanner = InventoryScanner(paths: paths)
        let everything = showsEverything
        let projects = projects
        let context = context
        Task.detached(priority: .utility) {
            let inventory = everything
                ? scanner.scanEverything(projects: projects)
                : scanner.scanAll(project: context)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.scanner = scanner
                self.apply(inventory)
            }
        }
    }

    private func apply(_ inventory: Inventory) {
        let previousSelection = selectedID
        let annotated = usageIndex?.annotate(inventory.items, assistants: countedAssistantIDs)
            ?? inventory.items
        items = annotated
        plugins = inventory.plugins
        if let selectedID, !items.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if selectedID == nil { selectedID = visibleItems.first?.id }
        reportUnreadableRecords()
        followSelectionIntoView()
        selectFirstPluginIfNeeded()
        if isDirty, selectedID == previousSelection, selectedID != nil {
            // The reload was caused by something else — a toggle, a failed save, the
            // watcher — and the person is mid-edit on this very item. Refresh only the
            // disk copy the gutter diffs against; wiping the draft here is how a failed
            // ⌘S used to destroy the edits it had just refused to save.
            if let path = selected?.path,
               let onDisk = try? String(contentsOf: path, encoding: .utf8) {
                diskDraft = onDisk
            }
        } else {
            if isDirty, previousSelection != nil {
                // The edited item itself vanished from disk. The draft must not be
                // grafted onto whatever got selected next — that used to end with A's
                // text saved into B's file.
                statusMessage = "The file being edited disappeared — unsaved changes were discarded."
            }
            loadDraft()
        }
    }

    var visibleItems: [Item] {
        Filtering.apply(
            items, selection: selection, filter: filter,
            assistant: assistantFilter, query: query, order: order
        )
    }

    var selected: Item? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    /// The sidebar-row count: everything of that kind, ignoring the chip. `.plugins` counts
    /// installed plugins rather than items, since it has none of its own.
    func count(for selection: Selection) -> Int {
        selection == .plugins ? plugins.count : Filtering.slice(items, for: selection).count
    }

    /// The chip's count within the current sidebar row AND the current assistant filter and
    /// search, so the numbers on the chips always match what picking them would show. They
    /// used to ignore the assistant menu, which left "All 56" on screen while an assistant
    /// with nothing loaded showed an empty list.
    func count(for chip: ItemFilter) -> Int {
        Filtering.apply(
            items, selection: selection, filter: chip,
            assistant: assistantFilter, query: query, order: order
        ).count
    }

    // MARK: - Draft

    func loadDraft() {
        guard let item = selected, let path = item.path, item.kind != .mcp else {
            draft = ""
            diskDraft = ""
            isDirty = false
            return
        }
        draft = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        diskDraft = draft
        isDirty = false
    }

    /// Throw away the unsaved edits and reload the file exactly as it is on disk — the
    /// document toolbar's Revert.
    func revert() {
        loadDraft()
    }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        loadDraft()
        followSelectionInAskPanel()
    }

    /// One conversation per skill, so picking another skill while the panel is open switches to
    /// that skill's conversation rather than carrying the previous one across.
    private func followSelectionInAskPanel() {
        guard showsAskPanel, let cli = ask.cli, let item = selected,
              let folder = item.directory ?? item.path?.deletingLastPathComponent()
        else { return }
        ask.open(itemID: item.id, cli: cli, origin: folder)
    }

    // MARK: - Writing

    func save() {
        guard let item = selected else { return }
        perform("Saved \(item.name).") {
            try mutations.save(item, contents: draft)
            diskDraft = draft
            isDirty = false
            try saveAcceptedSideFiles(of: item)
        }
    }

    /// A skill is a folder, so the assistant may have changed a script beside the document. The
    /// blocks Miguel accepted in those files are written by the same Save, each with its own
    /// snapshot first — never behind his back, and never a file he didn't accept anything in.
    private func saveAcceptedSideFiles(of item: Item) throws {
        let files = ask.acceptedSideFiles
        guard !files.isEmpty,
              let folder = item.directory ?? item.path?.deletingLastPathComponent()
        else { return }
        for file in files {
            try mutations.saveSupportingFile(in: folder, relativePath: file.id, contents: file.resolvedText)
        }
        ask.refreshProposals()
        statusMessage = files.count == 1
            ? "Saved \(item.name) and \(files[0].id)."
            : "Saved \(item.name) and \(files.count) files beside it."
    }

    // MARK: - Ask

    /// The conversation column beside the document. Off by default: the pane is for reading and
    /// editing, and the assistant is something you ask for, not something that is always there.
    var showsAskPanel = false

    // MARK: Reviewing the assistant's changes, in the document itself

    /// The document as the editor should show it while the assistant's changes are undecided: the
    /// file, with both sides of each change opened up in place. `nil` when there is nothing to
    /// decide, and the editor goes back to being an editor.
    ///
    /// Built from the file on disk rather than from the draft, so a change is always shown against
    /// what is really there — and the accepted ones are what make the draft differ from it.
    var reviewLayout: ReviewLayout? {
        guard showsAskPanel,
              let document = ask.proposals.first(where: { $0.id == AskModel.documentName }),
              !document.pending.isEmpty
        else { return nil }
        return ReviewLayout.make(
            original: document.original, blocks: document.blocks, decisions: document.decisions
        )
    }

    func acceptReviewChange(_ block: Int) {
        ask.accept(blockID: block, in: AskModel.documentName)
    }

    func rejectReviewChange(_ block: Int) {
        ask.reject(blockID: block, in: AskModel.documentName)
    }

    func acceptAllReviewChanges() {
        ask.acceptAll(in: AskModel.documentName)
    }

    func rejectAllReviewChanges() {
        ask.rejectAll(in: AskModel.documentName)
    }

    /// The message box's Send. The assistant is pointed at a copy of the folder, never the folder.
    func sendAskMessage() {
        guard let item = selected,
              let folder = item.directory ?? item.path?.deletingLastPathComponent()
        else { return }
        // Told fresh at each send rather than once when the panel opened: the selection, and with
        // it which assistants load this item, can have changed in between.
        ask.briefing = AskBriefing.text(
            itemName: item.name,
            kind: item.kind.briefingNoun,
            assistants: item.assistants.sorted()
        )
        ask.send(origin: folder)
    }

    /// The switch on a row. Off is one gesture and never asks; on can be a question.
    func toggle(_ item: Item) {
        if item.kind == .command || item.kind == .agent {
            toggleCommand(item)
            return
        }
        if item.kind == .mcp {
            // An MCP server is a few lines inside ~/.claude.json rather than a file, so switching
            // it off lifts the entry out and keeps it; switching it on puts back what was lifted.
            perform(item.enabled ? "Disabled \(item.name)." : "Enabled \(item.name).") {
                try mutations.setServer(item, enabled: !item.enabled)
            }
            return
        }
        guard item.kind == .skill else {
            errorMessage = LoadoutError.notEditable(item.name).errorDescription
            return
        }

        if case .plugin = item.origin {
            togglePluginSkill(item)
            return
        }

        if item.enabled {
            if case .project = item.origin, !hasSeenProjectSkillWarning {
                // Said once, before the first move: the folder lives inside a repository, so the
                // change lands next to whatever the user was working on.
                pendingProjectDisable = item
                return
            }
            disable(item)
            return
        }

        if case .personal = item.origin {
            // Coming back is a choice, not an undo: which assistants load it again is exactly
            // what the app cannot guess for someone.
            let proposal = mutations.restoreProposal(for: item, assistants: assistants)
            restoring = RestoringSkill(
                item: item,
                chosen: Set(proposal.assistants.isEmpty ? [] : proposal.assistants),
                remembered: proposal.remembered
            )
            return
        }

        perform("Enabled \(item.name).") { try mutations.enableSkill(item) }
    }

    /// Takes a copy of something that lives in a repository and makes it yours everywhere.
    ///
    /// The project keeps its own, so nobody else loses anything; from then on the two are separate
    /// files with separate lives, which is said out loud rather than left to be discovered.
    func makeGlobal(_ item: Item) {
        let noun = item.kind.briefingNoun
        perform("Copied \(item.name) to your \(noun)s. The project keeps its own.") {
            try mutations.makeGlobal(item)
        }
    }

    /// A command is a file beside its neighbours, so there is nowhere to choose on the way back:
    /// off and on are both one gesture (AC10.5, AC10.8).
    func toggleCommand(_ item: Item) {
        if item.enabled, case .project = item.origin, !hasSeenProjectSkillWarning {
            pendingProjectDisable = item
            return
        }
        let plugin = plugins.first { $0.id == item.pluginID }
        perform(item.enabled ? "Disabled \(item.name)." : "Enabled \(item.name).") {
            try mutations.setCommand(item, enabled: !item.enabled, plugin: plugin)
        }
    }

    /// Creates a command, or a subagent when that is the tab showing. In a project scope it lands
    /// in that repository, which is the scope being looked at — `~/.claude` would be a surprise.
    func createCommand(name: String, description: String, kind: ItemKind = .command) {
        let root = context.map {
            kind == .agent ? paths.projectAgents($0.path) : paths.projectCommands($0.path)
        }
        perform("Created the \(name) \(kind == .agent ? "subagent" : "command").") {
            try mutations.createCommand(name: name, description: description, in: root, kind: kind)
            selection = kind == .agent ? .agents : .commands
            selectedID = "\(kind.rawValue):\(context.map(\.name) ?? Origin.personal.label):\(name)"
        }
    }

    /// Off, everywhere, without a dialog (AC3.2).
    func disable(_ item: Item) {
        // The id survives an enable/disable, so the selection does too — nil-ing it here used to
        // jump the detail pane to whatever sorted first.
        perform("Disabled \(item.name).") {
            if item.kind == .command || item.kind == .agent {
                try mutations.setCommand(item, enabled: false, plugin: plugins.first { $0.id == item.pluginID })
            } else if item.kind == .mcp {
                try mutations.setServer(item, enabled: false)
            } else {
                try mutations.disableSkill(item, assistants: assistants)
            }
        }
    }

    /// A skill a plugin ships, switched one at a time so a 38-item plugin is not all or nothing.
    func togglePluginSkill(_ item: Item) {
        guard let plugin = plugins.first(where: { $0.id == item.pluginID })
            ?? plugins.first(where: { $0.name == item.origin.label })
        else {
            errorMessage = "Couldn't tell which plugin \(item.name) came from."
            return
        }
        perform(
            item.enabled
                ? "Disabled \(item.name) from the \(plugin.name) plugin."
                : "Enabled \(item.name) from the \(plugin.name) plugin."
        ) {
            if item.enabled {
                try mutations.disablePluginSkill(item, in: plugin)
            } else {
                try mutations.enablePluginSkill(item, in: plugin)
            }
        }
    }

    /// Puts a skill back into the assistants picked in the sheet (AC3.6, AC3.7).
    func confirmRestore() {
        guard let restoring else { return }
        let chosen = assistants.filter { restoring.chosen.contains($0.id) }
        self.restoring = nil
        guard !chosen.isEmpty else { return }
        let where_ = chosen.map(\.label).joined(separator: " and ")
        perform("Enabled \(restoring.item.name) in \(where_).") {
            try mutations.enableSkill(restoring.item, into: chosen, assistants: assistants)
        }
    }

    /// The repository warning was read; go through with the move.
    func confirmProjectDisable(rememberChoice: Bool) {
        guard let item = pendingProjectDisable else { return }
        pendingProjectDisable = nil
        if rememberChoice { hasSeenProjectSkillWarning = true }
        disable(item)
    }

    /// Every assistant found on this machine, in the order the row shows them.
    var assistants: [Assistant] { scanner.assistants }

    /// Whether the plugin an item came from is switched off as a whole — which is a different
    /// fact from the item's own switch, and has to be said separately or one of them ends up lying.
    func pluginIsOff(for item: Item) -> Bool {
        guard let id = item.pluginID else { return false }
        return plugins.first { $0.id == id }?.enabled == false
    }

    /// The plugin whose detail pane is open, and what it ships.
    var selectedPlugin: PluginInfo? { plugins.first { $0.id == selectedPluginID } }

    /// A record Loadout cannot read is not the same as a record saying nothing was switched off,
    /// and treating them alike is how an MCP server disappeared from the list — its entry lives in
    /// that file and nowhere else, so a row that never appears is a server with no way back.
    ///
    /// Nothing is repaired here and nothing is deleted: the file is named, and the person decides.
    private func reportUnreadableRecords() {
        let broken = mutations.records.unreadable()
        guard !broken.isEmpty else { return }
        let names = broken.map { $0.lastPathComponent }.joined(separator: ", ")
        errorMessage = """
        Loadout can't read its own record of what you switched off (\(names)), so anything parked         there is missing from these lists. Nothing has been changed or deleted. The file is in         \(displayPath(broken[0].deletingLastPathComponent())) — fix or remove it, then reload.
        """
    }

    /// `~/Library/...` rather than `/Users/you/Library/...`, in anything shown to a person.
    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: paths.home.path, with: "~")
    }

    /// The pane must show something the list is showing. Narrowing the list — a filter, a search,
    /// a scope — used to leave the detail on an item that had just scrolled out of existence, and
    /// so did switching one back on while the Disabled filter was up: the row vanished and the
    /// pane went on describing it.
    ///
    /// An unsaved edit is the one thing worth more than that consistency, so a dirty draft holds
    /// its selection until it is saved or abandoned.
    private func followSelectionIntoView() {
        guard !isDirty else { return }
        guard let selectedID else { return }
        guard !visibleItems.contains(where: { $0.id == selectedID }) else { return }
        self.selectedID = visibleItems.first?.id
        loadDraft()
    }

    /// Arriving at a tab with nothing selected means arriving at an empty pane, which reads as an
    /// app with nothing in it. Every other tab already lands on its first row; the Plugins tab
    /// keeps its own selection, so it needs saying here too — and a plugin that was uninstalled
    /// underneath us leaves a selection pointing at nothing.
    private func selectFirstPluginIfNeeded() {
        guard !plugins.isEmpty else {
            selectedPluginID = nil
            return
        }
        if selectedPluginID == nil || !plugins.contains(where: { $0.id == selectedPluginID }) {
            selectedPluginID = plugins.first?.id
        }
    }

    func itemsOfPlugin(_ plugin: PluginInfo) -> [Item] {
        items.filter { $0.pluginID == plugin.id || $0.origin == .plugin(plugin.name) }
            .sorted { ($0.kind.rawValue, $0.name) < ($1.kind.rawValue, $1.name) }
    }

    /// The assistants shown in list rows and the detail panel — everything, minus what
    /// Settings › Assistants hid. Sharing still works on a hidden one; it just isn't surfaced
    /// here, the same way a disabled skill still exists on disk.
    var visibleAssistants: [Assistant] { assistants.filter { !hiddenAssistantIDs.contains($0.id) } }

    func setAssistantHidden(_ assistant: Assistant, hidden: Bool) {
        if hidden { hiddenAssistantIDs.insert(assistant.id) } else { hiddenAssistantIDs.remove(assistant.id) }
    }

    /// Fills or removes a gap in the assistant dots.
    func setAssistant(_ assistant: Assistant, on item: Item, present: Bool) {
        var done = present
            ? "\(assistant.label) now loads \(item.name)."
            : "\(assistant.label) no longer loads \(item.name)."
        // A command's frontmatter is Claude Code's own vocabulary: `allowed-tools` and
        // `disable-model-invocation` are dead text anywhere else. The file travels; part of its
        // meaning does not, and that gets said rather than discovered later (AC10.12).
        if item.kind == .command, present, assistant.id != "claude" {
            done += " Claude-only frontmatter doesn't carry over."
        }
        perform(done) {
            if item.kind == .command {
                if present {
                    try mutations.shareCommand(item, with: assistant)
                } else {
                    try mutations.unshareCommand(item, from: assistant)
                }
            } else if present {
                try mutations.share(item, with: assistant)
            } else {
                try mutations.unshare(item, from: assistant)
            }
        }
    }

    /// Everything one assistant has and the other does not.
    func gaps(for assistant: Assistant) -> [Item] {
        items.filter {
            $0.kind == .skill && $0.origin == .personal && $0.enabled
                && !$0.assistants.contains(assistant.id) && !$0.assistants.isEmpty
        }
    }

    /// Gives an assistant every skill it is missing, in one go.
    func syncAll(to assistant: Assistant) {
        let missing = gaps(for: assistant)
        guard !missing.isEmpty else {
            statusMessage = "\(assistant.label) already has everything."
            return
        }
        var failures: [String] = []
        for item in missing {
            do {
                try mutations.share(item, with: assistant)
            } catch {
                failures.append(item.name)
            }
        }
        reload()
        if failures.isEmpty {
            statusMessage = "\(assistant.label) now loads \(missing.count) \(missing.count == 1 ? "skill" : "skills")."
            errorMessage = nil
        } else {
            errorMessage = "Couldn't sync: \(failures.joined(separator: ", "))."
        }
    }

    func togglePlugin(_ plugin: PluginInfo) {
        perform(plugin.enabled ? "Disabled the \(plugin.name) plugin." : "Enabled the \(plugin.name) plugin.") {
            try mutations.setPlugin(plugin, enabled: !plugin.enabled)
        }
    }

    func createSkill(name: String, description: String) {
        perform("Created the \(name) skill.") {
            try mutations.createSkill(name: name, description: description)
            selectedID = "skill:\(Origin.personal.label):\(name)"
        }
    }

    /// Creates the skill and hands it straight to an assistant, with the first message already
    /// written from what was typed into the sheet.
    ///
    /// The hard part of a new skill is not the folder — it is the `description` that decides whether
    /// the skill is ever reached for, and a body worth loading. So this ends where that work happens
    /// instead of leaving the same two sentences to be typed a second time into the panel.
    func createSkillAndAsk(name: String, description: String, cli: AssistantCLI) {
        createSkill(name: name, description: description)
        guard errorMessage == nil, selected?.name == name else { return }
        askAssistant(cli)
        guard showsAskPanel else { return }
        let intent = description.trimmingCharacters(in: .whitespacesAndNewlines)
        ask.draftMessage = intent.isEmpty
            ? """
              I've just made this skill and it's empty. Write it: a description that says when to \
              reach for it, and a body worth loading. Ask me what it should do if you need to.
              """
            : """
              I've just made this skill from one sentence: "\(intent)". Write it properly — sharpen \
              the description so it triggers at the right moments, and write a body worth loading.
              """
        sendAskMessage()
    }

    func deleteSelected() {
        guard let item = selected else { return }
        perform("Moved \(item.name) to the Trash.") {
            try mutations.delete(item)
            selectedID = nil
        }
    }

    // MARK: - Assistant CLIs ("Ask")

    /// Opens the sheet targeting this CLI, and remembers the choice for next time.
    /// The Ask button. An assistant Loadout knows how to hold a conversation with opens the panel
    /// beside the document; anything else — a custom entry from Settings, whose flags are whatever
    /// the owner typed — keeps the one-shot sheet it has always had.
    func askAssistant(_ cli: AssistantCLI) {
        lastAssistantCLIID = cli.id
        guard AskModel.canChat(cli), let item = selected,
              let folder = item.directory ?? item.path?.deletingLastPathComponent()
        else {
            askCLI = cli
            return
        }
        ask.open(itemID: item.id, cli: cli, origin: folder)
        showsAskPanel = true
    }

    /// Validates and saves a new custom entry. Throws `LoadoutError.invalidAssistantCLI`
    /// rather than saving something that would only fail silently later, when it's run.
    func addCustomAssistantCLI(name: String, path: String, template: String) throws {
        try AssistantCLIValidation.validate(name: name, path: path, template: template)
        let id = slug(name)
        var entries = customAssistantCLIs.filter { $0.id != id }
        entries.append(CustomAssistantCLI(id: id, label: name, executablePath: path, argumentTemplate: template))
        customAssistantCLIs = entries
    }

    func updateCustomAssistantCLI(_ original: CustomAssistantCLI, name: String, path: String, template: String) throws {
        try AssistantCLIValidation.validate(name: name, path: path, template: template)
        var entries = customAssistantCLIs
        guard let index = entries.firstIndex(where: { $0.id == original.id }) else { return }
        entries[index] = CustomAssistantCLI(id: original.id, label: name, executablePath: path, argumentTemplate: template)
        customAssistantCLIs = entries
    }

    func removeCustomAssistantCLI(_ entry: CustomAssistantCLI) {
        customAssistantCLIs.removeAll { $0.id == entry.id }
    }

    /// A stable, unique-enough id from a display name — lowercase, hyphenated, the same shape
    /// `known` built-in ids already use.
    private func slug(_ name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return base.isEmpty ? UUID().uuidString : base
    }

    /// The folder, with its markdown selected inside it — a skill is a folder, and the scripts
    /// and references beside the document are usually why you went looking.
    func revealInFinder() {
        guard let item = selected else { return }
        if let file = item.path {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if let folder = item.directory {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    func revealBackups() {
        try? FileManager.default.createDirectory(at: paths.backups, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([paths.backups])
    }

    /// Runs a mutation, reports it, and always leaves the view matching the disk.
    private func perform(_ success: String, _ body: () throws -> Void) {
        do {
            try body()
            statusMessage = success
            errorMessage = nil
        } catch {
            errorMessage = (error as? LoadoutError)?.errorDescription ?? error.localizedDescription
            statusMessage = nil
        }
        reload()
    }

    // MARK: - Usage index

    /// The projects one item was used in, busiest first — what the detail pane's "Used in"
    /// rail lists. Read on demand rather than joined onto every row: it is one indexed query
    /// for the one item on screen, where `annotate` would run it for the whole inventory.
    func projectUsage(for item: Item) async -> [ProjectUsage] {
        guard let usageIndex else { return [] }
        let counted = countedAssistantIDs
        return await Task.detached(priority: .userInitiated) {
            usageIndex.projects(kind: item.kind, key: item.name, assistants: counted)
        }.value
    }

    /// Which assistants the counts include: everything discovered, minus what Settings has
    /// unchecked. One checkbox governs both the rows and the numbers, so the two can never
    /// disagree — and because the filter is applied to the query rather than to the index, the
    /// history itself is never thrown away and unchecking is exactly reversible.
    var countedAssistantIDs: Set<String> {
        let known = Set(assistants.map(\.id)).union(usageIndex?.sources.map(\.assistant) ?? [])
        return known.subtracting(hiddenAssistantIDs)
    }

    /// One row per history source for Settings › Usage: what it is, whether it counts, and how much
    /// of it there is.
    var usageSources: [UsageSourceStatus] {
        usageIndex?.sourceStatuses(includedAssistants: countedAssistantIDs) ?? []
    }

    /// How often each assistant fired this item — the breakdown behind the total, read off the
    /// main thread for the same reason the projects query is.
    func usageByAssistant(for item: Item) async -> [String: Int] {
        guard let usageIndex else { return [:] }
        let counted = countedAssistantIDs
        return await Task.detached(priority: .userInitiated) {
            usageIndex.usageByAssistant(kind: item.kind, key: item.name, assistants: counted)
        }.value
    }

    /// The window the counts cover, in the words Settings uses, for saying so in the UI.
    var usageWindowLabel: String {
        switch UserDefaults.standard.string(forKey: "usageWindowDays") ?? "90" {
        case "30": return "the last 30 days"
        case "365": return "the last year"
        case "all": return "all recorded history"
        default: return "the last 90 days"
        }
    }

    /// Which assistants the counts include, named, for explaining a number in a tooltip.
    var countedAssistantLabels: [String] {
        let counted = countedAssistantIDs
        let known = assistants.filter { counted.contains($0.id) }.map(\.label)
        return known.isEmpty ? ["no assistants"] : known
    }

    /// Every recorded use of one item, for proving a count instead of asserting it.
    func occurrences(for item: Item) -> [UsageOccurrence] {
        usageIndex?.occurrences(kind: item.kind, key: item.name, assistants: countedAssistantIDs)
            ?? []
    }

    /// How many transcript files and events are currently indexed, for Settings › Usage.
    var indexedFileCount: Int { usageIndex?.indexedFileCount ?? 0 }
    var indexedEventCount: Int { usageIndex?.eventCount ?? 0 }

    func refreshUsage(fullHistory: Bool = false) {
        refreshUsage(since: fullHistory ? .distantPast : Date().addingTimeInterval(-UsageIndex.defaultWindow))
    }

    /// Settings › Usage picks the indexing window; changing it re-indexes from that point.
    /// `nil` means "Everything" (AC6.3's full-history case, reused here).
    func reindexUsage(windowDays: Int?) {
        let since = windowDays.map { Date().addingTimeInterval(-Double($0) * 86_400) } ?? .distantPast
        refreshUsage(since: since)
    }

    private func refreshUsage(since: Date) {
        guard let usageIndex else { return }
        indexTask?.cancel()
        indexProgress = 0

        indexTask = Task.detached(priority: .utility) { [weak self] in
            let report: @Sendable (Double?) -> Void = { value in
                Task { @MainActor in self?.indexProgress = value }
            }
            usageIndex.refresh(
                since: since,
                cancelled: { Task.isCancelled },
                progress: { progress in
                    report(
                        progress.total == 0 ? nil : Double(progress.scanned) / Double(progress.total)
                    )
                }
            )
            // Capture the weak reference explicitly rather than letting the closure reach back
            // into the detached task's context for it: without the capture list, older compilers
            // read this as sending `self` across isolation and refuse it.
            await MainActor.run { [weak self] in
                self?.indexProgress = nil
                self?.reload()
            }
        }
    }

    // MARK: - Watching

    private func startWatching() {
        let watcher = Watcher { [weak self] in
            Task { @MainActor [weak self] in self?.reloadFromDisk() }
        }
        // Everything the window shows, not only Claude's own folders: a skill added to Codex, a
        // plugin updated underneath the app, or a server added to ~/.claude.json used to leave the
        // list saying something that was no longer true until it was reloaded by hand.
        // `~/.claude.json` itself, not the folder it sits in — that folder is the home directory,
        // and watching a home means being woken by every download and every editor's autosave.
        var directories = [paths.skills, paths.skillsOff, paths.commands, paths.agents,
                           paths.agentsOff, paths.sharedSkills, paths.pluginCache,
                           paths.claudeJSON]
        for assistant in scanner.assistants {
            let home = assistant.skillsRoot.deletingLastPathComponent()
            directories += [assistant.skillsRoot, assistant.commandsRoot,
                            home.appendingPathComponent("skills-off")]
        }
        if let context { directories.append(context.path.appendingPathComponent(".claude")) }
        watcher.start(watching: directories)
        self.watcher = watcher
    }

    /// A change on disk must never throw away what the user is typing — and must never
    /// graft it onto a different item either. `reload()` owns both rules now: the draft
    /// survives exactly when the same item stays selected.
    private func reloadFromDisk() {
        reloadOffMainThread()
    }

    /// The one entry that is not a project: everything at once.
    func showEverything() {
        showsEverything = true
        context = nil
        selectedID = nil
        reload()
        startWatching()
    }

    func changeContext(to project: Project?) {
        showsEverything = false
        context = project
        selectedID = nil
        reload()
        startWatching()
    }
}

/// A skill on its way back on, and where the sheet is pointing it.
///
/// `remembered` is false when Loadout had no record of where the skill used to load — moved by
/// hand, or a support folder that was wiped. The sheet says so rather than presenting a guess as
/// if it were history (AC3.9).
struct RestoringSkill: Identifiable {
    var item: Item
    var chosen: Set<String>
    var remembered: Bool

    var id: String { item.id }
}
