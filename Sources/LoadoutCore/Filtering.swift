import Foundation

public enum ItemSort: String, CaseIterable, Sendable {
    case name
    case usage

    public var label: String {
        switch self {
        case .name: return "Nome"
        case .usage: return "Mais usadas"
        }
    }
}

/// Which slice of the inventory the sidebar is asking for.
public enum Selection: Equatable, Hashable, Sendable {
    case personal
    case projectItems
    case disabled
    case plugin(String)
    case kind(ItemKind)

    public var title: String {
        switch self {
        case .personal: return "Pessoais"
        case .projectItems: return "Projeto"
        case .disabled: return "Desativadas"
        case .plugin(let name): return name
        case .kind(.mcp): return "MCP"
        case .kind(let kind): return kind.label + "s"
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

    public static func slice(_ items: [Item], for selection: Selection) -> [Item] {
        switch selection {
        case .personal:
            return items.filter { $0.origin == .personal && $0.enabled && $0.kind == .skill }
        case .projectItems:
            return items.filter {
                if case .project = $0.origin { return true }
                return false
            }
        case .disabled:
            return items.filter { !$0.enabled }
        case .plugin(let name):
            return items.filter { $0.origin == .plugin(name) }
        case .kind(let kind):
            return items.filter { $0.kind == kind }
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
        _ items: [Item], selection: Selection, query: String, order: ItemSort
    ) -> [Item] {
        sort(slice(items, for: selection).filter { matches($0, query: query) }, by: order)
    }
}

public extension Usage {
    /// "12 usos · há 2 dias", or "nunca usada".
    func summary(now: Date = Date()) -> String {
        guard count > 0 else { return "nunca usada" }
        let uses = count == 1 ? "1 uso" : "\(count) usos"
        guard let last = lastUsed else { return uses }
        return "\(uses) · \(Self.relative(last, now: now))"
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 3600 { return "há minutos" }
        if seconds < 86_400 { return "hoje" }
        let days = Int(seconds / 86_400)
        if days == 1 { return "ontem" }
        if days < 30 { return "há \(days) dias" }
        let months = days / 30
        return months == 1 ? "há 1 mês" : "há \(months) meses"
    }
}
