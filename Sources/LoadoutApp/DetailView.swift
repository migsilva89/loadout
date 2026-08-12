import SwiftUI
import LoadoutCore

struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let item = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(item)
                    if let warning = item.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    stats(item)
                    actions(item)
                    editor(item)
                    footer(item)
                }
                .padding(20)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView(
                "Escolhe alguma coisa",
                systemImage: "square.stack.3d.up",
                description: Text("A lista à esquerda tem tudo o que o Claude carrega.")
            )
        }
    }

    // MARK: - Pieces

    private func header(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 13) {
            RoundedRectangle(cornerRadius: 11)
                .fill(item.enabled ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: icon(for: item.kind))
                        .font(.system(size: 19))
                        .foregroundStyle(item.enabled ? Color.accentColor : .secondary)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 19, weight: .semibold))
                Text(subtitle(item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.kind == .skill, item.origin == .personal {
                Toggle("", isOn: Binding(
                    get: { item.enabled },
                    set: { _ in model.toggle(item) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(item.enabled ? "Desativar" : "Ativar")
            }
        }
    }

    private func stats(_ item: Item) -> some View {
        HStack(spacing: 9) {
            stat("Usos, 90 dias", "\(item.usage.count)")
            stat("Última vez", item.usage.lastUsed.map { Usage.relative($0) } ?? "—")
            stat("Projetos", "\(item.usage.projectCount)")
            stat("Tipo", item.kind.label)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func actions(_ item: Item) -> some View {
        HStack(spacing: 8) {
            Button("Abrir no editor") { model.openInEditor() }
            Button("Revelar no Finder") { model.revealInFinder() }
            if item.isEditable {
                Button("Pedir ao Claude") { model.isAskingClaude = true }
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
            if item.isEditable {
                Button("Guardar") { model.save() }
                    .disabled(!model.isDirty)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private func editor(_ item: Item) -> some View {
        if item.kind == .mcp {
            Text("Este servidor está definido dentro de ~/.claude.json, não num ficheiro próprio.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if item.isEditable {
            TextEditor(text: Binding(
                get: { model.draft },
                set: { model.draft = $0; model.isDirty = true }
            ))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 300)
            .padding(8)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Vem de um plugin, por isso é só de leitura.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(model.draft)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 300)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func footer(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let path = item.path {
                Text(path.path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
                ))
            }
            Text(item.usage.summary())
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func subtitle(_ item: Item) -> String {
        var parts = ["\(item.kind.label) \(item.origin.label)"]
        parts.append(item.enabled ? "ativa" : "desativada")
        if let modified = item.modified {
            parts.append("alterada \(Usage.relative(modified))")
        }
        return parts.joined(separator: " · ")
    }

    private func icon(for kind: ItemKind) -> String {
        switch kind {
        case .skill: return "doc.text"
        case .command: return "terminal"
        case .agent: return "person.2"
        case .mcp: return "network"
        case .plugin: return "puzzlepiece.extension"
        }
    }
}
