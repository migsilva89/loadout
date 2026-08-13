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

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(plugin.enabled ? ItemKind.plugin.tint.opacity(0.2) : Color.white.opacity(0.06))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 14))
                        .foregroundStyle(plugin.enabled ? ItemKind.plugin.tint : V2.textDim)
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
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .help("\(plugin.name) — v\(plugin.version), \(itemCount) \(itemCount == 1 ? "item" : "items")")
    }
}
