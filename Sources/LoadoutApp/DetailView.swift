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
    /// Label and value in two columns, the way a Mac inspector states facts — Get Info, the
    /// Xcode inspector, the Finder's own panes. The boxed mini-cards this replaces were
    /// dashboard vocabulary: nine bordered tiles with uppercase captions, each drawing a frame
    /// around four characters. A calm pair of columns says the same in a third of the space.
    @ViewBuilder
    private func detailRows(_ item: Item) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Metrics.md, verticalSpacing: 7) {
            field("Type", item.kind.label)
            field("Source", originText(item))
            field("State", item.enabled ? "Enabled" : "Disabled")
            if let modified = item.modified {
                field("Modified", Usage.relative(modified))
            }
            if let size = fileSize(item) {
                field("Size", size)
            }
            usageField(item)
            if item.budget.descriptionCharacters > 0 || item.budget.bodyCharacters > 0 {
                tokensField(item)
            }
            if let folder = item.directory ?? item.path?.deletingLastPathComponent() {
                filesField(item, folder: folder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    /// Three numbers that answer one question, so they share one line instead of three frames.
    private func usageField(_ item: Item) -> some View {
        GridRow {
            Text("Usage")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(usageSentence(item))
        }
        .font(.callout)
    }

    private func usageSentence(_ item: Item) -> String {
        guard item.usage.count > 0 else { return "Never used in the last 90 days" }
        let uses = item.usage.count == 1 ? "1 use" : "\(item.usage.count) uses"
        let last = item.usage.lastUsed.map { Usage.relative($0) } ?? "unknown"
        let projects = item.usage.projectCount == 1 ? "1 project" : "\(item.usage.projectCount) projects"
        return "\(uses) · last \(last) · \(projects)"
    }

    /// The description is loaded in every session whether the skill fires or not; the body only
    /// on trigger. Two costs, never summed, and orange the moment one breaks a documented limit.
    private func tokensField(_ item: Item) -> some View {
        GridRow {
            Text("Tokens")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            HStack(spacing: 6) {
                Text("~\(item.budget.descriptionTokens) description")
                    .foregroundStyle(item.budget.descriptionCharacters > Budget.maxDescriptionCharacters ? Color.orange : Color.primary)
                Text("·").foregroundStyle(.tertiary)
                Text("~\(item.budget.bodyTokens) body")
                    .foregroundStyle(item.budget.bodyLines > Budget.maxBodyLines ? Color.orange : Color.primary)
                if item.budget.isOverBudget {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(item.budget.breaches.joined(separator: "\n"))
                }
            }
        }
        .font(.callout)
        .help("The description is in context in every session, used or not. The body only when the skill triggers. Estimated at four characters per token.")
    }

    /// The folder, what travels with it, and the two actions that act on it — all in the same
    /// row, because a button that opens this folder belongs beside the folder's own name.
    private func filesField(_ item: Item, folder: URL) -> some View {
        GridRow {
            Text("Files")
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 5) {
                Text(displayPath(folder))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                let entries = folderContents(folder)
                if !entries.isEmpty {
                    Text(entries.joined(separator: "   "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: Metrics.xs) {
                    Button { model.openInEditor() } label: {
                        Label {
                            Text("Open")
                        } icon: {
                            AppIconView(path: AppIconCache.editor(for: item.directory ?? item.path))
                        }
                    }
                    .help(editorHelp(item))
                    .pointingHand()

                    Button { model.revealInFinder() } label: {
                        Label {
                            Text("Finder")
                        } icon: {
                            AppIconView(path: AppIconCache.finder)
                        }
                    }
                    .help(revealHelp(item))
                    .pointingHand()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 1)
            }
        }
        .font(.callout)
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
                Image(systemName: "eye").tag(true)
                Image(systemName: "square.and.pencil").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(model.showsPreview ? "View raw file" : "View as Markdown")
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
