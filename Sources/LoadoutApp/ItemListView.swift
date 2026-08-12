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

    /// The menus lead, spread edge to edge — scope on the left margin, order on the right,
    /// the assistant filter between them — then the search field on its own full-width line,
    /// and the chips after. Scope first because it narrows what everything below acts on.
    /// The scope picker used to live in the window toolbar, but it filters this list, and a
    /// control reads best next to what it changes.
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: Metrics.xs) {
            HStack(spacing: Metrics.sm) {
                ContextPicker(model: model)
                    .controlSize(.small)
                Spacer(minLength: Metrics.sm)
                assistantMenu
                Spacer(minLength: Metrics.sm)
                sortMenu
            }
            searchField
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
            }
        }
        // The same bordered pill as the scope picker: three menus on one line in three
        // different styles read as clutter, in one style they read as a toolbar.
        .menuStyle(.button)
        .buttonStyle(.bordered)
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
                }
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
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
                // Three different truths, three different sentences: a search with no hits,
                // a filter that excludes everything, and a source that is genuinely empty.
                // Telling someone to create a skill when a filter is hiding fifty-six of
                // them would be a lie.
                // Trimmed like the filter itself trims: a stray space in the field must not
                // switch the message to blaming a search that is matching everything.
                if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView(
                        "No results", systemImage: "magnifyingglass",
                        description: Text("Nothing matches \"\(model.query)\".")
                    )
                } else if model.filter != .all || model.assistantFilter != .any {
                    ContentUnavailableView(
                        "No matches", systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Nothing passes the active filters. Clear them to see everything again.")
                    )
                } else {
                    ContentUnavailableView(
                        "Nothing here", systemImage: "tray",
                        description: Text("This source is empty. Create a skill with ⌘N.")
                    )
                }
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

    private func chipView(_ chip: ItemFilter) -> some View {
        FilterChip(
            title: chip.shortTitle,
            hint: chip.hint,
            count: model.count(for: chip),
            isActive: model.filter == chip
        ) {
            model.filter = chip
        }
    }

    var body: some View {
        // One row, edge to edge, while it fits: the pills keep their natural width — a label
        // never breaks in two — and the leftover space becomes even gaps between them. When
        // the row genuinely doesn't fit (a project scope adds a seventh chip), it falls back
        // to wrapping instead of running off the pane.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(chips.enumerated()), id: \.element) { index, chip in
                    if index > 0 { Spacer(minLength: 4) }
                    chipView(chips[index])
                }
            }
            ChipFlow(spacing: 4, lineSpacing: 5) {
                ForEach(chips, id: \.self) { chip in
                    chipView(chip)
                }
            }
        }
        // Same horizontal inset as the list header above, so the chips' left edge lines up
        // with the search field instead of sitting on its own grid.
        .padding(.horizontal, Metrics.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Metrics.xs) {
                    // The name is what the eye is scanning for, so it gets the size and the
                    // weight; everything else on the line is context for it.
                    Text(item.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    // Beside the name, not stranded at the far edge: which assistants load a
                    // skill is a property of the skill, and reads as one next to it.
                    if item.kind == .skill, item.origin == .personal, item.enabled {
                        AssistantDots(item: item, model: model)
                    }
                    if let stateBadge {
                        Badge(text: stateBadge.text, tone: stateBadge.tone)
                    }
                    // Orange, not the old plugins-yellow: the chip names the item's origin,
                    // and orange is what "came from a plugin" looks like everywhere else —
                    // the dot on this same row says it in the same hue.
                    if case .plugin(let pluginName) = item.origin {
                        Text(pluginName)
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(Color.orange)
                    }
                    if item.warning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(item.warning ?? "")
                    }
                    Spacer(minLength: 6)
                    Text("\(item.usage.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            item.usage.count == 0
                                ? Color.orange
                                : (colorScheme == .dark ? Color.primary.opacity(0.7) : Color.primary.opacity(0.85))
                        )
                        .help(item.usage.summary())
                    // Turning a skill off is the action you take from the list, so it lives in
                    // the list — no trip through the detail pane to park something.
                    if item.kind == .skill, item.origin == .personal {
                        Toggle("", isOn: Binding(
                            get: { item.enabled },
                            set: { _ in model.toggle(item) }
                        ))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        // No green here, unlike the detail pane's single switch: twenty-one
                        // green switches down a column pull the eye to the controls when the
                        // job is reading names. The system tint keeps it quiet and still says
                        // on or off.
                        .help(item.enabled
                              ? "Move \(item.name) to skills-off so nothing loads it"
                              : "Put \(item.name) back in ~/.claude/skills")
                        .pointingHand()
                    }
                }
                // Quieter than the name by two steps, size and colour both: it is there to be
                // read once, not scanned.
                Text(item.description.isEmpty ? item.kind.label : item.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
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

    /// The dot wears the kind's own colour — the same hue as the bar tab the row lives under —
    /// and goes gray when the item is disabled. Origin stayed in the tooltip and the chips;
    /// as a second colour code on the same dot it fought the topic palette above.
    private var originColor: Color {
        item.enabled ? item.kind.tint : .secondary
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
        // Gathered into one pill rather than left loose: three or four bare icons in a row read
        // as clutter competing with the name, where a single enclosed group reads as one fact.
        if !present.isEmpty {
            HStack(spacing: 2) {
                ForEach(present) { assistant in
                    AssistantMark(assistant: assistant, present: true, size: 13)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
            .help(present.count == 1
                  ? "\(present[0].label) loads this skill"
                  : "Loaded by \(present.map(\.label).joined(separator: ", "))")
            .pointingHand()
        }
    }
}

/// The full picture for the selected skill: every assistant on the machine, named, with the
/// ones that are missing it offering to take it.
///
/// Always open, no disclosure and no title row: the grid itself already names every assistant
/// and marks the ones that load the skill, so a "Used by …" line above it only said the same
/// thing smaller. The adaptive grid keeps it to two or three rows at worst.
struct AssistantPanel: View {
    let item: Item
    @Bindable var model: AppModel

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

    var body: some View {
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
    }
}
