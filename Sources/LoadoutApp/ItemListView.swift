import SwiftUI
import LoadoutCore

struct ItemListView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
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
    }

    /// The sort control belongs to the list, not to the window: it changes this column and
    /// nothing else.
    private var listHeader: some View {
        HStack(spacing: 8) {
            Text("\(model.visibleItems.count) \(model.visibleItems.count == 1 ? "item" : "items")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Picker("Sort", selection: $model.order) {
                ForEach(ItemSort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
        .padding(.bottom, 4)
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
    }
}

// MARK: - Filter chips

/// Origin and state, as a single-selection row of chips above the list. They combine with
/// whichever sidebar row is picked — "Skills" + "Never used" reads as one sentence.
struct FilterChipsView: View {
    @Bindable var model: AppModel

    private var chips: [ItemFilter] {
        var base: [ItemFilter] = [.all, .mine]
        if model.context != nil { base.append(.thisProject) }
        base.append(contentsOf: [.shared, .neverUsed, .disabled])
        return base
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { chip in
                    FilterChip(
                        title: chip.title,
                        count: model.count(for: chip),
                        isActive: model.filter == chip
                    ) {
                        model.filter = chip
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 7)
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isActive ? .white.opacity(0.8) : .secondary)
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isActive ? Color.accentColor : Color.secondary.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(isActive ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
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
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.loadoutAmber.opacity(plugin.enabled ? 0.18 : 0.08))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(plugin.enabled ? Color.loadoutAmber : .secondary)
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
            .help(plugin.enabled ? "Disable the \(plugin.name) plugin" : "Enable the \(plugin.name) plugin")
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Item row

struct ItemRow: View {
    let item: Item
    let model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(originColor)
                .frame(width: 3)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if let stateBadge {
                        Badge(text: stateBadge.text, tone: stateBadge.tone)
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
                        .foregroundStyle(.secondary)
                        .help(item.usage.summary())
                }
                Text(item.description.isEmpty ? item.kind.label : item.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
        .opacity(item.enabled ? 1 : 0.5)
    }

    /// Origin used to be spelled out in a badge on every row. The bar says it instead — one
    /// glance down the list, rather than a word to read on each one.
    private var originColor: Color {
        guard item.enabled else { return .gray }
        switch item.origin {
        case .personal: return .green
        case .project: return .blue
        case .plugin: return .loadoutAmber
        }
    }

    /// The two facts the bar's color cannot carry on its own: that this is parked, and that
    /// nobody has ever used it.
    private var stateBadge: (text: String, tone: Badge.Tone)? {
        if !item.enabled { return ("disabled", .muted) }
        if item.usage.neverUsed { return ("never used", .warning) }
        return nil
    }
}

struct Badge: View {
    enum Tone { case own, accent, muted, warning }
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
        case .own: return .green.opacity(0.16)
        case .accent: return .accentColor.opacity(0.16)
        case .muted: return .secondary.opacity(0.14)
        case .warning: return .orange.opacity(0.16)
        }
    }

    private var foreground: Color {
        switch tone {
        case .own: return .green
        case .accent: return .accentColor
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

    private var present: [Assistant] { model.assistants.filter { item.assistants.contains($0.id) } }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(present) { assistant in
                AssistantMark(assistant: assistant, present: true)
                    .help("\(assistant.label) loads this skill")
            }
        }
    }
}

/// The full picture for the selected skill: every assistant on the machine, named, with the
/// ones that are missing it offering to take it.
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
        VStack(alignment: .leading, spacing: 7) {
            Text("Assistants")
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 178), spacing: 8)],
                alignment: .leading, spacing: 6
            ) {
                ForEach(model.assistants) { assistant in
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
                            Color.secondary.opacity(has ? 0.10 : 0.04),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                    .buttonStyle(.plain)
                    .help(help(assistant, has: has))
                }
            }
        }
    }
}
