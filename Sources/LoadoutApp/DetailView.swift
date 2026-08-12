import SwiftUI
import LoadoutCore

/// The v2 detail pane: identity header with the one big switch, then cards — Token budget and
/// Details side by side, the Assistants grid, and the document with its own toolbar. Every
/// section is a rounded surface on the darker window ground, the way the design draws them.
struct DetailView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let item = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(item)
                    if let warning = item.warning {
                        warningCallout(warning)
                    }
                    // The two fact cards share a row while the pane is wide and stack when it
                    // isn't — same content either way.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            budgetCard(item).frame(maxWidth: .infinity)
                            detailsCard(item).frame(maxWidth: .infinity)
                        }
                        VStack(spacing: 12) {
                            budgetCard(item)
                            detailsCard(item)
                        }
                    }
                    if item.kind == .skill, item.origin == .personal, item.enabled {
                        assistantsCard(item)
                    }
                    documentCard(item)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(V2.window)
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "square.stack.3d.up",
                description: Text("The list on the left contains everything Claude loads.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(V2.window)
        }
    }

    // MARK: - Header

    private func header(_ item: Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(
                    LinearGradient(
                        colors: [item.kind.tint, item.kind.tint.opacity(0.65)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon(for: item.kind))
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                .saturation(item.enabled ? 1 : 0.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(V2.text)
                    .lineLimit(1)
                Text(subtitle(item))
                    .font(.system(size: 11.5))
                    .foregroundStyle(V2.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if item.kind == .skill, item.origin == .personal {
                Text(item.enabled ? "Enabled" : "Disabled")
                    .font(.system(size: 12.5))
                    .foregroundStyle(V2.textMid)
                MiniSwitch(on: item.enabled, width: 40, height: 24) { model.toggle(item) }
            }
        }
    }

    /// "Personal skill · 12 KB · modified 1 month ago" — origin, weight and age in one quiet line.
    private func subtitle(_ item: Item) -> String {
        var parts = [sourceText(item)]
        if let size = fileSize(item) { parts.append(size) }
        if let modified = item.modified { parts.append("modified \(Usage.relative(modified))") }
        return parts.joined(separator: " · ")
    }

    private func sourceText(_ item: Item) -> String {
        let kind = item.kind.label
        switch item.origin {
        case .personal: return "Personal \(kind.lowercased())"
        case .project(let name): return "\(kind) in \(name)"
        case .plugin(let name): return "\(kind) from \(name)"
        }
    }

    private func warningCallout(_ warning: String) -> some View {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12.5))
            .foregroundStyle(V2.amber)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(V2.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Token budget card

    private func budgetCard(_ item: Item) -> some View {
        V2Card {
            VStack(spacing: 0) {
                cardHeader { V2CardCaption(text: "Token budget") }
                meterRow(
                    label: "Description",
                    fraction: Double(item.budget.descriptionCharacters) / Double(Budget.maxDescriptionCharacters),
                    over: item.budget.descriptionCharacters > Budget.maxDescriptionCharacters,
                    value: "~\(item.budget.descriptionTokens) / ~\(Budget.estimatedTokens(characters: Budget.maxDescriptionCharacters)) tok"
                )
                meterRow(
                    label: "Body",
                    fraction: Double(item.budget.bodyLines) / Double(Budget.maxBodyLines),
                    over: item.budget.bodyLines > Budget.maxBodyLines,
                    value: "\(item.budget.bodyLines) / \(Budget.maxBodyLines) lines"
                )
            }
        }
        .help(budgetHelp(item))
    }

    private func meterRow(label: String, fraction: Double, over: Bool, value: String) -> some View {
        HStack(spacing: 11) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 78, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.4))
                    Capsule()
                        .fill(over ? V2.amber : V2.green)
                        .frame(width: proxy.size.width * min(1, max(0.02, fraction)))
                }
            }
            .frame(height: 5)
            Text(value)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(over ? V2.amber : Color.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5) }
    }

    private func budgetHelp(_ item: Item) -> String {
        let base = "The description is in context in every session, used or not. The body only when the skill triggers. Estimated at four characters per token."
        guard item.budget.isOverBudget else { return base }
        return (item.budget.breaches + [base]).joined(separator: "\n")
    }

    // MARK: - Details card

    private func detailsCard(_ item: Item) -> some View {
        V2Card {
            VStack(spacing: 0) {
                cardHeader { V2CardCaption(text: "Details") }
                detailRow(label: "Source", value: sourceText(item))
                detailRow(label: "Usage", value: usageValue(item))
                detailRow(label: "Last used", value: lastUsedValue(item))
                if let folder = item.directory ?? item.path?.deletingLastPathComponent() {
                    detailRow(
                        label: "Location", value: displayPath(folder), mono: true,
                        action: ("Reveal", { model.revealInFinder() }),
                        actionHint: "Reveal \(displayPath(folder)) in Finder"
                    )
                    let extras = folderContents(folder).filter { $0 != item.path?.lastPathComponent }
                    if !extras.isEmpty {
                        detailRow(label: "Files", value: extras.joined(separator: "  "), mono: true)
                    }
                }
            }
        }
    }

    private func detailRow(
        label: String, value: String, mono: Bool = false,
        action: (String, () -> Void)? = nil, actionHint: String = ""
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.white.opacity(0.5))
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(mono ? V2.textMid : Color.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let (title, act) = action {
                Button(action: act) {
                    Text(title)
                        .font(.system(size: 11.5))
                        .foregroundStyle(V2.link)
                }
                .buttonStyle(.plain)
                .help(actionHint)
                .pointingHand()
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5) }
    }

    private func usageValue(_ item: Item) -> String {
        guard item.usage.count > 0 else { return "Never used" }
        let uses = item.usage.count == 1 ? "1 use" : "\(item.usage.count) uses"
        let projects = item.usage.projectCount == 1 ? "1 project" : "\(item.usage.projectCount) projects"
        return "\(uses) in \(projects)"
    }

    private func lastUsedValue(_ item: Item) -> String {
        guard item.usage.count > 0, let last = item.usage.lastUsed else { return "— (last 90 days)" }
        return Usage.relative(last)
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

    /// Everything beside the markdown, folders marked with a trailing slash. Resolves symlinks
    /// first: several real skills are links into a shared `.agents/skills` tree, and listing
    /// a link's contents without resolving it returns nothing at all.
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

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
    }

    // MARK: - Assistants card

    private func assistantsCard(_ item: Item) -> some View {
        let assistants = model.visibleAssistants
        let loaded = assistants.filter { item.assistants.contains($0.id) }.count
        return V2Card {
            VStack(spacing: 0) {
                cardHeader {
                    HStack(spacing: 8) {
                        V2CardCaption(text: "Assistants")
                        Text("\(loaded) loaded of \(assistants.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(V2.textFaint)
                    }
                }
                // A fixed four-up grid, the design's shape: every assistant on the machine,
                // each row a click that adds or removes this skill for it.
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4),
                    spacing: 0
                ) {
                    ForEach(assistants) { assistant in
                        assistantCell(assistant, item: item)
                    }
                }
            }
        }
    }

    private func assistantCell(_ assistant: Assistant, item: Item) -> some View {
        let has = item.assistants.contains(assistant.id)
        let none = !has && !assistant.hasSkillsFolder
        return Button {
            model.setAssistant(assistant, on: item, present: !has)
        } label: {
            HStack(spacing: 9) {
                AssistantMark(assistant: assistant, present: has || !none, size: 20)
                Text(assistant.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(none ? 0.4 : 0.88))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(has ? "loaded" : (none ? "no skills" : "add"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(has ? V2.green : (none ? Color.white.opacity(0.25) : V2.link))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5) }
            .overlay(alignment: .trailing) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 0.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(assistantHelp(assistant, has: has))
        .pointingHand()
    }

    private func assistantHelp(_ assistant: Assistant, has: Bool) -> String {
        if has { return "Click to stop \(assistant.label) from loading this skill" }
        if assistant.hasSkillsFolder { return "Click to add this skill to \(assistant.label)" }
        return "\(assistant.label) doesn't have a skills folder yet. Click to create \(assistant.skillsRoot.path) and add this skill."
    }

    // MARK: - Document card

    private func documentCard(_ item: Item) -> some View {
        V2Card {
            VStack(spacing: 0) {
                documentToolbar(item)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                documentBody(item)
            }
        }
    }

    private func documentToolbar(_ item: Item) -> some View {
        HStack(spacing: 8) {
            // Reading or editing: one segmented switch, because they are the same document
            // in two modes.
            HStack(spacing: 1) {
                viewModeTab("Preview", selected: model.showsPreview) { model.showsPreview = true }
                viewModeTab("Edit", selected: !model.showsPreview) { model.showsPreview = false }
            }
            .padding(2)
            .background(V2.well, in: RoundedRectangle(cornerRadius: 7))

            if item.isEditable {
                askButton
            }

            Spacer(minLength: 8)

            budgetChip(item)

            if item.isEditable {
                Button("Revert") { model.revert() }
                    .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: model.isDirty))
                    .disabled(!model.isDirty)
                    .help("Throw away the unsaved changes and reload the file from disk")
                    .pointingHand()
                Button {
                    model.save()
                } label: {
                    HStack(spacing: 6) {
                        Text("Save")
                        Text("⌘S")
                            .font(.system(size: 11))
                            .opacity(0.6)
                    }
                }
                .buttonStyle(V2ToolbarButtonStyle(prominent: true, enabled: model.isDirty))
                .disabled(!model.isDirty)
                .keyboardShortcut("s", modifiers: .command)
                .help("Write your changes to the file on disk (⌘S)")
                .pointingHand()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private func viewModeTab(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                .padding(.horizontal, 13)
                .padding(.vertical, 4)
                .background(
                    selected ? Color.white.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(name == "Preview" ? "Read the document as rendered Markdown" : "Edit the raw file")
        .pointingHand()
    }

    /// The body's line count against the documented limit, always in view while editing —
    /// green while inside, amber the moment the file crosses the line.
    private func budgetChip(_ item: Item) -> some View {
        let over = item.budget.bodyLines > Budget.maxBodyLines
        let color = over ? V2.amber : V2.green
        return HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text("\(item.budget.bodyLines) / \(Budget.maxBodyLines) lines")
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.28), lineWidth: 0.5))
        .help(budgetHelp(item))
    }

    /// One button when exactly one assistant CLI is installed, a menu when there's a choice,
    /// and a disabled button naming what it's looking for when there's none.
    @ViewBuilder
    private var askButton: some View {
        let clis = model.assistantCLIs
        if clis.isEmpty {
            Button {} label: { askLabel }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: false))
                .disabled(true)
                .help("Looks for \(AssistantCLIRegistry.builtinLabels.joined(separator: ", ")) on your PATH — none of them are installed.")
        } else if let only = clis.count == 1 ? clis.first : nil {
            Button { model.askAssistant(only) } label: { askLabel }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                .help("Ask \(only.label) for help with this skill, in a sheet that writes nothing until you decide")
                .pointingHand()
        } else {
            Menu {
                ForEach(clis) { cli in
                    Button(cli.label) { model.askAssistant(cli) }
                }
            } label: {
                askLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(V2.button, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .help("Ask an assistant for help with this skill, in a sheet that writes nothing until you decide")
            .pointingHand()
        }
    }

    private var askLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(V2.link)
            Text("Ask")
                .font(.system(size: 12))
        }
    }

    // MARK: Document body

    @ViewBuilder
    private func documentBody(_ item: Item) -> some View {
        if item.kind == .mcp {
            Text("This server is defined in ~/.claude.json, not in a separate file.")
                .font(.system(size: 12.5))
                .foregroundStyle(V2.textMid)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.showsPreview {
            MarkdownView(text: model.draft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
        } else if item.isEditable {
            VStack(spacing: 0) {
                TextEditor(text: Binding(
                    get: { model.draft },
                    set: { model.draft = $0; model.isDirty = true }
                ))
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(minHeight: 320)
                .background(V2.editor)
                editorStatusBar
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("This comes from a plugin, so it's read-only.", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(V2.textDim)
                ScrollView {
                    Text(model.draft)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 300)
            }
            .padding(16)
        }
    }

    /// The design's editor footer: quiet facts about the buffer, nothing interactive.
    private var editorStatusBar: some View {
        HStack(spacing: 14) {
            Text("\(model.draft.components(separatedBy: "\n").count) lines")
            Text("Markdown")
            Text("UTF-8")
            Spacer()
            if model.isDirty {
                Text("unsaved")
                    .foregroundStyle(V2.amber)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(V2.textDim)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(V2.footer)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
    }

    // MARK: - Shared pieces

    private func cardHeader<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
            Spacer()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
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

/// The document toolbar's buttons: quiet pill normally, accent-filled for the one primary
/// action, both fading out instead of vanishing while there is nothing to act on.
struct V2ToolbarButtonStyle: ButtonStyle {
    var prominent: Bool
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(
                enabled ? (prominent ? Color.white : Color.white.opacity(0.85)) : Color.white.opacity(0.28)
            )
            .padding(.horizontal, prominent ? 12 : 11)
            .frame(height: 24)
            .background(
                enabled ? (prominent ? V2.accent : V2.button) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                Color.white.opacity(enabled && prominent ? 0.14 : 0.08), lineWidth: 0.5
            ))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
