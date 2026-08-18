import SwiftUI
import LoadoutCore

/// The v2 sidebar: scope, sort and a filter funnel as popover buttons on one line, the search
/// on its own full-width line, accent tokens naming whatever is currently narrowing the list,
/// then the rows, then a status footer. The chips row of the old UI became the funnel — six
/// always-visible pills traded for one button that says how many filters are on.
struct SidebarView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFieldFocused: Bool

    /// The same stored key the rows and Settings read, so whichever one changes it, the other two
    /// are already showing the answer.
    @AppStorage("listDensity") private var density = "compact"
    private var compact: Bool { density == "compact" }

    // Popovers start closed in normal use; the environment hook lets a screenshot scenario
    // open one from the outside, since no synthetic clicks ever drive a live window here.
    @State private var scopeOpen = ProcessInfo.processInfo.environment["LOADOUT_OPEN"] == "scope"
    @State private var sortOpen = ProcessInfo.processInfo.environment["LOADOUT_OPEN"] == "sort"
    @State private var filtersOpen = ProcessInfo.processInfo.environment["LOADOUT_OPEN"] == "filters"
    @State private var projectQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            // Plugins are not items: search, sort, scope and the funnel all act on the item
            // list, so on the Plugins tab the header would be four controls with nothing to
            // do. The manager gets the full column instead.
            if model.selection == .plugins {
                PluginManagerView(model: model)
            } else {
                header
                Hairline()
                list
            }
            Hairline()
            footer
        }
        .background(V2.sidebar)
        .onChange(of: model.searchFocused) { _, wantsFocus in
            guard wantsFocus else { return }
            searchFieldFocused = true
            // Consume the request immediately: if it stays true, the next ⌘F is a
            // true→true non-change and onChange never fires again.
            DispatchQueue.main.async { model.searchFocused = false }
        }
        .onChange(of: searchFieldFocused) { _, focused in
            if !focused { model.searchFocused = false }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                scopeButton
                sortButton
                Spacer(minLength: 6)
                densityButton
                filterButton
            }
            searchField
            if !activeTokens.isEmpty {
                tokensRow
            }
            if model.showsEverything {
                // Said once, where the list is: nothing on this machine loads two projects at the
                // same time, so a merged list is for finding things, not a picture of what is on.
                Text("Yours and every project's, to search. No assistant loads more than one project at a time.")
                    .font(.system(size: 11))
                    .foregroundStyle(V2.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 9)
    }

    // MARK: Scope

    private var scopeButton: some View {
        Button {
            scopeOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.showsEverything
                    ? "square.stack.3d.up" : (model.context == nil ? "globe" : "folder"))
                    .font(.system(size: 11))
                Text(model.showsEverything ? "Everything" : (model.context?.name ?? "Global"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 118, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5))
                    .foregroundStyle(V2.textDim)
            }
        }
        .buttonStyle(V2PillButtonStyle(active: scopeOpen))
        .help("Switch which project's files Claude sees, or go back to Global")
        .pointingHand()
        .popover(isPresented: $scopeOpen, arrowEdge: .bottom) {
            scopePopover
        }
    }

    private var scopePopover: some View {
        VStack(spacing: 0) {
            // Its own little search: the projects list is long, the popover is not.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(V2.textDim)
                TextField("Filter \(model.projects.count) projects", text: $projectQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(V2.well, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    popoverGroupLabel("Scope")
                    popoverRow(
                        title: "Global", subtitle: nil,
                        checked: model.context == nil && !model.showsEverything,
                        hint: "Everything in ~/.claude, not bound to any project"
                    ) {
                        model.changeContext(to: nil)
                        scopeOpen = false
                    }
                    popoverRow(
                        title: "Everything", subtitle: "yours and every project's, to search",
                        checked: model.showsEverything,
                        hint: "One list of it all, each row saying where it lives. Not what an assistant loads — that is your own plus one project at a time."
                    ) {
                        model.showEverything()
                        scopeOpen = false
                    }
                    let matches = filteredProjects
                    if !matches.isEmpty {
                        popoverGroupLabel("Projects (\(model.projects.count))")
                        ForEach(matches) { project in
                            popoverRow(
                                title: project.name, subtitle: project.relativePath,
                                checked: model.context?.id == project.id,
                                hint: "Scope the list to what Claude sees inside \(project.relativePath)"
                            ) {
                                model.changeContext(to: project)
                                scopeOpen = false
                                projectQuery = ""
                            }
                        }
                    }
                }
                .padding(5)
            }
            .frame(maxHeight: 290)
        }
        .frame(width: 300)
        .background(V2.popover)
    }

    private var filteredProjects: [Project] {
        let needle = projectQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return model.projects }
        return model.projects.filter {
            $0.name.lowercased().contains(needle) || $0.relativePath.lowercased().contains(needle)
        }
    }

    // MARK: Sort

    private var sortButton: some View {
        Button {
            sortOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(model.order.label)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5))
                    .foregroundStyle(V2.textDim)
            }
        }
        .buttonStyle(V2PillButtonStyle(active: sortOpen))
        .help("Change the order the list is sorted in")
        .pointingHand()
        .popover(isPresented: $sortOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ItemSort.allCases, id: \.self) { order in
                    popoverRow(title: order.label, subtitle: nil, checked: model.order == order, hint: "") {
                        model.order = order
                        sortOpen = false
                    }
                }
            }
            .padding(5)
            .frame(width: 210)
            .background(V2.popover)
        }
    }

    // MARK: Filters

    /// One filter from each group can be on at a time — the same single-choice model the old
    /// chips had, but the choices now live behind the funnel with the counts beside them.
    /// Comfortable or compact, beside the funnel.
    ///
    /// It began life in Settings › Appearance, which was the wrong house: this is not a preference
    /// about how the app looks, it is a control over the list you are looking at right now, and it
    /// belongs where the eye already goes to change what the list shows. It is still in Settings as
    /// well — the same door in two places, like the reading size — but this is the one people find.
    ///
    /// Two segments rather than one toggling glyph. A single icon has to stand for both the state
    /// it is in and the state it would take you to, and it manages neither: the first version was a
    /// lone list glyph that nobody could read as "density". Showing both choices side by side, with
    /// the current one lit, is the switcher every Finder window has taught people already.
    private var densityButton: some View {
        HStack(spacing: 0) {
            densitySegment(
                "comfortable", symbol: "rectangle.grid.1x2",
                hint: "Comfortable: each item with its description"
            )
            densitySegment(
                "compact", symbol: "list.dash",
                hint: "Compact: names only, so more fits on screen"
            )
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(V2.button)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(V2.hairline, lineWidth: 0.5)
                }
        )
    }

    private func densitySegment(_ value: String, symbol: String, hint: String) -> some View {
        let on = density == value
        return Button {
            density = value
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(on ? Color.white : V2.textDim)
                .frame(width: 24, height: 20)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(on ? V2.accent : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(hint)
        .accessibilityLabel(hint)
        .pointingHand()
    }

    private var filterButton: some View {
        let count = activeFilterCount
        return Button {
            filtersOpen.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 12))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(V2PillButtonStyle(active: filtersOpen, filled: count > 0))
        .help("Narrow the list by source, state or assistant")
        .pointingHand()
        .popover(isPresented: $filtersOpen, arrowEdge: .bottom) {
            filtersPopover
        }
    }

    private var activeFilterCount: Int {
        (model.filter == .all ? 0 : 1) + (model.assistantFilter == .any ? 0 : 1)
    }

    private var filtersPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverGroupLabel("Source")
            filterOption(.all)
            filterOption(.mine)
            filterOption(.fromPlugins)
            popoverGroupLabel("State")
            filterOption(.neverUsed)
            filterOption(.disabled)
            if model.selection == .skills || model.selection == .commands || model.selection == .agents {
                filterOption(.overBudget)
            }
            if model.selection == .skills {
                popoverGroupLabel("Assistant")
                assistantOption(.any, label: "Any")
                assistantOption(.multiple, label: "In more than one")
                ForEach(model.visibleAssistants) { assistant in
                    assistantOption(.one(assistant.id), label: assistant.label)
                }
            }
            Hairline().padding(.vertical, 5)
            Button {
                model.filter = .all
                model.assistantFilter = .any
                filtersOpen = false
            } label: {
                Text("Clear filters")
                    .font(.system(size: 12.5))
                    .foregroundStyle(V2.textMid)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHand()
        }
        .padding(5)
        .frame(width: 286)
        .background(V2.popover)
    }

    private func filterOption(_ chip: ItemFilter) -> some View {
        popoverRow(
            title: chip.title, subtitle: nil, checked: model.filter == chip,
            hint: chip.hint, trailingCount: model.count(for: chip)
        ) {
            model.filter = chip
            filtersOpen = false
        }
    }

    private func assistantOption(_ filter: AssistantFilter, label: String) -> some View {
        popoverRow(title: label, subtitle: nil, checked: model.assistantFilter == filter, hint: "") {
            model.assistantFilter = filter
            filtersOpen = false
        }
    }

    // MARK: Popover pieces

    private func popoverGroupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10.5))
            .kerning(0.5)
            .foregroundStyle(V2.textFaint)
            .padding(.horizontal, 9)
            .padding(.top, 7)
            .padding(.bottom, 3)
    }

    private func popoverRow(
        title: String, subtitle: String?, checked: Bool, hint: String,
        trailingCount: Int? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(checked ? "✓" : " ")
                    .font(.system(size: 12))
                    .frame(width: 14, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    if let subtitle, subtitle != title {
                        Text(subtitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(checked ? Color.white.opacity(0.75) : V2.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                if let trailingCount {
                    Text("\(trailingCount)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(checked ? Color.white.opacity(0.75) : V2.textFaint)
                }
            }
            .foregroundStyle(checked ? Color.white : Color.white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(checked ? V2.accent : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(hint)
        .pointingHand()
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(V2.textDim)
            TextField(searchPlaceholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searchFieldFocused)
                .onExitCommand {
                    model.query = ""
                    searchFieldFocused = false
                }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(V2.well, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .help("Filter the list as you type (⌘F)")
    }

    private var searchPlaceholder: String {
        let count = model.visibleItems.count
        return "Search \(count) \(model.selection.searchNoun(plural: count != 1))"
    }

    // MARK: Tokens

    private struct FilterToken: Identifiable {
        let id: String
        let label: String
        let clear: () -> Void
    }

    /// Every narrowing gets an accent token the design's way: visible, named, one click to undo.
    private var activeTokens: [FilterToken] {
        var tokens: [FilterToken] = []
        if let project = model.context {
            tokens.append(FilterToken(id: "scope", label: project.name) { model.changeContext(to: nil) })
        }
        if model.showsEverything {
            tokens.append(FilterToken(id: "scope", label: "Everything") { model.changeContext(to: nil) })
        }
        if model.filter != .all {
            tokens.append(FilterToken(id: "filter", label: model.filter.title) { model.filter = .all })
        }
        switch model.assistantFilter {
        case .any: break
        case .multiple:
            tokens.append(FilterToken(id: "assistant", label: "In 2+ assistants") { model.assistantFilter = .any })
        case .one(let id):
            let label = model.visibleAssistants.first { $0.id == id }?.label ?? id
            tokens.append(FilterToken(id: "assistant", label: label) { model.assistantFilter = .any })
        }
        return tokens
    }

    private var tokensRow: some View {
        // Wraps if someone stacks a long project name on an assistant filter — tokens are
        // capsules, and a capsule cut in half reads as a rendering bug.
        ChipFlow(spacing: 5, lineSpacing: 5) {
            ForEach(activeTokens) { token in
                Button(action: token.clear) {
                    HStack(spacing: 5) {
                        Text(token.label)
                            .lineLimit(1)
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.65))
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(V2.link)
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
                    .frame(height: 20)
                    .background(V2.accent.opacity(0.24), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(V2.accent.opacity(0.55), lineWidth: 0.5))
                    .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Remove this filter")
                .pointingHand()
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.visibleItems) { item in
                        SidebarRow(item: item, model: model)
                            .id(item.id)
                    }
                }
                .padding(6)
            }
            // The custom rows don't get `List`'s free arrow keys, so the scroll area takes
            // focus itself and moves the selection — click the list once, then ↑↓ walk it.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                let items = model.visibleItems
                guard !items.isEmpty else { return }
                let current = items.firstIndex { $0.id == model.selectedID }
                let next: Int
                switch direction {
                case .down: next = min(items.count - 1, (current ?? -1) + 1)
                case .up: next = max(0, (current ?? items.count) - 1)
                default: return
                }
                model.select(items[next].id)
                proxy.scrollTo(items[next].id, anchor: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.visibleItems.isEmpty {
            // Three different truths, three different sentences: a search with no hits, a
            // filter that excludes everything, and a source that is genuinely empty.
            if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView(
                    "No results", systemImage: "magnifyingglass",
                    description: Text("Nothing matches \"\(model.query)\".")
                )
            } else if activeFilterCount > 0 {
                ContentUnavailableView(
                    "No matches", systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Nothing passes the active filters. Clear them to see everything again.")
                )
            } else if let project = model.context {
                // A scoped, honestly empty project: say whose emptiness this is, instead of
                // padding the list with the global inventory the way the old scope did.
                ContentUnavailableView(
                    "Nothing in \(project.name)", systemImage: "folder",
                    description: Text("This project has no \(model.selection.searchNoun(plural: true)) of its own. Switch the scope back to Global to see everything.")
                )
            } else {
                ContentUnavailableView(
                    "Nothing here", systemImage: "tray",
                    description: Text(
                        model.selection == .skills
                            ? "This source is empty. Create a skill with ⌘N."
                            : "No \(model.selection.searchNoun(plural: true)) found on this machine."
                    )
                )
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 5) {
            // A switch rather than a door: the same button that opens Settings closes it, so
            // there is no second control to find and nothing to learn about getting out.
            Button {
                model.showsSettings.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10.5))
                    Text(model.showsSettings ? "Done" : "Settings")
                }
                .foregroundStyle(model.showsSettings ? V2.link : Color.primary)
            }
            .buttonStyle(.plain)
            .help(
                model.showsSettings
                    ? "Back to the list (⌘, or Esc)"
                    : "Projects, appearance, usage indexing, assistants and backups (⌘,)"
            )
            .pointingHand()

            Spacer()

            if let progress = model.indexProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text("Indexing usage…")
            } else if let status = model.statusMessage {
                Image(systemName: "checkmark.circle")
                Text(status)
            } else {
                Text(footerCount)
            }
            if model.isDirty {
                Text("unsaved")
                    .foregroundStyle(V2.amber)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(V2.textDim)
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(V2.footer)
    }

    private var footerCount: String {
        if model.selection == .plugins {
            return "\(model.plugins.count) \(model.plugins.count == 1 ? "plugin" : "plugins")"
        }
        let visible = model.visibleItems.count
        let total = model.count(for: model.selection)
        return visible == total
            ? "\(total) \(model.selection.searchNoun(plural: total != 1))"
            : "\(visible) of \(total) \(model.selection.searchNoun(plural: total != 1))"
    }
}

// MARK: - Row

/// One item the design's way: name, the assistants that load it as small marks, the use count,
/// a mini switch, and a two-line description. Selection paints the whole row in the accent.
struct SidebarRow: View {
    let item: Item
    @Bindable var model: AppModel

    private var isSelected: Bool { model.selectedID == item.id }

    /// The list without descriptions, for somebody who knows their own skills by name.
    @AppStorage("listDensity") private var density = "compact"
    private var compact: Bool { density == "compact" }

    var body: some View {
        Button {
            model.select(item.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(item.name)
                        .font(.system(size: 15, weight: .medium))
                        .help(originHint)
                        .foregroundStyle(
                            isSelected ? Color.white
                                : (item.enabled && !model.pluginIsOff(for: item) ? V2.text : V2.textDim)
                        )
                        .lineLimit(1)
                    if item.kind == .skill || item.kind == .command {
                        HStack(spacing: 3) {
                            ForEach(marks, id: \.id) { assistant in
                                AssistantMark(assistant: assistant, present: true, size: 14)
                            }
                        }
                    }
                    if item.budget.isOverBudget {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : V2.amber)
                            .help(item.budget.breaches.joined(separator: "\n"))
                    }
                    if case .plugin(let plugin) = item.origin {
                        PluginTag(name: plugin, muted: isSelected)
                    } else if let tag = originTag {
                        PluginTag(name: tag, muted: isSelected, quiet: true)
                            .help(originTagHint)
                    }
                    Spacer(minLength: 6)
                    Text("\(item.usage.count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(isSelected ? 0.75 : 0.35))
                        .help(usageHint)
                    if item.kind != .plugin {
                        MiniSwitch(on: item.enabled) { model.toggle(item) }
                            .help(switchHint)
                            .spotlight(Spotlight.toggle(item.id))
                    }
                }
                // Deliberately quieter than the name, and by more than one step. The row is scanned
                // by name — the description is there to settle "is this the one?" once your eye has
                // already stopped, and at the old size and brightness it competed with the thing
                // you were actually reading down the column.
                //
                // Gone entirely in the compact list. That is the whole point of compact: at 83
                // skills the descriptions are what makes the column a wall, and somebody who knows
                // their own skills by name is only paying to scroll.
                if !compact {
                    Text(item.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(isSelected ? 0.72 : 0.34))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .padding(.trailing, 38)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, compact ? 5 : 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? V2.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        // Deliberately not `.help` on the whole row. A tooltip on the button covers everything
        // inside it, so hovering the use count answered "Your own, in ~/.claude" — the row's own
        // answer to a question nobody asked there. Each thing now explains itself: the name says
        // where it comes from, the number says what it counts, the switch says what it will do.
        .pointingHand()
        .spotlight(Spotlight.row(item.id))
        .contextMenu {
            if item.kind != .plugin {
                Button(item.enabled ? "Disable" : "Enable") { model.toggle(item) }
            }
            // Only from a repository outwards. The other direction hands a file to a team, which
            // is not a thing to do from a context menu.
            if case .project = item.origin, item.kind != .mcp {
                // Gone once your copy exists, like the button in the detail pane: a menu that offers
                // the same copy twice is a menu that lies the second time.
                if !model.hasGlobalCopy(of: item) {
                    Button("Make global") { model.makeGlobal(item) }
                }
            }
            Button("Show in Finder") {
                model.select(item.id)
                model.revealInFinder()
            }
            if item.isEditable {
                Button("Move to Trash", role: .destructive) {
                    model.select(item.id)
                    model.isConfirmingDelete = true
                }
            }
            // Yours to remove; the ones a repository ships are the team's, and have no Remove.
            if model.canRemove(item) {
                Button("Remove…", role: .destructive) {
                    model.select(item.id)
                    model.isConfirmingDelete = true
                }
            }
        }
    }

    private var marks: [Assistant] {
        model.visibleAssistants.filter { item.assistants.contains($0.id) }
    }

    /// Where the row comes from, when the scope does not already answer that.
    ///
    /// In the everything list nothing is implied, so every row says it. Inside a project every row
    /// is that project's, so a tag would be one word repeated down the column. Global is the case
    /// this exists for: it is your own things — except MCP servers, which `~/.claude.json` also
    /// files under project directories. Two servers called `notion`, from two different
    /// repositories, were two rows with the same name and nothing to tell them apart.
    private var originTag: String? {
        if model.showsEverything {
            return item.origin == .personal ? "global" : item.origin.label
        }
        if model.context == nil, case .project(let name) = item.origin { return name }
        return nil
    }

    /// The folder's name is not unique — two checkouts can both be called `app` — so the tooltip
    /// gives the path that is.
    private var originTagHint: String {
        guard let directory = item.projectDirectory else {
            return "Where this comes from"
        }
        return "Declared under \(directory)"
    }

    /// Says the window the person actually chose in Settings › Usage. Hardcoding 90 days told
    /// somebody on a 30-day window the wrong thing about their own numbers.
    private var usageHint: String {
        item.usage.count == 0
            ? "Never used in \(model.usageWindowLabel)"
            : "\(item.usage.count) uses in \(model.usageWindowLabel)"
    }

    private var originHint: String {
        if !item.enabled { return "Disabled — not loaded by anything right now" }
        switch item.origin {
        case .personal: return "Your own, in ~/.claude"
        case .project(let name): return "Lives in the \(name) repository"
        case .plugin(let name): return "Comes from the \(name) plugin"
        }
    }

    /// The switch means the same thing everywhere — out of service — but where the skill lives
    /// changes what that costs, and the tooltip is where that gets said.
    private var switchHint: String {
        switch item.origin {
        case .personal:
            return item.enabled
                ? "Disable — every assistant stops loading this skill"
                : "Enable — choose which assistants load it again"
        case .project(let name):
            return item.enabled
                ? "Disable — moves it aside inside the \(name) repository"
                : "Enable — puts it back in the \(name) repository"
        case .plugin(let plugin):
            return item.enabled
                ? "Disable just this skill, leaving the rest of the \(plugin) plugin alone"
                : "Enable this skill again"
        }
    }
}

/// Where a skill came from, said on the row itself. A plugin's own colour would be a code to
/// learn; its name is already the answer, and dimming is spoken for — it means disabled.
struct PluginTag: View {
    let name: String
    var muted: Bool = false
    /// Where the row lives rather than what shipped it — `global`, or a repository's name. The
    /// same shape in the neutral grey, so it says its piece without competing with a plugin's tag,
    /// and without the `-plugin` suffix, which would be a lie about it.
    var quiet: Bool = false

    var body: some View {
        // "vercel-plugin", not "vercel": the name alone reads like a namespace, and the row has
        // to say what kind of thing this came from without a colour code to learn.
        Text(quiet ? name : "\(name)-plugin")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(muted ? Color.white.opacity(0.85)
                             : (quiet ? V2.textMid : V2.accent))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                (muted ? Color.white.opacity(0.18)
                 : (quiet ? Color.white.opacity(0.07) : V2.accent.opacity(0.16))),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .help(quiet
                  ? (name == "global" ? "Yours, in ~/.claude — active in every project"
                     : "Lives in the \(name) repository, and only works there")
                  : "Comes from the \(name) plugin")
    }
}

// MARK: - Controls

/// The design's switch, drawn by hand because the native `Toggle` only comes in one size:
/// 30×18 on every list row, 40×24 as the detail header's single big control. The healthy
/// hue when on, the shared grey track when off.
struct MiniSwitch: View {
    let on: Bool
    var width: CGFloat = 30
    var height: CGFloat = 18
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(on ? V2.ok : V2.offTrack)
                .frame(width: width, height: height)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: height - 4, height: height - 4)
                        .shadow(color: Color.black.opacity(0.45), radius: 1.5, y: 1)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.16), value: on)
        }
        .buttonStyle(.plain)
        .pointingHand()
    }
}

/// The header buttons' shared chrome: a small raised pill, brighter while its popover is up,
/// filled with the accent when it is announcing active filters.
struct V2PillButtonStyle: ButtonStyle {
    var active = false
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundStyle(filled ? Color.white : Color.white.opacity(0.88))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                filled ? V2.accent : (active || configuration.isPressed ? V2.buttonHover : V2.button),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }
}
