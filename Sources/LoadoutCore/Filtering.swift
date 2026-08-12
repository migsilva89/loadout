import Foundation

public enum ItemSort: String, CaseIterable, Sendable {
    case name
    case usage

    public var label: String {
        switch self {
        case .name: return "Name"
        case .usage: return "Most used"
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
    case mine
    case thisProject
    case shared
    case neverUsed
    case disabled

    public var title: String {
        switch self {
        case .all: return "All"
        case .mine: return "Mine"
        case .thisProject: return "This project"
        case .shared: return "Shared"
        case .neverUsed: return "Never used"
        case .disabled: return "Disabled"
        }
    }
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
    public static func filter(_ items: [Item], by filter: ItemFilter) -> [Item] {
        switch filter {
        case .all:
            return items
        case .mine:
            return items.filter { $0.origin == .personal }
        case .thisProject:
            return items.filter {
                if case .project = $0.origin { return true }
                return false
            }
        case .shared:
            return items.filter { $0.assistants.count > 1 }
        case .neverUsed:
            return items.filter { $0.usage.neverUsed }
        case .disabled:
            return items.filter { !$0.enabled }
        }
    }

    public static func sort(_ items: [Item], by order: ItemSort) -> [Item] {
        switch order {
        case .name:
            return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .usage:
            return items.sorted {
                $0.usage.count == $1.usage.count
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.usage.count > $1.usage.count
            }
        }
    }

    public static func apply(
        _ items: [Item], selection: Selection, filter chip: ItemFilter, query: String, order: ItemSort
    ) -> [Item] {
        sort(
            filter(slice(items, for: selection), by: chip).filter { matches($0, query: query) },
            by: order
        )
    }
}

public extension Usage {
    /// "12 uses · 2 days ago", or "never used".
    func summary(now: Date = Date()) -> String {
        guard count > 0 else { return "never used" }
        let uses = count == 1 ? "1 use" : "\(count) uses"
        guard let last = lastUsed else { return uses }
        return "\(uses) · \(Self.relative(last, now: now))"
    }

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
