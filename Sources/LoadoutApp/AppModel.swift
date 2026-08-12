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
    var selection: Selection = .skills
    /// The origin/state chip above the list. Resets to `.all` whenever the sidebar row
    /// changes, so a stale "Disabled" chip never silently hides everything in a new kind.
    var filter: ItemFilter = .all
    /// The assistant menu next to sort. Independent of `filter`, and only meaningful for
    /// skills — resets to `.any` alongside `filter` whenever the sidebar row changes.
    var assistantFilter: AssistantFilter = .any
    var selectedID: String?
    var query: String = ""
    var order: ItemSort = .usage
    /// Bridges ⌘F (a window-level command, with no view of its own) to the search field's
    /// `@FocusState`, which can only live inside the view that owns the field.
    var searchFocused: Bool = false

    // Editing
    var draft: String = ""
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

    let paths: Paths
    let scanner: InventoryScanner
    let mutations: Mutations
    let copilot = Copilot()
    private var usageIndex: UsageIndex?
    private var watcher: Watcher?
    private var indexTask: Task<Void, Never>?

    /// Every CLI on this machine right now: the built-ins that are actually installed, plus
    /// whatever the owner added by hand in Settings. Computed fresh each time rather than
    /// cached, since Settings can add or remove a custom entry at any moment.
    var assistantCLIs: [AssistantCLI] {
        AssistantCLIRegistry.discover(customEntries: customAssistantCLIs)
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

    /// Assistants Settings › Assistants has hidden from the rows and the detail panel.
    /// Stored under the same UserDefaults key the Settings tab reads with `@AppStorage`, so
    /// either side changing it is seen by the other immediately.
    private static let hiddenAssistantsKey = "hiddenAssistants"
    var hiddenAssistantIDs: Set<String> {
        didSet {
            UserDefaults.standard.set(
                hiddenAssistantIDs.sorted().joined(separator: ","), forKey: Self.hiddenAssistantsKey
            )
        }
    }

    init(paths: Paths = .live()) {
        self.paths = paths
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
        reload()
        startWatching()
        refreshUsage()
    }

    // MARK: - Reading

    func reload() {
        let inventory = scanner.scanAll(project: context)
        let annotated = usageIndex?.annotate(inventory.items) ?? inventory.items
        items = annotated
        plugins = inventory.plugins
        if let selectedID, !items.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        if selectedID == nil { selectedID = visibleItems.first?.id }
        loadDraft()
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

    /// The chip's count within the current sidebar row, so the numbers on the chips always
    /// match what picking them would show.
    func count(for chip: ItemFilter) -> Int {
        Filtering.filter(Filtering.slice(items, for: selection), by: chip).count
    }

    /// Plugins that actually ship something, so the plugin manager does not list empty rows.
    var pluginsWithItems: [PluginInfo] {
        plugins.filter { plugin in items.contains { $0.origin == .plugin(plugin.name) } }
    }

    // MARK: - Draft

    func loadDraft() {
        guard let item = selected, let path = item.path, item.kind != .mcp else {
            draft = ""
            isDirty = false
            return
        }
        draft = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
        isDirty = false
    }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        loadDraft()
    }

    // MARK: - Writing

    func save() {
        guard let item = selected else { return }
        perform("Saved \(item.name).") {
            try mutations.save(item, contents: draft)
            isDirty = false
        }
    }

    func toggle(_ item: Item) {
        if case .plugin = item.origin {
            errorMessage = LoadoutError.notEditable(item.name).errorDescription
            return
        }
        perform(item.enabled ? "Disabled \(item.name)." : "Enabled \(item.name).") {
            if item.enabled {
                try mutations.disableSkill(item)
            } else {
                try mutations.enableSkill(item)
            }
            selectedID = nil
        }
    }

    /// Every assistant found on this machine, in the order the row shows them.
    var assistants: [Assistant] { scanner.assistants }

    /// The assistants shown in list rows and the detail panel — everything, minus what
    /// Settings › Assistants hid. Sharing still works on a hidden one; it just isn't surfaced
    /// here, the same way a disabled skill still exists on disk.
    var visibleAssistants: [Assistant] { assistants.filter { !hiddenAssistantIDs.contains($0.id) } }

    func setAssistantHidden(_ assistant: Assistant, hidden: Bool) {
        if hidden { hiddenAssistantIDs.insert(assistant.id) } else { hiddenAssistantIDs.remove(assistant.id) }
    }

    /// Fills or removes a gap in the assistant dots.
    func setAssistant(_ assistant: Assistant, on item: Item, present: Bool) {
        let done = present
            ? "\(assistant.label) now loads \(item.name)."
            : "\(assistant.label) no longer loads \(item.name)."
        perform(done) {
            if present {
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

    func deleteSelected() {
        guard let item = selected else { return }
        perform("Moved \(item.name) to the Trash.") {
            try mutations.delete(item)
            selectedID = nil
        }
    }

    // MARK: - Assistant CLIs ("Ask")

    /// Opens the sheet targeting this CLI, and remembers the choice for next time.
    func askAssistant(_ cli: AssistantCLI) {
        lastAssistantCLIID = cli.id
        askCLI = cli
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

    /// Opens the whole folder in the editor rather than the single file, so a script beside the
    /// markdown is one click away instead of needing a second trip through the Finder.
    func openInEditor() {
        guard let item = selected else { return }
        let target = item.directory ?? item.path?.deletingLastPathComponent() ?? item.path
        guard let target else { return }
        NSWorkspace.shared.open(target)
    }

    /// Which folder "Open folder" will hand over, for the tooltip.
    var editorTarget: URL? {
        guard let item = selected else { return nil }
        return item.directory ?? item.path?.deletingLastPathComponent()
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
            await MainActor.run {
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
        var directories = [paths.skills, paths.skillsOff, paths.commands, paths.agents]
        if let context { directories.append(context.path.appendingPathComponent(".claude")) }
        watcher.start(watching: directories)
        self.watcher = watcher
    }

    /// A change on disk must never throw away what the user is typing.
    private func reloadFromDisk() {
        let editing = isDirty
        let keptDraft = draft
        reload()
        if editing {
            draft = keptDraft
            isDirty = true
        }
    }

    func changeContext(to project: Project?) {
        context = project
        selectedID = nil
        reload()
        startWatching()
    }
}
