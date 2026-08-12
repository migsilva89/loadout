import SwiftUI
import LoadoutCore

struct ItemListView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedID },
            set: { model.select($0) }
        )) {
            ForEach(model.visibleItems) { item in
                ItemRow(item: item)
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
