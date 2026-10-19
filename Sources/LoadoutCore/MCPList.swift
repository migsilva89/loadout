import Foundation

/// One row per server in the MCP list, not one per assistant that happens to have it.
///
/// A server is one thing: `codegraph serve --mcp` running in four configs is one server, and the
/// list answers "what do I have" — four rows of it were four answers to one question, with the
/// same usage number printed four times (usage is keyed by name, so the copies were identical
/// to the digit).
///
/// This collapses them for display only. Owners keep their own rows on disk and in the
/// inventory: `MCPMatrix` builds its grid from them, the Assistants card reads per-assistant
/// state from them, and every switch still writes exactly one assistant's own file. The merge
/// happens where a *name* is what identifies a row — the list, its counts, search and filters.
public enum MCPList {
    /// The id of a collapsed row: stable while the group exists. A group of one keeps the
    /// owner's own id untouched, so a server only one assistant has behaves exactly as it
    /// always has — same selection, same detail, same everything.
    public static func mergedID(_ name: String) -> String { "mcp:merged:\(name)" }

    public static func isMerged(_ item: Item) -> Bool { item.id.hasPrefix("mcp:merged:") }

    /// Folds same-named personal-scope MCP rows into one. Project-scoped rows never fold:
    /// per-project MCP is Claude's alone, and two repositories can share a server's name
    /// without sharing the server.
    public static func mergeDuplicates(_ items: [Item]) -> [Item] {
        var groups: [String: [Item]] = [:]
        for item in items where item.kind == .mcp && item.origin == .personal {
            groups[item.name, default: []].append(item)
        }
        let duplicated = Set(groups.filter { $0.value.count > 1 }.keys)
        guard !duplicated.isEmpty else { return items }

        var result: [Item] = []
        var emitted = Set<String>()
        for item in items {
            if item.kind == .mcp && item.origin == .personal, duplicated.contains(item.name) {
                guard emitted.insert(item.name).inserted else { continue }
                result.append(merged(groups[item.name] ?? [item]))
            } else {
                result.append(item)
            }
        }
        return result
    }

    /// The collapsed row: the first switchable owner's identity — file, path, description —
    /// with the union of assistants and the state that says whether *anywhere* has it on. The
    /// Assistants card is where per-assistant state lives; this row's switch moves them all.
    private static func merged(_ group: [Item]) -> Item {
        let primary = group.first { $0.enabled } ?? group[0]
        var item = primary
        item.id = mergedID(primary.name)
        item.assistants = Set(group.flatMap(\.assistants))
        item.enabled = group.contains { $0.enabled }
        item.modified = group.compactMap(\.modified).max()
        // The same number on every copy today; take the loudest rather than assume it.
        item.usage = group.map(\.usage).max { $0.count < $1.count } ?? primary.usage
        return item
    }
}
