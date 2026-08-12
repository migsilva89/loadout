import SwiftUI
import LoadoutCore

struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let item = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.md) {
                    header(item)
                    if let warning = item.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .padding(Metrics.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    }
                    section(header: { Text("Details") }) {
                        detailRows(item)
                    }
                    if item.kind == .skill, item.origin == .personal, item.enabled {
                        section {
                            AssistantPanel(item: item, model: model)
                        }
                    }
                    section(header: { documentHeader(item) }) {
                        VStack(alignment: .leading, spacing: Metrics.sm) {
                            actions(item)
                            editor(item)
                        }
                    }
                }
                // A fixed inset on both edges instead of a centred, capped column: the
                // sections reach the full width of the pane, the way a stock sidebar
                // inspector's boxes do.
                .padding(.horizontal, Metrics.lg)
                .padding(.vertical, Metrics.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "square.stack.3d.up",
                description: Text("The list on the left contains everything Claude loads.")
            )
        }
    }

    // MARK: - Sections

    /// A titled, full-width box — the hand-rolled stand-in for a grouped `Form` section, used
    /// because the real one caps its content to a centred column and leaves dead margins on
    /// a wide pane. Same look (a system surface, a quiet header), without the cap.
    private func section<Header: View, Content: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.xs) {
            header()
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.sm)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func section<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.sm)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Pieces

    /// Identity only — name, kind and the enable switch. What used to be a second line of
    /// prose here ("Personal skill · enabled · modified 2 days ago") now lives as real rows
    /// in the Details section below, instead of being said twice.
    private func header(_ item: Item) -> some View {
        HStack(alignment: .center, spacing: Metrics.md) {
            RoundedRectangle(cornerRadius: 11)
                .fill(item.enabled ? Color.accentColor.opacity(0.15) : Color(nsColor: .quaternaryLabelColor))
                .frame(width: 42, height: 42)
                .overlay {
                    Image(systemName: icon(for: item.kind))
                        .font(.system(size: 19))
                        .foregroundStyle(item.enabled ? Color.accentColor : .secondary)
                }
            Text(item.name)
                .font(.system(size: 19, weight: .semibold))
                .lineLimit(1)
            // The switch belongs at the far edge, not glued to the title: it acts on the whole
            // item, and a control touching the name reads as part of the name.
            Spacer(minLength: Metrics.md)
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

    /// The frontmatter section: what the old header's second line and footer used to say,
    /// now as a stock, labelled list of fields instead of a caption to be parsed.
    @ViewBuilder
    private func detailRows(_ item: Item) -> some View {
        detailRow("Type", item.kind.label)
        Divider()
        detailRow("Source", originText(item))
        Divider()
        detailRow("State", item.enabled ? "Enabled" : "Disabled")
        if let modified = item.modified {
            Divider()
            detailRow("Modified", Usage.relative(modified))
        }
        Divider()
        detailRow("Usage", item.usage.summary())
        if let location = item.path ?? item.directory {
            Divider()
            detailRow("Location", displayPath(location), selectable: true)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer(minLength: Metrics.md)
            if selectable {
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 6)
    }

    /// "Personal", not "Personal skill": the section header already reads "Details", and the
    /// row above already says "Type" — repeating the kind here would say it a third time.
    private func originText(_ item: Item) -> String {
        switch item.origin {
        case .personal: return "Personal"
        case .project(let name): return name
        case .plugin(let name): return name
        }
    }

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
    }

    /// The document section's header: the one place the file's name and size live, so it is
    /// obvious where the document itself begins, below the details above it.
    private func documentHeader(_ item: Item) -> some View {
        HStack {
            Text(item.path?.lastPathComponent ?? (item.kind == .mcp ? "Configuration" : "Document"))
            Spacer()
            if let size = fileSize(item) {
                Text(size)
            }
        }
    }

    private func fileSize(_ item: Item) -> String? {
        guard let path = item.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let bytes = attributes[.size] as? Int
        else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func actions(_ item: Item) -> some View {
        HStack(spacing: Metrics.xs) {
            // Reading or editing: one switch, because they are the same pane in two modes.
            Picker("", selection: Binding(
                get: { model.showsPreview },
                set: { model.showsPreview = $0 }
            )) {
                Text("Read").tag(true)
                Text("Edit").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(model.showsPreview ? "View raw file" : "View as Markdown")

            Button("Open in editor") { model.openInEditor() }
                .buttonStyle(.bordered)
            Button("Show in Finder") { model.revealInFinder() }
                .buttonStyle(.bordered)
            if item.isEditable {
                Button("Ask Claude") { model.isAskingClaude = true }
                    .buttonStyle(.bordered)
            }

            Spacer()
            if item.isEditable {
                Button("Save") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDirty)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func editor(_ item: Item) -> some View {
        if item.kind == .mcp {
            Text("This server is defined in ~/.claude.json, not in a separate file.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if model.showsPreview {
            MarkdownView(text: model.draft)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if item.isEditable {
            TextEditor(text: Binding(
                get: { model.draft },
                set: { model.draft = $0; model.isDirty = true }
            ))
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 300)
            .padding(Metrics.xs)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        } else {
            VStack(alignment: .leading, spacing: Metrics.xs) {
                Label("This comes from a plugin, so it's read-only.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(model.draft)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 300)
            }
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
