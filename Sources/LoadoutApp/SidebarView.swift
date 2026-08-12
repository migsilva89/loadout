import SwiftUI
import LoadoutCore

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { newValue in
                if let newValue {
                    model.selection = newValue
                    model.select(model.visibleItems.first?.id)
                }
            }
        )) {
            Section("Sources") {
                row(.personal)
                if model.context != nil { row(.projectItems) }
                row(.disabled)
            }

            if !model.pluginsWithItems.isEmpty {
                Section("Plugins") {
                    ForEach(model.pluginsWithItems) { plugin in
                        PluginRow(model: model, plugin: plugin)
                            .tag(Selection.plugin(plugin.name))
                    }
                }
            }

            Section("More") {
                row(.kind(.command))
                row(.kind(.agent))
                row(.kind(.mcp))
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ selection: Selection) -> some View {
        HStack {
            Text(selection.title)
            Spacer()
            Text("\(model.count(for: selection))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .tag(selection)
    }
}

/// A plugin row carries its own switch, because a plugin is the only thing here with a
/// real on/off in Claude Code.
struct PluginRow: View {
    @Bindable var model: AppModel
    let plugin: PluginInfo

    var body: some View {
        HStack(spacing: 6) {
            Text(plugin.name)
                .foregroundStyle(plugin.enabled ? .primary : .secondary)
            Spacer()
            Text("\(model.count(for: .plugin(plugin.name)))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Toggle("", isOn: Binding(
                get: { plugin.enabled },
                set: { _ in model.togglePlugin(plugin) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(plugin.enabled ? "Disable the \(plugin.name) plugin" : "Enable the \(plugin.name) plugin")
        }
    }
}
