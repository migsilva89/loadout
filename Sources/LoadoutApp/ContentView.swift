import SwiftUI
import AppKit
import LoadoutCore

struct ContentView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 176, ideal: 200, max: 260)
        } content: {
            ItemListView(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            DetailView(model: model)
        }
        .toolbar {
            // The window's own icon, in place of printing "Loadout" next to the picker — the
            // title bar already says what app this is.
            ToolbarItem(placement: .navigation) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 18, height: 18)
            }
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
                .help("New skill (⌘N)")
            }
        }
        .background(WindowPlacement())
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search")
        .safeAreaInset(edge: .bottom) { StatusBar(model: model) }
        .sheet(isPresented: $model.isCreating) { NewSkillSheet(model: model) }
        .sheet(isPresented: $model.isAskingClaude) { CopilotSheet(model: model) }
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
        .help("What Claude sees in this folder")
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let progress = model.indexProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("Indexing usage…")
            } else if let status = model.statusMessage {
                Image(systemName: "checkmark.circle")
                Text(status)
            } else {
                Text("\(model.items.count) \(model.items.count == 1 ? "item" : "items") · \(model.plugins.count) \(model.plugins.count == 1 ? "plugin" : "plugins")")
            }
            Spacer()
            if model.isDirty {
                Text("unsaved")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.bar)
    }
}
