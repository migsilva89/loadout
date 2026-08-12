import SwiftUI
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
            ToolbarItem(placement: .navigation) {
                ContextPicker(model: model)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isCreating = true
                } label: {
                    Label("Nova skill", systemImage: "plus")
                }
                .help("Nova skill (⌘N)")
            }
        }
        .background(WindowPlacement())
        .searchable(text: $model.query, placement: .toolbar, prompt: "Procurar")
        .safeAreaInset(edge: .bottom) { StatusBar(model: model) }
        .sheet(isPresented: $model.isCreating) { NewSkillSheet(model: model) }
        .sheet(isPresented: $model.isAskingClaude) { CopilotSheet(model: model) }
        .alert("Apagar \(model.selected?.name ?? "")?", isPresented: $model.isConfirmingDelete) {
            Button("Cancelar", role: .cancel) {}
            Button("Mandar para o Lixo", role: .destructive) { model.deleteSelected() }
        } message: {
            Text("A pasta vai para o Lixo, e fica uma cópia nos backups do Loadout.")
        }
        .alert(
            "Não deu",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("Está bem") { model.errorMessage = nil }
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
            Picker("Contexto", selection: Binding(
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
        .help("O que o Claude vê nesta pasta")
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
                Text("A indexar o uso…")
            } else if let status = model.statusMessage {
                Image(systemName: "checkmark.circle")
                Text(status)
            } else {
                Text("\(model.items.count) itens · \(model.plugins.count) plugins")
            }
            Spacer()
            if model.isDirty {
                Text("por guardar")
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
