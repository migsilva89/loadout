import Foundation

public enum ItemSort: String, CaseIterable, Sendable {
    case name
    case usage
    case frontmatter

    public var label: String {
        switch self {
        case .name: return "Name"
        case .usage: return "Most used"
        case .frontmatter: return "Frontmatter"
        }
    }
}

/// Which row of the sidebar is picked. The sidebar has one axis now — what kind of thing this
/// is — instead of the old mix of origin, state, and type all stacked in one column.
///
/// `.plugins` is not a kind of item: picking it swaps the list column for the plugin manager
/// instead of slicing the inventory. It still lives here, rather than as a separate `Bool`,
/// because the sidebar's `List` needs one selection value to drive both.
public enum Selection: String, Equatable, Hashable, Sendable, CaseIterable {
    case skills
    case commands
    case agents
    case mcp
    case plugins

    public var title: String {
        switch self {
        case .skills: return "Skills"
        case .commands: return "Commands"
        case .agents: return "Agents"
        case .mcp: return "MCP"
        case .plugins: return "Plugins"
        }
    }

    /// The item kind this row slices by. `nil` for `.plugins`, which has no items of its own —
    /// the plugin manager reads the plugin list directly instead.
    public var kind: ItemKind? {
        switch self {
        case .skills: return .skill
        case .commands: return .command
        case .agents: return .agent
        case .mcp: return .mcp
        case .plugins: return nil
        }
    }
}

/// Origin and state used to be sidebar rows of their own. They are chips above the list now,
/// and they combine with whichever `Selection` the sidebar has picked — a single choice, not
/// a multi-select, because "Mine and never used" is a rare enough need not to be worth the
/// complexity of combining chips.
public enum ItemFilter: String, Equatable, Hashable, Sendable, CaseIterable {
    case all
    case enabled
    case mine
    case fromPlugins
    case neverUsed
    case disabled
    case overBudget
    case frontmatter

    /// "Personal", not "Mine": read next to a count on a chip, "Mine 12" reads like a
    /// possessive fragment, where "Personal 12" reads as a label.
    public var title: String {
        switch self {
        case .all: return "All"
        case .enabled: return "On"
        case .mine: return "Personal"
        case .fromPlugins: return "From plugins"
        case .neverUsed: return "Never used"
        case .disabled: return "Off"
        case .overBudget: return "Over budget"
        case .frontmatter: return "Frontmatter"
        }
    }


    /// The full sentence a short chip label can't carry on its own, shown on hover.
    public var hint: String {
        switch self {
        case .all: return "Everything in this list"
        case .enabled: return "Currently turned on and available to the assistant"
        case .mine: return "Created and kept locally, not from a project or plugin"
        case .fromPlugins: return "Comes from an installed plugin"
        case .neverUsed: return "Never used in the last 90 days"
        case .disabled: return "Currently turned off"
        case .overBudget:
            return "Breaks a documented limit: body over \(Budget.maxBodyLines) lines or \(Budget.maxBodyWords) words, or a name or description over its maximum"
        case .frontmatter:
            return "Has the selected frontmatter key"
        }
    }
}

/// The assistant menu next to sort: independent of the origin/state chip above the list, and
/// combined with it rather than replacing it — "Personal" plus "Codex" means personal skills
/// Codex loads, not one or the other. Skills carry the assistants that load them and MCP servers
/// carry their one owner, so this is shown on those two tabs and is inert on the rest.
public enum AssistantFilter: Hashable, Sendable {
    case any
    /// What the old `.shared` chip did: skills more than one assistant loads.
    case multiple
    /// One specific assistant, by id.
    case one(String)
}

public enum Filtering {
    /// Case- and accent-insensitive, so "seo" finds "SEO" and "traducao" finds "tradução" (AC2.4).
    public static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_PT"))
    }

    public static func matches(_ item: Item, query: String) -> Bool {
        let needle = normalize(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return true }
        return normalize(item.name).contains(needle)
            || normalize(item.description).contains(needle)
    }

    /// The sidebar-row slice: everything of that kind, from every origin. `.plugins` has no
    /// items of its own, so it slices to nothing — the plugin manager doesn't go through here.
    public static func slice(_ items: [Item], for selection: Selection) -> [Item] {
        guard let kind = selection.kind else { return [] }
        return items.filter { $0.kind == kind }
    }

    /// The chip, applied on top of the sidebar slice.
    public static func filter(
        _ items: [Item], by filter: ItemFilter, frontmatterKey: String? = nil,
        disabledPluginIDs: Set<String> = []
    ) -> [Item] {
        switch filter {
        case .all:
            return items
        case .enabled:
            return items.filter { isEffectivelyEnabled($0, disabledPluginIDs: disabledPluginIDs) }
        case .mine:
            return items.filter { $0.origin == .personal }
        case .fromPlugins:
            return items.filter {
                if case .plugin = $0.origin { return true }
                return false
            }
        case .neverUsed:
            return items.filter { $0.usage.neverUsed && usageIsObservable($0) }
        case .disabled:
            return items.filter { !isEffectivelyEnabled($0, disabledPluginIDs: disabledPluginIDs) }
        case .overBudget:
            return items.filter { $0.budget.isOverBudget }
        case .frontmatter:
            guard let frontmatterKey else { return items }
            return items.filter { $0.frontmatter[frontmatterKey] != nil }
        }
    }

    /// The owners whose history proves an MCP call: Claude's transcripts name the server in the
    /// tool (`mcp__server__tool`). Codex and Antigravity don't yet, so their servers are never
    /// called unused — a zero nobody can see is not a zero.
    static let assistantsWithMCPUsage: Set<String> = ["claude"]

    public static func usageIsObservable(_ item: Item) -> Bool {
        guard item.kind == .mcp else { return true }
        return item.assistants.isEmpty || !item.assistants.isDisjoint(with: assistantsWithMCPUsage)
    }

    public static func isEffectivelyEnabled(
        _ item: Item, disabledPluginIDs: Set<String> = []
    ) -> Bool {
        item.enabled && !(item.pluginID.map { disabledPluginIDs.contains($0) } ?? false)
    }

    /// The assistant menu, applied independently of the chip.
    public static func filter(_ items: [Item], by assistant: AssistantFilter) -> [Item] {
        switch assistant {
        case .any:
            return items
        case .multiple:
            return items.filter { $0.assistants.count > 1 }
        case .one(let id):
            return items.filter { $0.assistants.contains(id) }
        }
    }

    public static func sort(
        _ items: [Item], by order: ItemSort, frontmatterKey: String? = nil
    ) -> [Item] {
        switch order {
        case .name:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .usage:
            return items.sorted {
                $0.usage.count == $1.usage.count
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.usage.count > $1.usage.count
            }
        case .frontmatter:
            guard let frontmatterKey else { return sort(items, by: .name) }
            return items.sorted {
                let left = $0.frontmatter[frontmatterKey]
                let right = $1.frontmatter[frontmatterKey]
                switch (left, right) {
                case let (a?, b?) where a != b:
                    return a.localizedStandardCompare(b) == .orderedAscending
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
        }
    }

    public static func apply(
        _ items: [Item], selection: Selection, filter chip: ItemFilter,
        assistant: AssistantFilter = .any, query: String, order: ItemSort,
        frontmatterFilterKey: String? = nil, frontmatterSortKey: String? = nil,
        disabledPluginIDs: Set<String> = []
    ) -> [Item] {
        sort(
            filter(
                filter(
                    slice(items, for: selection), by: chip,
                    frontmatterKey: frontmatterFilterKey,
                    disabledPluginIDs: disabledPluginIDs
                ),
                by: assistant
            )
            .filter { matches($0, query: query) },
            by: order, frontmatterKey: frontmatterSortKey
        )
    }
}

public extension Usage {
    /// "2 days ago", said the way a person would — what the detail cards and the header
    /// subtitle print for dates.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 3600 { return "minutes ago" }
        if seconds < 86_400 { return "today" }
        let days = Int(seconds / 86_400)
        if days == 1 { return "yesterday" }
        if days < 30 { return "\(days) days ago" }
        let months = days / 30
        return months == 1 ? "1 month ago" : "\(months) months ago"
    }
}
