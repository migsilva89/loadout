import Foundation

/// Which assistant a skill started in.
///
/// Sharing a skill moves its real folder to `~/.agents/skills` and leaves every assistant — the one
/// it came from included — holding a link, so the disk no longer says where it began. This is the
/// one thing Loadout writes down about that, so the Assistants card can mark the original.
///
/// Kept in Loadout's own support directory, like `OffRecords`. Losing it is never an error: the
/// skill is still shared and still works, it just stops saying where it came from.
public struct OriginRecords: Sendable {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    var file: URL { paths.support.appendingPathComponent("origins.json") }

    private func read() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return map
    }

    private func key(_ kind: ItemKind, _ name: String) -> String { "\(kind.rawValue):\(name)" }

    public func assistant(for kind: ItemKind, named name: String) -> String? {
        read()[key(kind, name)]
    }

    public func remember(_ kind: ItemKind, named name: String, assistant: String) throws {
        var map = read()
        guard map[key(kind, name)] != assistant else { return }
        map[key(kind, name)] = assistant
        try write(map)
    }

    public func forget(_ kind: ItemKind, named name: String) throws {
        var map = read()
        guard map.removeValue(forKey: key(kind, name)) != nil else { return }
        try write(map)
    }

    private func write(_ map: [String: String]) throws {
        do {
            try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            throw LoadoutError.io("Couldn't record where \(map.keys.first ?? "it") came from: \(error.localizedDescription)")
        }
    }
}
