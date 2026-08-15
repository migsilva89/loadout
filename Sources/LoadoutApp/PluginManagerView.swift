import SwiftUI
import LoadoutCore

/// One row per installed plugin: name, version and item count are all a person needs to
/// decide whether to flip it. Restyled onto the v2 sidebar surface; the switch is the same
/// hand-drawn one the item rows use.
struct PluginManagerView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(model.plugins) { plugin in
                    PluginManagerRow(model: model, plugin: plugin)
                }
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if model.plugins.isEmpty {
                ContentUnavailableView(
                    "No plugins installed",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Plugins installed through Claude Code will show up here.")
                )
            }
        }
    }
}

struct PluginManagerRow: View {
    @Bindable var model: AppModel
    let plugin: PluginInfo

    private var itemCount: Int {
        model.items.filter { $0.origin == .plugin(plugin.name) }.count
    }

    private var isSelected: Bool { model.selectedPluginID == plugin.id }

    var body: some View {
        row
            .background(isSelected ? V2.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            // The row is a button around everything except the switch, which keeps its own tap:
            // selecting a plugin to look at it and flipping it are different intentions.
            .onTapGesture { model.selectedPluginID = plugin.id }
            .pointingHand()
    }

    private var row: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(plugin.enabled ? V2.accent.opacity(0.2) : Color.white.opacity(0.06))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 14))
                        .foregroundStyle(plugin.enabled ? V2.accent : V2.textDim)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(plugin.enabled ? V2.text : V2.textDim)
                // In a project scope the inventory holds only the project's items, so the
                // per-plugin count would read a false 0 — plugins are global installs, and
                // the row says so instead.
                Text(
                    model.context == nil
                        ? "\(itemCount) \(itemCount == 1 ? "item" : "items") · v\(plugin.version)"
                        : "v\(plugin.version) · global"
                )
                    .font(.system(size: 11.5))
                    .foregroundStyle(V2.textDim)
            }
            Spacer(minLength: 6)
            MiniSwitch(on: plugin.enabled) { model.togglePlugin(plugin) }
                .help(
                    plugin.enabled
                        ? "Turn off the \(plugin.name) plugin so Claude stops loading what it ships"
                        : "Turn on the \(plugin.name) plugin so Claude loads what it ships"
                )
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(plugin.name) — v\(plugin.version), \(itemCount) \(itemCount == 1 ? "item" : "items")")
    }
}

/// What a plugin brought with it, and which of it is switched on (AC3.17).
///
/// The plugin's own switch decides whether it is in the house at all; this is where a plugin gets
/// trimmed — a 38-item plugin you wanted three things from is the ordinary case, not the odd one.
struct PluginDetailView: View {
    @Bindable var model: AppModel
    let plugin: PluginInfo

    private var items: [Item] { model.itemsOfPlugin(plugin) }
    /// Skills and commands both have a switch of their own now, so they belong in the same list —
    /// splitting them left a plugin command switchable in one place and not in the other.
    private var switchable: [Item] { items.filter { $0.kind == .skill || $0.kind == .command } }
    private var rest: [Item] { items.filter { $0.kind != .skill && $0.kind != .command } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !plugin.enabled {
                    Text("The whole plugin is off, so nothing here is loaded. The switches below are each item's own choice, kept for when you turn the plugin back on.")
                        .font(.system(size: 12))
                        .foregroundStyle(V2.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !switchable.isEmpty {
                    section("Skills and commands", items: switchable, switchable: true)
                }
                if !rest.isEmpty {
                    // Subagents have no per-item switch inside a plugin's detail — the Agents tab
                    // is where they are switched — so they are listed without one. MCP servers are
                    // not named here: no plugin on this machine declares any, and promising a list
                    // the scanner does not read was a promise the screen could not keep.
                    section("Also ships", items: rest, switchable: false)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(V2.window)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(plugin.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(V2.text)
                MiniSwitch(on: plugin.enabled, width: 40, height: 24) { model.togglePlugin(plugin) }
                    .help(plugin.enabled ? "Turn the whole plugin off" : "Turn the whole plugin on")
            }
            Text("v\(plugin.version)\(plugin.marketplace.isEmpty ? "" : " · from \(plugin.marketplace)")")
                .font(.system(size: 12))
                .foregroundStyle(V2.textDim)
        }
    }

    private func section(_ title: String, items: [Item], switchable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(V2.textDim)
            VStack(spacing: 1) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(item.enabled ? V2.text : V2.textDim)
                            Text(item.description)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.white.opacity(0.42))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 6)
                        if switchable {
                            MiniSwitch(on: item.enabled) { model.toggle(item) }
                                .help(
                                    item.enabled
                                        ? "Disable just \(item.name), leaving the rest of the plugin alone"
                                        : "Enable \(item.name) again"
                                )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(V2.card, in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }
}
