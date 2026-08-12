import SwiftUI
import LoadoutCore

struct ItemListView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFieldFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            KindBar(model: model)
            Divider()
            if model.selection == .plugins {
                pluginHeader
                Divider()
                PluginManagerView(model: model)
            } else {
                listHeader
                FilterChipsView(model: model)
                Divider()
                list
            }
        }
        // ⌘F is a window-level command with no view of its own; it asks the model to focus,
        // and this is the only place that can turn that into the real `@FocusState`.
        .onChange(of: model.searchFocused) { _, wantsFocus in
            if wantsFocus { searchFieldFocused = true }
        }
        .onChange(of: searchFieldFocused) { _, focused in
            if !focused { model.searchFocused = false }
        }
    }

    /// The scope and count used to live in a "56 items" label; now they live in the search
    /// field's own placeholder, so the field is the first thing read rather than a caption
    /// above it. The sort menu sits at the same row's trailing end, quiet on purpose — it is
    /// a secondary control, not a peer of search.
    private var listHeader: some View {
        HStack(spacing: Metrics.xs) {
            searchField
            assistantMenu
            sortMenu
        }
        .padding(.horizontal, Metrics.sm)
        .padding(.top, Metrics.xs)
        .padding(.bottom, Metrics.xs)
    }

    private var searchField: some View {
        HStack(spacing: Metrics.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(searchPlaceholder, text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .onExitCommand {
                    model.query = ""
                    searchFieldFocused = false
                }
        }
        .padding(.horizontal, Metrics.xs)
        .padding(.vertical, 5)
        .background(searchFieldFill, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            if colorScheme == .light {
                RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.14))
            }
        }
        .frame(maxWidth: .infinity)
        .help("Filter the list as you type (⌘F)")
        .pointingHand()
    }

    /// `.controlBackgroundColor` alone read as a floating placeholder against a white pane —
    /// only light mode gets the stronger fill and the hairline border above; dark was fine.
    private var searchFieldFill: Color {
        colorScheme == .dark ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(0.06)
    }

    private var searchPlaceholder: String {
        let count = model.visibleItems.count
        let noun = model.selection.searchNoun(plural: count != 1)
        return "Search \(count) \(noun)"
    }

    /// A menu rather than the old segmented control: sort is a secondary decision next to
    /// search, and a menu reads quieter than a two-button toggle competing for the eye.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $model.order) {
                ForEach(ItemSort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text(model.order.label)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Change the order the list is sorted in")
        .pointingHand()
    }

    /// Only skills carry assistants, so this only appears while the sidebar is on Skills —
    /// showing it elsewhere would be a control with nothing to act on. What used to be a
    /// "2+" chip nobody could decode now reads as a real sentence, and picking one assistant
    /// by name is new: the old chip could only ever say "more than one".
    @ViewBuilder
    private var assistantMenu: some View {
        if model.selection == .skills {
            Menu {
                Picker("Assistant", selection: $model.assistantFilter) {
                    Text("Any").tag(AssistantFilter.any)
                        .help("Show skills regardless of which assistants load them")
                    Text("In more than one").tag(AssistantFilter.multiple)
                        .help("Show only skills loaded by more than one assistant")
                    Divider()
                    ForEach(model.visibleAssistants) { assistant in
                        Text(assistant.label).tag(AssistantFilter.one(assistant.id))
                            .help("Show only skills that \(assistant.label) loads")
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.crop.circle")
                    Text(assistantMenuLabel)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Only show skills a particular assistant loads")
            .pointingHand()
        }
    }

    private var assistantMenuLabel: String {
        switch model.assistantFilter {
        case .any: return "Assistant: Any"
        case .multiple: return "Assistant: In more than one"
        case .one(let id):
            let label = model.visibleAssistants.first { $0.id == id }?.label ?? id
            return "Assistant: \(label)"
        }
    }

    private var pluginHeader: some View {
        HStack {
            Text("\(model.plugins.count) \(model.plugins.count == 1 ? "plugin" : "plugins")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
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
                            Button(item.enabled ? "Disable" : "Enable") { model.toggle(item) }
                        }
                        Button("Show in Finder") {
                            model.select(item.id)
                            model.revealInFinder()
                        }
                        Button("Open in editor") {
                            model.select(item.id)
                            model.openInEditor()
                        }
                        if item.isEditable {
                            Divider()
                            Button("Move to Trash", role: .destructive) {
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
                    model.query.isEmpty ? "Nothing here" : "No results",
                    systemImage: model.query.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? "This source is empty. Create a skill with ⌘N."
                            : "Nothing matches \"\(model.query)\"."
                    )
                )
            }
        }
        // Rebuilds the List's own identity whenever the kind bar switches rows, instead of
        // diffing the old NSTableView-backed content in place. Without this, a kind whose
        // items are all disabled can land the List on a stale internal layout from the
        // previous kind — selection and counts update correctly, but the rows never draw and
        // the empty-state overlay never appears either, since `visibleItems` genuinely isn't
        // empty. Forcing a fresh List per kind is the same fix `.id()` gives any List/ForEach
        // pairing that reuses identity across an unrelated content swap.
        .id(model.selection)
    }
}

// MARK: - Filter chips

/// Origin and state, as a single-selection row of chips above the list. They combine with
/// whichever sidebar row is picked — "Skills" + "Never used" reads as one sentence.
struct FilterChipsView: View {
    @Bindable var model: AppModel

    /// All · Personal · From plugins · Never used · Off — origin chips lead, state chips
    /// trail. "In 2+ assistants" used to close the row here; it's the assistant menu next to
    /// sort now, since a "2+" chip explained nothing on its own and still wrapped to a second
    /// line at the column's normal width.
    private var chips: [ItemFilter] {
        var base: [ItemFilter] = [.all, .mine]
        if model.context != nil { base.append(.thisProject) }
        base.append(contentsOf: [.fromPlugins, .neverUsed, .disabled])
        // Only offered where it can mean something: only documents have a budget to break.
        if model.selection == .skills || model.selection == .commands || model.selection == .agents {
            base.append(.overBudget)
        }
        return base
    }

    var body: some View {
        // Wrapping, not scrolling: a filter you have to scroll sideways to discover is a
        // filter nobody uses, and the last chip was falling off the edge of the column.
        // Now that "2+" moved out to the assistant menu, the five that remain on their full
        // names still need a tighter chip to clear the list column at its normal width —
        // ChipFlow is still there as the fallback for anything narrower.
        ChipFlow(spacing: 4, lineSpacing: 5) {
            ForEach(chips, id: \.self) { chip in
                FilterChip(
                    title: chip.shortTitle,
                    hint: chip.hint,
                    count: model.count(for: chip),
                    isActive: model.filter == chip
                ) {
                    model.filter = chip
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

private struct FilterChip: View {
    let title: String
    let hint: String
    let count: Int
    let isActive: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    /// A chip with nothing in it stays clickable — the zero is itself information — but reads
    /// quieter, so an eye scanning the row lands on the chips that actually have something.
    private var isEmpty: Bool { count == 0 && !isActive }

    /// `Color.primary.opacity(x)` reads very differently on the two grounds — dark mode was
    /// already fine, light mode read as floating text rather than a control — so these branch
    /// on appearance instead of picking one value that compromises both.
    private var fill: Color {
        isActive ? Color.accentColor : Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.10)
    }

    private var border: Color {
        colorScheme == .dark ? Color(nsColor: .separatorColor) : Color.primary.opacity(0.16)
    }

    private var countColor: Color {
        if isActive { return Color.white.opacity(0.8) }
        return colorScheme == .dark ? Color.primary.opacity(0.75) : Color.primary.opacity(0.9)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .foregroundStyle(countColor)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(fill, in: Capsule())
            .overlay {
                if !isActive {
                    Capsule().strokeBorder(border)
                }
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .opacity(isEmpty ? 0.45 : 1)
        }
        .buttonStyle(.borderless)
        // The short label is deliberately terse; the hover tooltip says the whole sentence.
        .help(hint)
        .pointingHand()
    }
}

// MARK: - Plugin manager

/// What used to be a toggle buried in the sidebar, one row per plugin: name, version and item
/// count are all a person needs to decide whether to flip it.
struct PluginManagerView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            ForEach(model.plugins) { plugin in
                PluginManagerRow(model: model, plugin: plugin)
            }
        }
        .overlay {
            if model.plugins.isEmpty {
                ContentUnavailableView(
                    "No plugins installed",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Plugins installed through Claude Code will show up here.")
                )
            }
        }
    }
}

struct PluginManagerRow: View {
    @Bindable var model: AppModel
    let plugin: PluginInfo

    private var itemCount: Int {
        model.items.filter { $0.origin == .plugin(plugin.name) }.count
    }

    var body: some View {
        HStack(spacing: Metrics.sm) {
            RoundedRectangle(cornerRadius: 8)
                .fill(plugin.enabled ? Color.orange.opacity(0.18) : Color(nsColor: .quaternaryLabelColor))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(plugin.enabled ? Color.orange : .secondary)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .fontWeight(.medium)
                    .foregroundStyle(plugin.enabled ? .primary : .secondary)
                Text("\(itemCount) \(itemCount == 1 ? "item" : "items") · v\(plugin.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { plugin.enabled },
                set: { _ in model.togglePlugin(plugin) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(
                plugin.enabled
                    ? "Turn off the \(plugin.name) plugin so Claude stops loading what it ships"
                    : "Turn on the \(plugin.name) plugin so Claude loads what it ships"
            )
            .pointingHand()
        }
        .padding(.vertical, Metrics.xs)
        .contentShape(Rectangle())
        .help("\(plugin.name) — v\(plugin.version), \(itemCount) \(itemCount == 1 ? "item" : "items")")
        .pointingHand()
    }
}

// MARK: - Item row

struct ItemRow: View {
    let item: Item
    let model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.xs) {
            // A dot, not a full-height bar, and set on the title's own line: a mark that runs
            // past the description reads as a bracket around both lines instead of a status.
            Circle()
                .fill(originColor)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
                .help(originHint)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Metrics.xs) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let stateBadge {
                        Badge(text: stateBadge.text, tone: stateBadge.tone)
                    }
                    if case .plugin(let pluginName) = item.origin {
                        Text(pluginName)
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color(nsColor: .systemYellow).opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(Color(nsColor: .systemYellow))
                    }
                    if item.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(item.warning ?? "")
                    }
                    Spacer(minLength: 4)
                    if item.kind == .skill, item.origin == .personal, item.enabled {
                        AssistantDots(item: item, model: model)
                    }
                    Text("\(item.usage.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            item.usage.count == 0
                                ? Color.orange
                                : (colorScheme == .dark ? Color.primary.opacity(0.7) : Color.primary.opacity(0.85))
                        )
                        .help(item.usage.summary())
                }
                Text(item.description.isEmpty ? item.kind.label : item.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Metrics.xs)
        .opacity(item.enabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .help(rowHint)
        .pointingHand()
    }

    /// The row is truncated on both the name and, for skills and commands, the path — this is
    /// the only place either is guaranteed to be readable in full.
    private var rowHint: String {
        let path = (item.path ?? item.directory)?.path
        return path.map { "\(item.name) — \($0)" } ?? item.name
    }

    /// Origin used to be spelled out in a badge on every row. The bar says it instead — one
    /// glance down the list, rather than a word to read on each one. System colours only,
    /// even here: green for what's yours, blue for what the project brought, orange for what
    /// a plugin shipped, secondary once it's off.
    /// What the dot means, since a colour on its own is not self-explanatory.
    private var originHint: String {
        if !item.enabled { return "Disabled — not loaded by anything right now" }
        switch item.origin {
        case .personal: return "Your own, in ~/.claude"
        case .project(let name): return "Lives in the \(name) repository"
        case .plugin(let name): return "Comes from the \(name) plugin"
        }
    }

    private var originColor: Color {
        guard item.enabled else { return .secondary }
        switch item.origin {
        case .personal: return .green
        case .project: return .blue
        case .plugin: return .orange
        }
    }

    /// The kind icon: the same symbol the sidebar uses for this row's category, so a glance at
    /// the leading edge of a row tells kind apart the same way the sidebar column does.

    /// One system colour per kind, matching the sidebar's palette — off once the row is
    /// disabled, same as the origin bar.

    /// The two facts the bar's color cannot carry on its own: that this is parked, and that
    /// nobody has ever used it.
    private var stateBadge: (text: String, tone: Badge.Tone)? {
        if !item.enabled { return ("disabled", .muted) }
        if item.usage.neverUsed { return ("never used", .warning) }
        return nil
    }
}

struct Badge: View {
    enum Tone { case muted, warning }
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
        case .muted: return Color(nsColor: .quaternaryLabelColor)
        case .warning: return .orange.opacity(0.16)
        }
    }

    private var foreground: Color {
        switch tone {
        case .muted: return .secondary
        case .warning: return .orange
        }
    }
}

/// Which assistants load this skill, using each one's real app icon where there is an app.
/// Only the ones that have it are shown; the gaps live in the detail pane, where there is
/// room for names.
struct AssistantDots: View {
    let item: Item
    @Bindable var model: AppModel

    private var present: [Assistant] { model.visibleAssistants.filter { item.assistants.contains($0.id) } }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(present) { assistant in
                AssistantMark(assistant: assistant, present: true)
                    .help("\(assistant.label) loads this skill")
                    .pointingHand()
            }
        }
    }
}

/// The full picture for the selected skill: every assistant on the machine, named, with the
/// ones that are missing it offering to take it.
///
/// Collapsed by default behind a stock `DisclosureGroup`: with up to twelve assistants, the
/// full grid used to eat half the detail pane before a person had even looked at the file it
/// belongs to. The closed row still answers the one question that matters at a glance — which
/// assistants have it, and how many — and expanding it is one click away, remembered across
/// launches the same way any other disclosure state is.
struct AssistantPanel: View {
    let item: Item
    @Bindable var model: AppModel
    @AppStorage("assistantPanelExpanded") private var isExpanded = false

    private var present: [Assistant] { model.visibleAssistants.filter { item.assistants.contains($0.id) } }

    /// Three states, not two: has it, does not have it, or has nowhere to keep skills yet.
    private func status(_ assistant: Assistant, has: Bool) -> String {
        if has { return "loaded" }
        return assistant.hasSkillsFolder ? "add" : "no skills"
    }

    private func help(_ assistant: Assistant, has: Bool) -> String {
        if has { return "Click to stop \(assistant.label) from loading this skill" }
        if assistant.hasSkillsFolder { return "Click to add this skill to \(assistant.label)" }
        return "\(assistant.label) doesn't have a skills folder yet. Click to create \(assistant.skillsRoot.path) and add this skill."
    }

    /// "Used by Claude Code", "Used by Claude Code and Codex", and past three a count takes
    /// over so the row cannot grow without bound.
    private var loadedByLabel: String {
        let names = present.map(\.label)
        switch names.count {
        case 0: return "No assistant loads this yet"
        case 1: return "Used by \(names[0])"
        case 2: return "Used by \(names[0]) and \(names[1])"
        case 3: return "Used by \(names[0]), \(names[1]) and \(names[2])"
        default: return "Used by \(names.count) of \(model.visibleAssistants.count) assistants"
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 178), spacing: Metrics.xs)],
                alignment: .leading, spacing: Metrics.xs
            ) {
                ForEach(model.visibleAssistants) { assistant in
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
                            has ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(help(assistant, has: has))
                    .pointingHand()
                }
            }
            .padding(.top, Metrics.xs)
        } label: {
            HStack(spacing: Metrics.xs) {
                ForEach(present) { assistant in
                    AssistantMark(assistant: assistant, present: true)
                        .pointingHand()
                }
                // Names, not a fraction: "1 of 12" says how many and hides which, and which
                // is the only part a person is actually asking.
                Text(loadedByLabel)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .help("Show every assistant on this machine, and which of them load this skill")
            .pointingHand()
        }
    }
}
