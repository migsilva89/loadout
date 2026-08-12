import SwiftUI
import LoadoutCore

struct DetailView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

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

    /// The small uppercase tile captions ("TYPE", "LOCATION", …) needed more weight in light
    /// mode to hold the same contrast an uppercase label reads at in dark mode — dark was
    /// already legible at the smaller, lighter values, so only light gets the bump.
    private var captionSize: CGFloat { colorScheme == .dark ? 10 : 10.5 }
    private var captionWeight: Font.Weight { colorScheme == .dark ? .medium : .semibold }
    private var captionOpacity: Double { colorScheme == .dark ? 0.75 : 0.8 }

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
                if item.budget.descriptionCharacters > 0 || item.budget.bodyCharacters > 0 {
                    tokensTile(item)
                }
                if let size = fileSize(item) {
                    detailTile("Size", size)
                }
            }
            if let folder = item.directory ?? item.path?.deletingLastPathComponent() {
                filesTile(item, folder: folder)
            } else if let location = item.path {
                locationTile(location)
            }
        }
    }

    private func detailTile(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(caption.uppercased())
                .font(.system(size: captionSize, weight: captionWeight))
                .foregroundStyle(.primary.opacity(captionOpacity))
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

    /// The two costs, side by side and never added together: the description is loaded in every
    /// session whether or not the skill fires, the body only when it does. Estimated at four
    /// characters per token — there is no tokenizer on the machine, and the caption says so
    /// rather than implying a precision this cannot have.
    private func tokensTile(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("TOKENS, ESTIMATED")
                .font(.system(size: captionSize, weight: captionWeight))
                .foregroundStyle(.primary.opacity(captionOpacity))
            HStack(spacing: 10) {
                Text("\(item.budget.descriptionTokens) desc")
                    .font(.body.weight(.medium))
                    .foregroundStyle(item.budget.descriptionCharacters > Budget.maxDescriptionCharacters ? Color.orange : Color.primary)
                Text("\(item.budget.bodyTokens) body")
                    .font(.body.weight(.medium))
                    .foregroundStyle(item.budget.bodyLines > Budget.maxBodyLines ? Color.orange : Color.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
        .help("The description is loaded in every session, used or not. The body only when the skill triggers. Roughly four characters per token.")
    }

    /// "Files", not "Location": the folder usually holds more than the markdown — scripts,
    /// references, assets — and knowing what travels with a skill matters more than repeating
    /// a path whose head is already the item's name.
    private func filesTile(_ item: Item, folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("FILES")
                .font(.system(size: captionSize, weight: captionWeight))
                .foregroundStyle(.primary.opacity(captionOpacity))
            Text(displayPath(folder))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            let entries = folderContents(folder)
            if !entries.isEmpty {
                Text(entries.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// Everything beside the markdown, folders marked with a trailing slash.
    ///
    /// Resolves symlinks first: six of the real skills are links into a shared `.agents/skills`
    /// tree, and listing a link's contents without resolving it returns nothing at all.
    private func folderContents(_ folder: URL) -> [String] {
        let fm = FileManager.default
        let target = folder.resolvingSymlinksInPath()
        guard let entries = try? fm.contentsOfDirectory(
            at: target, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .map { url -> String in
                var isDirectory: ObjCBool = false
                _ = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return url.lastPathComponent + (isDirectory.boolValue ? "/" : "")
            }
            .sorted()
    }


    private func locationTile(_ location: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LOCATION")
                .font(.system(size: captionSize, weight: captionWeight))
                .foregroundStyle(.primary.opacity(captionOpacity))
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

    /// Only the controls. The file's name said nothing a person could not already see — it is
    /// `SKILL.md` for every skill, and the item's own name for a command or an agent — and its
    /// size moved into the Details grid, where the other facts about the file live.
    private func documentToolbar(_ item: Item) -> some View {
        HStack(spacing: Metrics.md) {
            actions(item)
            Spacer(minLength: Metrics.sm)
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
                    Text("Open folder")
                } icon: {
                    AppIconView(path: AppIconCache.editor(for: item.directory ?? item.path))
                }
            }
            .buttonStyle(.bordered)
            .help(editorHelp(item))
            .pointingHand()

            Button { model.revealInFinder() } label: {
                Label {
                    Text("Show folder")
                } icon: {
                    AppIconView(path: AppIconCache.finder)
                }
            }
            .buttonStyle(.bordered)
            .help(revealHelp(item))
            .pointingHand()

            if item.isEditable {
                askButton
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

    /// One button when exactly one assistant CLI is installed, a menu when there's a choice,
    /// and a disabled button naming what it's looking for when there's none. Whichever CLI is
    /// picked is what the sheet, opened right after, actually runs.
    @ViewBuilder
    private var askButton: some View {
        let clis = model.assistantCLIs
        if clis.isEmpty {
            Button {} label: {
                Label("Ask", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .disabled(true)
            .help("Looks for \(AssistantCLIRegistry.builtinLabels.joined(separator: ", ")) on your PATH — none of them are installed.")
            .pointingHand()
        } else if let only = clis.count == 1 ? clis.first : nil {
            Button { model.askAssistant(only) } label: {
                Label {
                    Text("Ask \(only.label)")
                } icon: {
                    assistantMark(for: only)
                }
            }
            .buttonStyle(.bordered)
            .help("Ask \(only.label) for help with this skill, in a sheet that writes nothing until you decide")
            .pointingHand()
        } else {
            Menu {
                ForEach(clis) { cli in
                    Button { model.askAssistant(cli) } label: {
                        Label {
                            Text(cli.label)
                        } icon: {
                            assistantMark(for: cli)
                        }
                    }
                }
            } label: {
                Label("Ask", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .help("Ask an assistant for help with this skill, in a sheet that writes nothing until you decide")
            .pointingHand()
        }
    }

    /// The real app icon when the CLI's id matches an installed assistant — `cursor-agent`
    /// maps to the `cursor` assistant, everything else matches its own id — and two letters
    /// otherwise, the same fallback `AssistantMark` already uses everywhere else.
    private func assistantMark(for cli: AssistantCLI) -> some View {
        let mappedID = cli.id == "cursor-agent" ? "cursor" : cli.id
        let assistant = model.assistants.first { $0.id == mappedID } ?? Assistant(
            id: mappedID, label: cli.label,
            skillsRoot: URL(fileURLWithPath: "/dev/null"),
            appPath: AssistantRegistry.known[mappedID]?.app
        )
        return AssistantMark(assistant: assistant, present: true)
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

    /// Names both the app and the folder, since the icon only hints at the first and the label
    /// says nothing about the second.
    private func editorHelp(_ item: Item) -> String {
        let folder = item.directory ?? item.path?.deletingLastPathComponent()
        let where_ = folder.map { displayPath($0) } ?? "this item"
        guard let app = AppIconCache.editor(for: folder ?? item.path) else {
            return "Open \(where_) in the default app"
        }
        let name = URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
        return "Open \(where_) in \(name) — scripts and references included"
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
