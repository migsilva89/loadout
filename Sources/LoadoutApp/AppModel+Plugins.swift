import Foundation
import LoadoutCore

/// Installing and updating plugins. Removing one is in `AppModel` beside the dialog that confirms it.
extension AppModel {
    /// The assistants whose plugins can be managed here and that are installed on this machine.
    var pluginAssistants: [Assistant] {
        assistants.filter { PluginService.managedAssistants.contains($0.id) }
    }

    private var pluginService: PluginService { PluginService(paths: paths, locate: locate) }

    /// Whether a plugin has an update to ask for. opencode's local files and the plugins a Codex
    /// workspace manages have none.
    func canUpdate(_ plugin: PluginInfo) -> Bool {
        guard pluginService.canManage(plugin.assistant) else { return false }
        if plugin.assistant == "opencode" { return !plugin.nativeKey.hasPrefix("local:") }
        return plugin.assistant == "claude" || plugin.toggleUnavailableReason == nil
    }

    func canRemove(_ plugin: PluginInfo) -> Bool {
        plugin.assistant == "claude" || pluginService.canManage(plugin.assistant)
    }

    // MARK: - Update

    func updatePlugin(_ plugin: PluginInfo) {
        guard busyPlugins.insert(plugin.id).inserted else { return }
        statusMessage = "Updating \(plugin.name)…"
        errorMessage = nil
        let service = pluginService
        Task.detached {
            let result = Result { try service.update(plugin) }
            await MainActor.run { [self] in
                busyPlugins.remove(plugin.id)
                switch result {
                case .success(let outcome):
                    statusMessage = "\(plugin.name): \(outcome.summary.isEmpty ? "up to date." : outcome.summary)"
                    errorMessage = nil
                case .failure(let error):
                    errorMessage = (error as? LoadoutError)?.errorDescription ?? error.localizedDescription
                    statusMessage = nil
                }
                reload()
            }
        }
    }

    /// Asks every updatable plugin to update, one after another, and says how many did.
    func updateAllPlugins() {
        let targets = plugins.filter(canUpdate)
        guard !targets.isEmpty, busyPlugins.isDisjoint(with: targets.map(\.id)) else { return }
        busyPlugins.formUnion(targets.map(\.id))
        statusMessage = "Updating \(targets.count) \(targets.count == 1 ? "plugin" : "plugins")…"
        errorMessage = nil
        let service = pluginService
        Task.detached {
            var failures: [String] = []
            for plugin in targets {
                do { _ = try service.update(plugin) }
                catch { failures.append("\(plugin.name): \((error as? LoadoutError)?.errorDescription ?? error.localizedDescription)") }
            }
            await MainActor.run { [self] in
                busyPlugins.subtract(targets.map(\.id))
                if failures.isEmpty {
                    statusMessage = "Updated \(targets.count) \(targets.count == 1 ? "plugin" : "plugins"). A running session picks them up when it restarts."
                    errorMessage = nil
                } else {
                    errorMessage = "\(targets.count - failures.count) of \(targets.count) updated.\n" + failures.joined(separator: "\n")
                    statusMessage = nil
                }
                reload()
            }
        }
    }

    // MARK: - Install

    func openPluginInstaller() {
        pluginReceipt = nil
        pluginInstallError = nil
        pluginCatalogError = nil
        if !pluginAssistants.contains(where: { $0.id == pluginInstallAssistant }) {
            pluginInstallAssistant = pluginAssistants.first?.id ?? "claude"
        }
        isInstallingPlugin = true
        loadPluginCatalog()
    }

    func selectPluginInstallAssistant(_ id: String) {
        pluginInstallAssistant = id
        pluginReceipt = nil
        pluginInstallError = nil
        loadPluginCatalog()
    }

    /// Reads what the chosen assistant's marketplaces offer. Slow for Claude Code, which reads
    /// every marketplace it has, so it never blocks the window.
    func loadPluginCatalog() {
        let assistant = pluginInstallAssistant
        pluginCatalog = []
        pluginCatalogError = nil
        guard assistant != "opencode" else { return }
        isLoadingPluginCatalog = true
        let service = pluginService
        Task.detached {
            let result = Result { try service.catalog(for: assistant) }
            await MainActor.run { [self] in
                guard pluginInstallAssistant == assistant else { return }
                isLoadingPluginCatalog = false
                switch result {
                case .success(let entries): pluginCatalog = entries
                case .failure(let error):
                    pluginCatalogError = (error as? LoadoutError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    func install(_ entry: PluginCatalogEntry) {
        runInstall(key: entry.id, name: entry.name) { try $0.install(entry) }
    }

    /// A plugin named by hand: `name@marketplace` for Claude Code, a package or git URL for opencode.
    func install(spec: String, assistant: String) {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        runInstall(key: "\(assistant):\(trimmed)", name: trimmed) { try $0.install(spec: trimmed, assistant: assistant) }
    }

    func addPluginMarketplace(_ source: String) {
        runInstall(key: "marketplace:\(source)", name: source) { try $0.addMarketplace(source: source) }
    }

    private func runInstall(
        key: String, name: String, _ work: @escaping @Sendable (PluginService) throws -> PluginOutcome
    ) {
        guard busyPlugins.insert(key).inserted else { return }
        pluginReceipt = nil
        pluginInstallError = nil
        let service = pluginService
        Task.detached {
            let result = Result { try work(service) }
            await MainActor.run { [self] in
                busyPlugins.remove(key)
                switch result {
                case .success(let outcome):
                    pluginReceipt = outcome.summary.isEmpty ? "Done." : outcome.summary
                    statusMessage = outcome.summary.isEmpty ? "Installed \(name)." : outcome.summary
                    if key.hasPrefix("marketplace:") { loadPluginCatalog() }
                case .failure(let error):
                    pluginInstallError = (error as? LoadoutError)?.errorDescription ?? error.localizedDescription
                }
                reload()
                if key.hasPrefix("marketplace:") == false, !pluginCatalog.isEmpty { markInstalledInCatalog() }
            }
        }
    }

    /// After an install the entry should read as installed without waiting for the catalogue to be
    /// fetched again: whichever plugins now appear in the inventory are marked.
    private func markInstalledInCatalog() {
        let known = Set(plugins.map(\.nativeKey))
        for index in pluginCatalog.indices where known.contains(pluginCatalog[index].spec) {
            pluginCatalog[index].installed = true
        }
    }
}
