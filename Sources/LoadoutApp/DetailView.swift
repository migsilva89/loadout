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
                    if item.kind == .skill, item.origin == .personal, item.enabled {
                        AssistantPanel(item: item, model: model)
                    }
                    actions(item)
                    editor(item)
                    footer(item)
                }
                .padding(20)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "square.stack.3d.up",
                description: Text("The list on the left contains everything Claude loads.")
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
                metadataLine(item)
                    .font(.caption)
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
                .help(item.enabled ? "Disable" : "Enable")
            }
        }
    }

    /// One quiet line instead of four cards competing for attention: the file below is what
    /// the pane is for, and these numbers are context for it, not the headline.
    private func metadataLine(_ item: Item) -> Text {
        var parts: [String] = ["\(item.usage.count) uses"]
        if let last = item.usage.lastUsed {
            parts.append("last used \(Usage.relative(last))")
        }
        if item.usage.projectCount > 0 {
            parts.append("\(item.usage.projectCount) \(item.usage.projectCount == 1 ? "project" : "projects")")
        }
        return Text(parts.joined(separator: " · "))
    }

    private func actions(_ item: Item) -> some View {
        HStack(spacing: 8) {
            // Reading or editing: one switch, because they are the same pane in two modes.
            Picker("", selection: Binding(
                get: { model.showsPreview },
                set: { model.showsPreview = $0 }
            )) {
                Image(systemName: "eye").tag(true)
                Image(systemName: "chevron.left.forwardslash.chevron.right").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(model.showsPreview ? "View raw file" : "View as Markdown")

            Button { model.openInEditor() } label: { Image(systemName: "arrow.up.forward.app") }
                .help("Open in editor")
            Button { model.revealInFinder() } label: { Image(systemName: "folder") }
                .help("Show in Finder")
            if item.isEditable {
                Button { model.isAskingClaude = true } label: { Image(systemName: "bubble.left.and.text.bubble.right") }
                    .help("Ask Claude")
            }

            Spacer()
            if item.isEditable {
                Button("Save") { model.save() }
                    .disabled(!model.isDirty)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private func editor(_ item: Item) -> some View {
        if item.kind == .mcp {
            Text("This server is defined in ~/.claude.json, not in a separate file.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if model.showsPreview {
            MarkdownView(text: model.draft)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
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
                Label("This comes from a plugin, so it's read-only.", systemImage: "lock")
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
        var parts = [subtitleOrigin(item)]
        parts.append(item.enabled ? "enabled" : "disabled")
        if let modified = item.modified {
            parts.append("modified \(Usage.relative(modified))")
        }
        return parts.joined(separator: " · ")
    }

    /// "Personal skill", "vercel command" — the origin qualifies the kind, so it reads as
    /// English rather than as two labels stapled together.
    private func subtitleOrigin(_ item: Item) -> String {
        switch item.origin {
        case .personal: return "Personal \(item.kind.label.lowercased())"
        case .project(let name): return "\(item.kind.label) in \(name)"
        case .plugin(let name): return "\(item.kind.label) from \(name)"
        }
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
