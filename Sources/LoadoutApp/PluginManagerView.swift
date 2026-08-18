import SwiftUI
import LoadoutCore

/// One row per installed plugin: name, version and item count are all a person needs to
/// decide whether to flip it. Restyled onto the v2 sidebar surface; the switch is the same
/// hand-drawn one the item rows use.
struct PluginManagerView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(model.plugins) { plugin in
                    PluginManagerRow(model: model, plugin: plugin)
                }
            }
            .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var isSelected: Bool { model.selectedPluginID == plugin.id }

    /// The badge, in the three states it actually has: on, off, and on-a-selected-row. The third
    /// is not a shade of the first — it sits on a different colour and has to be told so.
    private var tileFill: Color {
        if isSelected { return Color.white.opacity(0.22) }
        return plugin.enabled ? V2.accent.opacity(0.2) : V2.offTile
    }

    private var glyphColor: Color {
        if isSelected { return Color.white }
        return plugin.enabled ? V2.accent : V2.offGlyph
    }

    /// In a project scope the inventory holds only the project's items, so a per-plugin count would
    /// read a false 0 — plugins are global installs, and the row says so instead. Unless the
    /// repository decided about this one, which is the more useful thing to know there.
    private var subtitle: String {
        if let repositoryChoice = plugin.repositoryChoice, let name = model.context?.name {
            return "v\(plugin.version) · \(repositoryChoice ? "on" : "off") in \(name)"
        }
        return model.context == nil
            ? "\(itemCount) \(itemCount == 1 ? "item" : "items") · v\(plugin.version)"
            : "v\(plugin.version) · global"
    }

    /// Why the switch is not yours to flip here, or nil when it is.
    private func repositoryVerdict(_ plugin: PluginInfo) -> String? {
        guard let choice = plugin.repositoryChoice, let name = model.context?.name else { return nil }
        return """
        \(name) settles this one in its own settings, which Claude reads after yours, so it is \
        \(choice ? "on" : "off") while you work there whatever you choose
        """
    }

    var body: some View {
        row
            .background(isSelected ? V2.accent : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            // The row is a button around everything except the switch, which keeps its own tap:
            // selecting a plugin to look at it and flipping it are different intentions.
            .onTapGesture { model.selectedPluginID = plugin.id }
            .pointingHand()
    }

    private var row: some View {
        HStack(spacing: 10) {
            // On a selected row the accent is the *background*, so an accent-tinted tile with an
            // accent glyph in it vanished entirely — the row lost its icon the moment you clicked
            // it. Selected rows wear white instead, which is what the name beside them already does.
            RoundedRectangle(cornerRadius: 8)
                .fill(tileFill)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 14))
                        .foregroundStyle(glyphColor)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(plugin.enabled ? V2.text : V2.textDim)
                // In a project scope the inventory holds only the project's items, so the
                // per-plugin count would read a false 0 — plugins are global installs, and
                // the row says so instead.
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(V2.textDim)
            }
            Spacer(minLength: 6)
            MiniSwitch(on: plugin.enabled) { model.togglePlugin(plugin) }
                .disabled(plugin.repositoryChoice != nil)
                .help(repositoryVerdict(plugin) ?? (
                    plugin.enabled
                        ? "Turn off the \(plugin.name) plugin so Claude stops loading what it ships"
                        : "Turn on the \(plugin.name) plugin so Claude loads what it ships"
                ))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(plugin.name) — v\(plugin.version), \(itemCount) \(itemCount == 1 ? "item" : "items")")
    }
}

/// What a plugin brought with it, and which of it is switched on (AC3.17).
///
/// The plugin's own switch decides whether it is in the house at all; this is where a plugin gets
/// trimmed — a 38-item plugin you wanted three things from is the ordinary case, not the odd one.
struct PluginDetailView: View {
    @Bindable var model: AppModel
    let plugin: PluginInfo

    private var items: [Item] { model.itemsOfPlugin(plugin) }
    /// Skills and commands both have a switch of their own now, so they belong in the same list —
    /// splitting them left a plugin command switchable in one place and not in the other.
    private var switchable: [Item] { items.filter { $0.kind == .skill || $0.kind == .command } }
    private var rest: [Item] { items.filter { $0.kind != .skill && $0.kind != .command } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !plugin.enabled {
                    // The second sentence promises switches "below", which only exist when this
                    // plugin has switchable items in the list on screen. In a project scope the list
                    // holds only that repository's own things, so there was nothing below the
                    // sentence pointing at it.
                    Text(switchable.isEmpty
                        ? "The whole plugin is off, so nothing it ships is loaded."
                        : "The whole plugin is off, so nothing here is loaded. The switches below are each item's own choice, kept for when you turn the plugin back on.")
                        .font(.system(size: 12))
                        .foregroundStyle(V2.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !switchable.isEmpty {
                    section("Skills and commands", items: switchable, switchable: true)
                }
                whereItLives
                if !rest.isEmpty {
                    // Subagents have no per-item switch inside a plugin's detail — the Agents tab
                    // is where they are switched — so they are listed without one. MCP servers are
                    // not named here: no plugin on this machine declares any, and promising a list
                    // the scanner does not read was a promise the screen could not keep.
                    section("Also ships", items: rest, switchable: false)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(V2.window)
    }

    /// The repository's word on this plugin, when it has one. Nil means the choice is yours.
    private var repositorySettles: String? {
        guard let choice = plugin.repositoryChoice, let name = model.context?.name else { return nil }
        return """
        \(name) keeps this plugin \(choice ? "on" : "off") in its own settings, which Claude reads \
        after yours. Your switch cannot change it while you are working there.
        """
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(plugin.name)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(V2.text)
                MiniSwitch(on: plugin.enabled, width: 40, height: 24) { model.togglePlugin(plugin) }
                    .disabled(plugin.repositoryChoice != nil)
                    .help(repositorySettles ?? (
                        plugin.enabled ? "Turn the whole plugin off" : "Turn the whole plugin on"
                    ))
            }
            Text("v\(plugin.version)\(plugin.marketplace.isEmpty ? "" : " · from \(plugin.marketplace)")")
                .font(.system(size: 12))
                .foregroundStyle(V2.textDim)
            // Said out loud rather than left to a tooltip: a switch that will not move needs a
            // reason on screen, or the app looks broken.
            if let repositorySettles {
                Text(repositorySettles)
                    .font(.system(size: 12))
                    .foregroundStyle(V2.textMid)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Where the plugin actually is, what it brought, and the two things you can do to the whole of
    /// it — open it, or take it out.
    ///
    /// The page used to be a switch, a version and a list of names: nothing about where those files
    /// live, nothing about what installed them, and no way to remove one — so "how do I get rid of
    /// this?" had no answer on the screen that was about it.
    private var whereItLives: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("THE PLUGIN ITSELF")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(V2.textDim)
            VStack(spacing: 1) {
                factRow("From", plugin.marketplace.isEmpty ? "an unnamed marketplace" : plugin.marketplace)
                factRow("Version", plugin.version.isEmpty ? "not recorded" : "v\(plugin.version)")
                factRow("Ships", model.pluginContents(plugin))
                factRow("Location", model.readablePath(of: plugin), mono: true) {
                    Button("Reveal") { model.revealPlugin(plugin) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(V2.link)
                        .help("Show \(plugin.name)'s own folder in the Finder")
                        .pointingHand()
                }
            }
            HStack(spacing: 10) {
                Button {
                    model.removePlugin(plugin)
                } label: {
                    Text("Remove plugin…")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(V2.issue)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(V2.issue.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(V2.issue.opacity(0.35), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Uninstall \(plugin.name): its folder to the Trash and its entry out of Claude Code's register")
                .pointingHand()
                // Said beside the button, not only inside the dialog it opens: switching off and
                // removing are two different things, and somebody who only wants the plugin quiet
                // should be able to tell before pressing anything.
                Text("Switching it off above keeps the files. This takes them away.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(V2.textFaint)
            }
            .padding(.top, 2)
        }
    }

    private func factRow<Trailing: View>(
        _ label: String, _ value: String, mono: Bool = false,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
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
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(V2.card, in: RoundedRectangle(cornerRadius: 8))
    }

    private func section(_ title: String, items: [Item], switchable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(V2.textDim)
            VStack(spacing: 1) {
                ForEach(items) { item in
                    itemRow(item, switchable: switchable)
                }
            }
        }
    }

    /// A row with a switch says what switching it off costs — the plugin keeps working, and the
    /// choice is not undone the next time the plugin updates. A row without one has to say why
    /// there is nothing to flip here, or it reads as a switch that failed to draw.
    @ViewBuilder
    private func itemRow(_ item: Item, switchable: Bool) -> some View {
        let row = HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(item.enabled ? V2.text : V2.textDim)
                Text(item.description)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.42))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 6)
            if switchable {
                MiniSwitch(on: item.enabled) { model.toggle(item) }
                    .help(
                        item.enabled
                            ? "Stop Claude loading \(item.name), leaving the rest of the plugin on. "
                                + "It stays off when the plugin updates."
                            : "Let Claude load \(item.name) again. A plugin update leaves it on from now on."
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(V2.card, in: RoundedRectangle(cornerRadius: 7))

        if !switchable, item.kind == .agent {
            row.help("Subagents are switched on the Agents tab, not here")
        } else {
            row
        }
    }
}
