import Foundation

/// A conversation held about one item, remembered by its id rather than by its contents.
///
/// The assistant already keeps every exchange it has had on disk. So this stores what Loadout needs
/// to find one again — which item and assistant it was about, and something to recognise it by — and
/// nothing that could drift from the real thing.
public struct AskConversation: Codable, Identifiable, Hashable, Sendable {
    /// The CLI's own session id, which is what resumes it.
    public var id: String
    public var itemID: String
    public var cliID: String
    /// The folder it was about. A conversation is only offered for the same folder it was held
    /// about, so a skill that moved doesn't inherit an exchange about somewhere else.
    public var originPath: String
    public var startedAt: Date
    /// The first thing that was asked, trimmed — how a conversation is recognised in a list.
    public var title: String

    public init(
        id: String, itemID: String, cliID: String, originPath: String, startedAt: Date, title: String
    ) {
        self.id = id
        self.itemID = itemID
        self.cliID = cliID
        self.originPath = originPath
        self.startedAt = startedAt
        self.title = title
    }
}

/// Every conversation Loadout knows about, as one JSON blob under one key. Small, always read and
/// written together, and the same reasoning as the custom-CLI list next door.
public enum AskConversationStore {
    public static let key = "askConversations"
    /// A ceiling, so a year of asking doesn't grow an unbounded list in the preferences. Old ones
    /// past this drop off; the CLI still has them, Loadout simply stops offering them.
    public static let limit = 40

    public static func load(defaults: UserDefaults = .standard) -> [AskConversation] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([AskConversation].self, from: data)) ?? []
    }

    public static func save(_ conversations: [AskConversation], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(conversations) else { return }
        defaults.set(data, forKey: key)
    }

    /// Adds or updates one, newest first, keeping the list within its ceiling.
    public static func upsert(
        _ conversation: AskConversation, into conversations: [AskConversation]
    ) -> [AskConversation] {
        var result = conversations.filter { $0.id != conversation.id }
        result.insert(conversation, at: 0)
        result.sort { $0.startedAt > $1.startedAt }
        return Array(result.prefix(limit))
    }

    /// The conversations held about this item with this assistant, in this folder, newest first.
    public static func matching(
        itemID: String, cliID: String, origin: URL, in conversations: [AskConversation]
    ) -> [AskConversation] {
        let path = origin.standardizedFileURL.path
        return conversations
            .filter { $0.itemID == itemID && $0.cliID == cliID && $0.originPath == path }
            .sorted { $0.startedAt > $1.startedAt }
    }
}
