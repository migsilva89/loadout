import SwiftUI
import AppKit
import LoadoutCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            ItemListView(model: model)
                .safeAreaInset(edge: .bottom, spacing: 0) { ListFooter(model: model) }
                .navigationSplitViewColumnWidth(min: 340, ideal: 392, max: 520)
        } detail: {
            DetailView(model: model)
        }
        .toolbar {
            // The context picker is what actually changes across a session; search and sort
            // moved into the list column itself, next to what they act on.
            ToolbarItem(placement: .navigation) {
                ContextPicker(model: model)
                    .controlSize(.regular)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isCreating = true
                } label: {
                    Label("New skill", systemImage: "plus")
                }
                .controlSize(.regular)
                .help("Create a new personal skill (⌘N)")
                .pointingHand()
            }
        }
        .background(WindowPlacement())

        .sheet(isPresented: $model.isCreating) { NewSkillSheet(model: model) }
        .sheet(item: $model.askCLI) { cli in CopilotSheet(model: model, cli: cli) }
        .sheet(isPresented: $model.isAddingAssistantCLI) { AssistantCLIFormSheet(model: model, editing: nil) }
        .sheet(item: $model.editingCustomAssistantCLI) { entry in AssistantCLIFormSheet(model: model, editing: entry) }
        .alert("Move \(model.selected?.name ?? "") to the Trash?", isPresented: $model.isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("The folder moves to the Trash, and a copy stays in the Loadout backups.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Context picker

struct ContextPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Menu {
            Picker("Context", selection: Binding(
                get: { model.context?.id },
                set: { id in
                    model.changeContext(to: model.projects.first { $0.id == id })
                }
            )) {
                Text("Global").tag(String?.none)
                Divider()
                ForEach(model.projects) { project in
                    Text(project.relativePath).tag(String?.some(project.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.context == nil ? "globe" : "folder")
                Text(model.context?.name ?? "Global")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("Switch which project's files Claude sees, or go back to Global")
        .pointingHand()
    }
}

// MARK: - List footer

/// The list column's bottom edge: Settings at the leading end — its home now that the sidebar
/// that used to carry it is gone — and the status text at the trailing end, sharing one line
/// the way they used to share one line split across two columns.
struct ListFooter: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: Metrics.sm) {
            SettingsLink {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                    Text("Settings")
                }
            }
            .buttonStyle(.plain)
            .help("Appearance, usage indexing, assistants and backups (⌘,)")
            .pointingHand()

            Spacer()

            if let progress = model.indexProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 100)
                Text("Indexing usage…")
            } else if let status = model.statusMessage {
                Image(systemName: "checkmark.circle")
                Text(status)
            } else {
                Text("\(model.items.count) \(model.items.count == 1 ? "item" : "items") · \(model.plugins.count) \(model.plugins.count == 1 ? "plugin" : "plugins")")
            }
            if model.isDirty {
                Text("unsaved")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Metrics.md)
        .padding(.vertical, Metrics.xs)
        .background(.bar)
    }
}
