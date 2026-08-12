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
                    // No outer boxed section here: the grid's own tiles are the cards, and
                    // wrapping them in another same-colour box just merged the two into one
                    // undifferentiated slab.
                    VStack(alignment: .leading, spacing: Metrics.xs) {
                        Text("Details")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        detailRows(item)
                    }
                    if item.kind == .skill, item.origin == .personal, item.enabled {
                        section {
                            AssistantPanel(item: item, model: model)
                        }
                    }
                    // The toolbar — file name, size, and every button that acts on the file —
                    // sits above the box now, not inside it: the box holds the document, the
                    // way a toolbar sits above the document it controls rather than inside it.
                    VStack(alignment: .leading, spacing: Metrics.xs) {
                        documentToolbar(item)
                        VStack(alignment: .leading, spacing: 0) {
                            editor(item)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.sm)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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
                .tint(.green)
                .labelsHidden()
                .help(
                    item.enabled
                        ? "Move this skill to skills-off so Claude stops loading it"
                        : "Move this skill back to skills so Claude loads it again"
                )
                .pointingHand()
            }
        }
    }

    /// The frontmatter section: what the old header's second line and footer used to say, now
    /// as a reflowing grid of small cards instead of label/value rows. A grid scans the way a
    /// glance actually works — several facts at once, not one column read top to bottom — and
    /// it uses a wide pane's width instead of leaving it as dead margin either side of a list.
    private var detailColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: Metrics.xs)]
    }

    // `LazyVGrid`, unlike `Grid`, has no cell-spanning modifier — a tile inside it can't be
    // told to stretch across the row's other columns. Location is rendered as its own
    // full-width tile below the grid instead, which reads the same either way: a block of
    // small cards, with the one long value sitting underneath at the pane's own width.
    @ViewBuilder
    private func detailRows(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: Metrics.xs) {
            LazyVGrid(columns: detailColumns, alignment: .leading, spacing: Metrics.xs) {
                detailTile("Type", item.kind.label)
                detailTile("Source", originText(item))
                detailTile("State", item.enabled ? "Enabled" : "Disabled")
                if let modified = item.modified {
                    detailTile("Modified", Usage.relative(modified))
                }
                // What used to be one "Usage" row, split into the three facts it was
                // summarising — each is its own small answer, not a sentence to parse.
                detailTile("Uses", item.usage.count == 1 ? "1 use" : "\(item.usage.count) uses")
                detailTile("Last used", item.usage.lastUsed.map { Usage.relative($0) } ?? "Never")
                detailTile("Projects", "\(item.usage.projectCount)")
            }
            if let location = item.path ?? item.directory {
                locationTile(location)
            }
        }
    }

    private func detailTile(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption.uppercased())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(0.75))
            Text(value)
                .font(.body.weight(.medium))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        // A hairline border, not just a fill: a `.controlBackgroundColor` tile can sit on
        // almost the same tone as the pane behind it in light mode, and the fill alone stops
        // being enough to read as its own card. The border guarantees the edge either way.
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// The path gets its own full-width tile — a monospaced, truncate-from-the-middle string
    /// doesn't sit well next to short values in a two- or four-column grid, and it is the one
    /// value worth selecting and copying.
    private func locationTile(_ location: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LOCATION")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(0.75))
            Text(displayPath(location))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
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

    /// The file's name and size, and every control that acts on it, in one band above the
    /// document box — the way a toolbar relates to the document it controls. They share a
    /// line at the pane's normal width; only a narrower pane would force them apart.
    private func documentToolbar(_ item: Item) -> some View {
        HStack(spacing: Metrics.md) {
            HStack(spacing: Metrics.xs) {
                Text(item.path?.lastPathComponent ?? (item.kind == .mcp ? "Configuration" : "Document"))
                if let size = fileSize(item) {
                    Text(size)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            Spacer(minLength: Metrics.sm)
            actions(item)
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
            .pointingHand()

            Button { model.openInEditor() } label: {
                Label {
                    Text("Open in editor")
                } icon: {
                    AppIconView(path: AppIconCache.editor(for: item.path))
                }
            }
            .buttonStyle(.bordered)
            .help(editorHelp(item))
            .pointingHand()

            Button { model.revealInFinder() } label: {
                Label {
                    Text("Show in Finder")
                } icon: {
                    AppIconView(path: AppIconCache.finder)
                }
            }
            .buttonStyle(.bordered)
            .help(revealHelp(item))
            .pointingHand()

            if item.isEditable {
                Button { model.isAskingClaude = true } label: {
                    Label {
                        Text("Ask Claude")
                    } icon: {
                        AppIconView(path: AppIconCache.claude)
                    }
                }
                .buttonStyle(.bordered)
                .help("Ask Claude for help with this skill, in a sheet that writes nothing until you decide")
                .pointingHand()
            }

            Spacer()
            if item.isEditable {
                Button("Save") { model.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isDirty)
                    .keyboardShortcut("s", modifiers: .command)
                    .help("Write your changes to the file on disk (⌘S)")
                    .pointingHand()
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

    /// Names the app the button will actually use, since the icon alone only hints at it.
    private func editorHelp(_ item: Item) -> String {
        guard let path = AppIconCache.editor(for: item.path) else { return "Open in the default app" }
        return "Open in \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)"
    }

    /// Names the folder Finder will reveal, since neither the icon nor the label says where
    /// that actually is.
    private func revealHelp(_ item: Item) -> String {
        guard let location = item.directory ?? item.path else { return "Reveal this item in Finder" }
        return "Reveal \(displayPath(location)) in Finder"
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
