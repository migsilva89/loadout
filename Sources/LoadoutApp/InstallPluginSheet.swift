import SwiftUI
import LoadoutCore

/// Find a plugin and put it into Claude Code, Codex or opencode.
///
/// Claude Code and Codex publish catalogues, so those two are a searchable list with an Install
/// button on each row. opencode has none: a plugin is an npm package or a git URL, so it gets a
/// field to type one into.
struct InstallPluginSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var packageSpec = ""
    @State private var marketplaceSource = ""
    @State private var addingMarketplace = false

    private var assistant: String { model.pluginInstallAssistant }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install a plugin")
                .font(.title3.weight(.semibold))
            assistantPicker
            if assistant == "opencode" {
                packageForm
            } else {
                catalogue
                if assistant == "claude" { marketplaceForm }
            }
            if let error = model.pluginInstallError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if let receipt = model.pluginReceipt {
                Label(receipt, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("A copy of the files each tool is about to change goes to the Loadout backups first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .help("Close this")
                    .pointingHand()
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: Which assistant

    private var assistantPicker: some View {
        HStack(spacing: 6) {
            ForEach(model.pluginAssistants) { candidate in
                let selected = candidate.id == assistant
                Button {
                    model.selectPluginInstallAssistant(candidate.id)
                } label: {
                    HStack(spacing: 6) {
                        AssistantMark(assistant: candidate, present: true, size: 16)
                        Text(candidate.label).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(selected ? V2.accent.opacity(0.18) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? V2.accent.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Install into \(candidate.label)")
                .pointingHand()
            }
            Spacer()
        }
    }

    // MARK: Catalogue (Claude Code, Codex)

    private var matches: [PluginCatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.pluginCatalog
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(needle) || $0.summary.lowercased().contains(needle)
                || $0.marketplace.lowercased().contains(needle)
        }
    }

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search \(model.pluginCatalog.count) plugins", text: $query)
                .textFieldStyle(.roundedBorder)
            ZStack {
                if model.isLoadingPluginCatalog {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Asking \(assistant == "claude" ? "Claude Code" : "Codex") what its marketplaces offer…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if let error = model.pluginCatalogError {
                    Text(error).font(.callout).foregroundStyle(.secondary).padding()
                } else if matches.isEmpty {
                    Text(model.pluginCatalog.isEmpty ? "No marketplace offers a plugin yet." : "Nothing matches “\(query)”.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            // Capped: Claude Code's official marketplace alone lists hundreds, and
                            // a list nobody scrolls to the end of is better searched than drawn.
                            ForEach(matches.prefix(80)) { entry in row(entry) }
                        }
                    }
                }
            }
            .frame(height: 300)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ entry: PluginCatalogEntry) -> some View {
        let busy = model.busyPlugins.contains(entry.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.system(size: 13, weight: .medium))
                    if !entry.marketplace.isEmpty {
                        Text(entry.marketplace).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    }
                    if let count = entry.installCount {
                        Text("\(count.formatted()) installs").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                if !entry.summary.isEmpty {
                    Text(entry.summary)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 6)
            if entry.installed {
                Label("Installed", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(busy ? "Installing…" : "Install") { model.install(entry) }
                    .disabled(busy || !model.busyPlugins.isEmpty)
                    .help("Install \(entry.name) into \(assistant == "claude" ? "Claude Code" : "Codex")")
                    .pointingHand()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A marketplace is where Claude Code finds plugins, and adding one is deciding to trust it —
    /// so it sits apart from the list, behind its own disclosure.
    private var marketplaceForm: some View {
        DisclosureGroup("Add a marketplace", isExpanded: $addingMarketplace) {
            HStack {
                TextField("owner/repo, a git URL or a folder", text: $marketplaceSource)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addMarketplace)
                Button("Add", action: addMarketplace)
                    .disabled(marketplaceSource.trimmingCharacters(in: .whitespaces).isEmpty || !model.busyPlugins.isEmpty)
                    .help("Have Claude Code add this marketplace, then list what it offers")
                    .pointingHand()
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private func addMarketplace() {
        let source = marketplaceSource.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { return }
        model.addPluginMarketplace(source)
        marketplaceSource = ""
    }

    // MARK: opencode

    private var packageForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("opencode has no catalogue: a plugin is an npm package or a git repository. Name one and opencode installs it and adds it to its configuration.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("opencode-wakatime  ·  pkg@1.2.3  ·  git+https://…", text: $packageSpec)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addPackage)
                Button(model.busyPlugins.isEmpty ? "Install" : "Installing…", action: addPackage)
                    .disabled(packageSpec.trimmingCharacters(in: .whitespaces).isEmpty || !model.busyPlugins.isEmpty)
                    .help("Run `opencode plugin add` with this package")
                    .pointingHand()
            }
        }
    }

    private func addPackage() {
        let spec = packageSpec.trimmingCharacters(in: .whitespaces)
        guard !spec.isEmpty else { return }
        model.install(spec: spec, assistant: "opencode")
        packageSpec = ""
    }
}
