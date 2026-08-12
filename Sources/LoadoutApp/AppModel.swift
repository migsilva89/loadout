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
    var selection: Selection = .personal
    var selectedID: String?
    var query: String = ""
    var order: ItemSort = .usage

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
    var isAskingClaude = false

    let paths: Paths
    let scanner: InventoryScanner
    let mutations: Mutations
    let copilot = Copilot()
    private var usageIndex: UsageIndex?
    private var watcher: Watcher?
    private var indexTask: Task<Void, Never>?

    init(paths: Paths = .live()) {
        self.paths = paths
        self.scanner = InventoryScanner(paths: paths)
        self.mutations = Mutations(paths: paths)
        self.usageIndex = try? UsageIndex(paths: paths)
        self.projects = ProjectsIndex(paths: paths).load()
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
        Filtering.apply(items, selection: selection, query: query, order: order)
    }

    var selected: Item? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    func count(for selection: Selection) -> Int {
        Filtering.slice(items, for: selection).count
    }

    /// Plugins that actually ship something, so the sidebar does not list empty rows.
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
        perform("Guardado \(item.name).") {
            try mutations.save(item, contents: draft)
            isDirty = false
        }
    }

    func toggle(_ item: Item) {
        if case .plugin = item.origin {
            errorMessage = LoadoutError.notEditable(item.name).errorDescription
            return
        }
        perform(item.enabled ? "\(item.name) desativada." : "\(item.name) ativada.") {
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

    /// Fills or removes a gap in the assistant dots.
    func setAssistant(_ assistant: Assistant, on item: Item, present: Bool) {
        let done = present
            ? "\(item.name) passa a valer no \(assistant.label)."
            : "\(item.name) deixa de ser carregada pelo \(assistant.label)."
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
            statusMessage = "O \(assistant.label) já tem tudo."
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
            statusMessage = "\(missing.count) skills passaram a valer no \(assistant.label)."
            errorMessage = nil
        } else {
            errorMessage = "Ficaram de fora: \(failures.joined(separator: ", "))."
        }
    }

    func togglePlugin(_ plugin: PluginInfo) {
        perform(plugin.enabled ? "Plugin \(plugin.name) desativado." : "Plugin \(plugin.name) ativado.") {
            try mutations.setPlugin(plugin, enabled: !plugin.enabled)
        }
    }

    func createSkill(name: String, description: String) {
        perform("Skill \(name) criada.") {
            try mutations.createSkill(name: name, description: description)
            selectedID = "skill:pessoal:\(name)"
        }
    }

    func deleteSelected() {
        guard let item = selected else { return }
        perform("\(item.name) foi para o Lixo.") {
            try mutations.delete(item)
            selectedID = nil
        }
    }

    func revealInFinder() {
        guard let path = selected?.directory ?? selected?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([path])
    }

    func openInEditor() {
        guard let path = selected?.path else { return }
        NSWorkspace.shared.open(path)
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

    func refreshUsage(fullHistory: Bool = false) {
        guard let usageIndex else { return }
        indexTask?.cancel()
        indexProgress = 0
        let since = fullHistory ? Date.distantPast : Date().addingTimeInterval(-UsageIndex.defaultWindow)

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
