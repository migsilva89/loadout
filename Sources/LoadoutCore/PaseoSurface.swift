import Foundation

/// Which sessions Paseo hosted, read from `~/.paseo/agents`.
///
/// Paseo is not a history of its own: those files hold metadata and no messages, and the sessions
/// themselves live in the provider's own history. So counting `~/.paseo/*` would count the same work
/// twice. What Paseo does give is an exact key — `persistence.sessionId` is the provider's own session
/// id — which turns attribution into a lookup rather than a guess. The working directory is
/// deliberately not used: a session merely running inside a Paseo worktree is not evidence that Paseo
/// ran the agent.
///
/// It hosts Claude more than Codex on this machine (135 records against 41), so this applies to any
/// provider, and it only ever sets a surface — no count moves because of it.
public struct PaseoSurface: Sendable {
    public static let name = "paseo"

    /// Provider session ids Paseo is responsible for.
    public let sessionIDs: Set<String>

    public init(paths: Paths) {
        let root = paths.paseoAgents
        guard FileManager.default.fileExists(atPath: root.path),
              let walker = FileManager.default.enumerator(
                  at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              )
        else {
            sessionIDs = []
            return
        }

        var found: Set<String> = []
        for case let url as URL in walker where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for field in ["persistence", "runtimeInfo"] {
                if let nested = object[field] as? [String: Any],
                   let id = nested["sessionId"] as? String, !id.isEmpty {
                    found.insert(id)
                }
            }
        }
        sessionIDs = found
    }

    init(sessionIDs: Set<String>) { self.sessionIDs = sessionIDs }

    public func hosted(_ sessionID: String?) -> Bool {
        guard let sessionID else { return false }
        return sessionIDs.contains(sessionID)
    }

    /// The surface an event should carry: Paseo when it hosted the session, otherwise whatever the
    /// format itself said.
    func surface(for event: UsageEvent) -> String? {
        hosted(event.sessionID) ? Self.name : event.surface
    }
}
