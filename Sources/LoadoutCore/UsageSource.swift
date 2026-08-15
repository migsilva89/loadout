import Foundation
import CryptoKit

/// How certain an event is (SEM-007).
///
/// Claude announces a skill through a tool call of its own, so its events are `explicit`. Codex has
/// no skill tool at all: it activates a skill by reading the file, so the best available signal is a
/// canonical full read, and saying so out loud is the difference between a number and a guess.
public enum UsageEvidence: String, Sendable, Equatable, Codable {
    case explicit
    case inferred
}

/// One proven activation of one item, by one assistant, at one moment.
public struct UsageEvent: Sendable, Equatable {
    /// Stable across passes over unchanged input, which is what makes insertion idempotent.
    public var id: String
    /// Never empty: it is what the Settings checkbox filters on.
    public var assistant: String
    /// The front end the session ran through — `paseo`, `codex-cli`, `codex-app` — when the format
    /// can tell. Attribution only; it never creates a second event.
    public var surface: String?
    public var kind: ItemKind
    public var key: String
    public var timestamp: Date
    public var project: String
    public var sessionID: String?
    public var sourceFile: String
    public var evidence: UsageEvidence

    public init(
        id: String, assistant: String, surface: String? = nil, kind: ItemKind, key: String,
        timestamp: Date, project: String, sessionID: String? = nil, sourceFile: String,
        evidence: UsageEvidence
    ) {
        self.id = id
        self.assistant = assistant
        self.surface = surface
        self.kind = kind
        self.key = key
        self.timestamp = timestamp
        self.project = project
        self.sessionID = sessionID
        self.sourceFile = sourceFile
        self.evidence = evidence
    }
}

/// Builds events with stable identities, and keeps two genuine activations of the same item in the
/// same millisecond apart by counting them.
struct UsageEventFactory {
    private var ordinals: [String: Int] = [:]

    mutating func make(
        assistant: String, surface: String? = nil, kind: ItemKind, key: String, timestamp: Date,
        project: String, sessionID: String?, sourceFile: String, evidence: UsageEvidence
    ) -> UsageEvent {
        // Deliberately excludes surface and project: a corrected attribution or a moved working
        // directory must not conjure a second event out of the same activation.
        let base = [
            assistant, kind.rawValue, key, sessionID ?? sourceFile,
            String(Int(timestamp.timeIntervalSince1970 * 1000)),
        ].joined(separator: "\u{1F}")
        let ordinal = ordinals[base] ?? 0
        ordinals[base] = ordinal + 1
        let digest = SHA256.hash(data: Data("\(base)\u{1F}\(ordinal)".utf8))

        return UsageEvent(
            id: digest.map { String(format: "%02x", $0) }.joined(),
            assistant: assistant, surface: surface, kind: kind, key: key, timestamp: timestamp,
            project: project, sessionID: sessionID, sourceFile: sourceFile, evidence: evidence
        )
    }
}

/// What the Usage tab says about one source.
public enum UsageSourceState: Sendable, Equatable {
    /// History found, parsed, and this assistant is checked in Settings.
    case included
    /// History found and parsed, but the assistant is unchecked — the events are still indexed.
    case excluded
    /// The adapter exists; there is nothing on disk.
    case noHistory
    /// There is history, but no signal in it proves an activation. Contributes nothing, and says so.
    case unsupported
    case error(String)

    public var label: String {
        switch self {
        case .included: return "Included"
        case .excluded: return "Not counted"
        case .noHistory: return "No history found"
        case .unsupported: return "Format unsupported"
        case .error(let message): return "Couldn't read — \(message)"
        }
    }
}

public struct UsageSourceStatus: Identifiable, Sendable, Equatable {
    public var sourceID: String
    public var assistant: String
    public var label: String
    public var state: UsageSourceState
    public var sessionCount: Int
    public var eventCount: Int

    public var id: String { sourceID }

    public init(
        sourceID: String, assistant: String, label: String, state: UsageSourceState,
        sessionCount: Int, eventCount: Int = 0
    ) {
        self.sourceID = sourceID
        self.assistant = assistant
        self.label = label
        self.state = state
        self.sessionCount = sessionCount
        self.eventCount = eventCount
    }
}

/// One history format. The index orchestrates and stores; a source only reads and parses, which is
/// what lets a new assistant arrive as one file and one commit.
public protocol UsageSource: Sendable {
    /// Persisted in `files.source`, so changing a parser invalidates only its own files.
    var id: String { get }
    /// The assistant every event of this source is attributed to. Matches `Assistant.id`.
    var assistant: String { get }
    var label: String { get }
    /// Bumped whenever the parsing rules change.
    var parserVersion: Int { get }
    /// False means the format has no provable activation signal: listed, honest, and silent.
    var isSupported: Bool { get }

    /// Empty for a missing directory. Never throws: an absent assistant is not an error.
    func historyFiles() -> [URL]
    /// Malformed records are skipped, never fatal.
    func events(in file: URL, since: Date) -> [UsageEvent]
    func state() -> UsageSourceState
}

extension UsageSource {
    public func events(in file: URL, since: Date) -> [UsageEvent] { [] }

    public func state() -> UsageSourceState {
        isSupported ? (historyFiles().isEmpty ? .noHistory : .included)
            : (historyFiles().isEmpty ? .noHistory : .unsupported)
    }

    /// Every `.jsonl` under a root, or nothing at all when the root does not exist.
    func jsonlFiles(under root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path),
              let walker = FileManager.default.enumerator(
                  at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              )
        else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" { found.append(url) }
        return found
    }
}

/// Reads a JSONL file a line at a time, in bounded chunks: these files run to hundreds of
/// megabytes, and holding one in memory to count four events in it would be absurd.
enum JSONLReader {
    static func forEachLine(of url: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? handle.close() }

        var pending = Data()
        let newline = UInt8(ascii: "\n")
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            while let index = pending.firstIndex(of: newline) {
                body(pending[pending.startIndex..<index])
                pending = pending[pending.index(after: index)...]
            }
        }
        if !pending.isEmpty { body(pending) }
    }
}

/// Hand-rolled UTC ISO-8601 reader.
///
/// `ISO8601DateFormatter` is neither `Sendable` nor cheap, and this runs once per candidate line
/// across a gigabyte of history — the arithmetic below is both safe to share and an order of
/// magnitude faster.
enum Timestamp {
    static func iso(_ string: String) -> Date? {
        let digits = Array(string.utf8)
        guard digits.count >= 19 else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let byte = digits[index]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }

        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
              month >= 1, month <= 12, day >= 1, day <= 31
        else { return nil }

        var fraction = 0.0
        if digits.count > 20, digits[19] == UInt8(ascii: ".") {
            var index = 20
            var scale = 0.1
            while index < digits.count, digits[index] >= 48, digits[index] <= 57 {
                fraction += Double(digits[index] - 48) * scale
                scale /= 10
                index += 1
            }
        }

        // Days from the civil calendar to the Unix epoch (Howard Hinnant's algorithm).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468

        let seconds = Double(days) * 86_400 + Double(hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }
}

/// The leaf of a working directory, which is how a project is named everywhere in the app.
func projectName(fromCWD cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "?" }
    return URL(fileURLWithPath: cwd).lastPathComponent
}

/// Item names are normalized identically for every source: a plugin-qualified `plugin:skill`
/// counts under the bare name, and a slash command loses its slash.
func normalizedKey(_ raw: String) -> String {
    var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.hasPrefix("/") { name.removeFirst() }
    return name.components(separatedBy: ":").last ?? name
}
