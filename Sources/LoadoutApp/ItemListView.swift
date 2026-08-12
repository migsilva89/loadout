import SwiftUI
import LoadoutCore

struct ItemListView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            listHeader
            Divider()
            list
        }
    }

    /// The sort control belongs to the list, not to the window: it changes this column and
    /// nothing else.
    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("\(model.visibleItems.count) \(model.visibleItems.count == 1 ? "item" : "itens")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Picker("Ordenar", selection: $model.order) {
                ForEach(ItemSort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var list: some View {
        List(selection: Binding(
            get: { model.selectedID },
            set: { model.select($0) }
        )) {
            ForEach(model.visibleItems) { item in
                ItemRow(item: item, model: model)
                    .tag(item.id)
                    .contextMenu {
                        if item.kind == .skill, item.origin == .personal {
                            Button(item.enabled ? "Desativar" : "Ativar") { model.toggle(item) }
                        }
                        Button("Revelar no Finder") {
                            model.select(item.id)
                            model.revealInFinder()
                        }
                        Button("Abrir no editor") {
                            model.select(item.id)
                            model.openInEditor()
                        }
                        if item.isEditable {
                            Divider()
                            Button("Mandar para o Lixo", role: .destructive) {
                                model.select(item.id)
                                model.isConfirmingDelete = true
                            }
                        }
                    }
            }
        }
        .overlay {
            if model.visibleItems.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "Nada aqui" : "Sem resultados",
                    systemImage: model.query.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? "Esta fonte não tem nada. Cria uma skill com ⌘N."
                            : "Nada corresponde a \"\(model.query)\"."
                    )
                )
            }
        }
    }
}

struct ItemRow: View {
    let item: Item
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Badge(text: badgeText, tone: badgeTone)
                if item.warning != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(item.warning ?? "")
                }
                Spacer(minLength: 4)
                if item.kind == .skill, item.origin == .personal, item.enabled {
                    AssistantDots(item: item, model: model)
                }
                // Usage sits on its own, right-aligned: appended to the description it was
                // the first thing to be cut off, which is backwards.
                Text(usageBadge)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(item.usage.neverUsed ? Color.orange : Color.secondary)
                    .help(item.usage.summary())
            }
            Text(item.description.isEmpty ? item.kind.label : item.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
        .opacity(item.enabled ? 1 : 0.5)
    }

    private var usageBadge: String {
        guard item.enabled else { return "off" }
        return item.usage.neverUsed ? "0" : "\(item.usage.count)"
    }

    private var badgeText: String {
        if !item.enabled { return "desativada" }
        switch item.origin {
        case .personal: return item.kind == .skill ? "pessoal" : item.kind.label.lowercased()
        case .project(let name): return name
        case .plugin(let name): return name
        }
    }

    private var badgeTone: Badge.Tone {
        if !item.enabled { return .muted }
        switch item.origin {
        case .personal: return item.kind == .skill ? .own : .accent
        case .project: return .accent
        case .plugin: return .muted
        }
    }
}

struct Badge: View {
    enum Tone { case own, accent, muted }
    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(background, in: RoundedRectangle(cornerRadius: 5))
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch tone {
        case .own: return .green.opacity(0.16)
        case .accent: return .accentColor.opacity(0.16)
        case .muted: return .secondary.opacity(0.14)
        }
    }

    private var foreground: Color {
        switch tone {
        case .own: return .green
        case .accent: return .accentColor
        case .muted: return .secondary
        }
    }
}

/// Which assistants load this skill, using each one's real app icon where there is an app.
/// Only the ones that have it are shown; the gaps live in the detail pane, where there is
/// room for names.
struct AssistantDots: View {
    let item: Item
    @Bindable var model: AppModel

    private var present: [Assistant] { model.assistants.filter { item.assistants.contains($0.id) } }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(present) { assistant in
                AssistantMark(assistant: assistant, present: true)
                    .help("\(assistant.label) carrega esta skill")
            }
        }
    }
}

/// The full picture for the selected skill: every assistant on the machine, named, with the
/// ones that are missing it offering to take it.
struct AssistantPanel: View {
    let item: Item
    @Bindable var model: AppModel

    /// Three states, not two: has it, does not have it, or has nowhere to keep skills yet.
    private func status(_ assistant: Assistant, has: Bool) -> String {
        if has { return "tem" }
        return assistant.hasSkillsFolder ? "pôr lá" : "sem skills"
    }

    private func help(_ assistant: Assistant, has: Bool) -> String {
        if has { return "Clica para o \(assistant.label) deixar de carregar esta skill" }
        if assistant.hasSkillsFolder { return "Clica para pôr esta skill no \(assistant.label)" }
        return "O \(assistant.label) ainda não tem pasta de skills. Clicar cria \(assistant.skillsRoot.path) e põe esta lá."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Assistentes")
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 178), spacing: 8)],
                alignment: .leading, spacing: 6
            ) {
                ForEach(model.assistants) { assistant in
                    let has = item.assistants.contains(assistant.id)
                    Button {
                        model.setAssistant(assistant, on: item, present: !has)
                    } label: {
                        HStack(spacing: 7) {
                            AssistantMark(assistant: assistant, present: has, size: 18)
                            Text(assistant.label)
                                .font(.callout)
                                .foregroundStyle(has ? Color.primary : Color.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(status(assistant, has: has))
                                .font(.caption)
                                .foregroundStyle(
                                    has ? Color.secondary
                                        : (assistant.hasSkillsFolder ? Color.accentColor : Color.secondary)
                                )
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Color.secondary.opacity(has ? 0.10 : 0.04),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(help(assistant, has: has))
                }
            }
        }
    }
}
