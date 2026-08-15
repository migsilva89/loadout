import Foundation

/// One contiguous change between the file as it is and the file as the assistant left it.
///
/// A block is the unit Miguel accepts or rejects. It is deliberately line-based and contiguous:
/// that is the granularity the editor's gutter already speaks, and it is the only one that can be
/// applied on its own without the other blocks having been decided first.
public struct DiffBlock: Identifiable, Hashable, Sendable {
    public let id: Int
    /// Where the change starts in the original, as a zero-based line index. A pure insertion
    /// points at the line it goes before.
    public let start: Int
    /// The original lines this block replaces. Empty for an insertion.
    public let removed: [String]
    /// The lines the assistant put there. Empty for a deletion.
    public let added: [String]

    public init(id: Int, start: Int, removed: [String], added: [String]) {
        self.id = id
        self.start = start
        self.removed = removed
        self.added = added
    }

    /// The lines as Miguel should see them: without the newline each one carries internally.
    public var removedText: [String] { removed.map(Self.trimmed) }
    public var addedText: [String] { added.map(Self.trimmed) }

    private static func trimmed(_ line: String) -> String {
        line.hasSuffix("\n") ? String(line.dropLast()) : line
    }

    /// Identifies the change by what it *is*, not by where it happens to fall in this round's
    /// numbering. A decision is remembered against this, so a block whose text the assistant has
    /// since changed comes back needing a decision instead of staying quietly accepted.
    public var signature: String {
        "\(start)\u{0}\(removed.joined())\u{0}\(added.joined())"
    }

    public var isInsertion: Bool { removed.isEmpty }
    public var isDeletion: Bool { added.isEmpty }

    /// What the block is called in the panel — "3 lines replaced", and so on.
    public var summary: String {
        if isInsertion { return added.count == 1 ? "1 line added" : "\(added.count) lines added" }
        if isDeletion { return removed.count == 1 ? "1 line removed" : "\(removed.count) lines removed" }
        return removed.count == 1 && added.count == 1
            ? "1 line changed"
            : "\(removed.count) lines replaced by \(added.count)"
    }
}

/// Compares two versions of a text file and applies chosen blocks back.
///
/// This is where the promise "the assistant proposes, Loadout applies" is kept: whatever the CLI
/// did in its own copy is read here as plain before/after text, so no assistant's output format
/// can decide what lands in Miguel's file.
public enum DiffBlocks {
    /// The blocks that turn `original` into `modified`, in file order.
    public static func blocks(from original: String, to modified: String) -> [DiffBlock] {
        let old = lines(of: original)
        let new = lines(of: modified)

        // Trim the matching head and tail first. On the change this feature exists for — one
        // rewritten `description` line in a file of fifty — this alone leaves two lines to align.
        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }

        let oldMiddle = Array(old[head..<(old.count - tail)])
        let newMiddle = Array(new[head..<(new.count - tail)])
        guard !oldMiddle.isEmpty || !newMiddle.isEmpty else { return [] }

        var blocks: [DiffBlock] = []
        for change in align(oldMiddle, newMiddle) {
            blocks.append(DiffBlock(
                id: blocks.count,
                start: head + change.start,
                removed: change.removed,
                added: change.added
            ))
        }
        return blocks
    }

    /// The text you get by taking `original` and applying only the blocks whose ids are given.
    ///
    /// Applying a subset is why blocks carry absolute positions into the original rather than
    /// offsets that shift: accepting the third block and not the first must land in the same place
    /// either way.
    public static func apply(_ blocks: [DiffBlock], accepting accepted: Set<Int>, to original: String)
        -> String
    {
        let old = lines(of: original)
        var result: [String] = []
        var cursor = 0
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            if block.start > cursor { result += old[cursor..<block.start] }
            cursor = max(cursor, block.start)
            if accepted.contains(block.id) {
                result += block.added
            } else {
                result += block.removed
            }
            cursor += block.removed.count
        }
        if cursor < old.count { result += old[cursor...] }
        return result.joined()
    }

    // MARK: - Alignment

    private struct Change {
        var start: Int
        var removed: [String]
        var added: [String]
    }

    /// Longest-common-subsequence alignment of the differing middles, collapsed into contiguous
    /// changes. Quadratic, which is right for a `SKILL.md`: these files are hundreds of lines at
    /// most, and the head/tail trim above has already thrown away everything that matches.
    private static func align(_ old: [String], _ new: [String]) -> [Change] {
        // Guard against a pathological paste: past this size, report one block for the whole
        // middle rather than spend seconds building the table. Still correct, just coarser.
        guard old.count * new.count <= 4_000_000 else {
            return [Change(start: 0, removed: old, added: new)]
        }

        var table = [[Int]](repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var changes: [Change] = []
        var pending: Change?
        var i = 0, j = 0
        func flush() {
            if let pending { changes.append(pending) }
            pending = nil
        }
        while i < old.count && j < new.count {
            if old[i] == new[j] {
                flush()
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                if pending == nil { pending = Change(start: i, removed: [], added: []) }
                pending?.removed.append(old[i])
                i += 1
            } else {
                if pending == nil { pending = Change(start: i, removed: [], added: []) }
                pending?.added.append(new[j])
                j += 1
            }
        }
        while i < old.count {
            if pending == nil { pending = Change(start: i, removed: [], added: []) }
            pending?.removed.append(old[i])
            i += 1
        }
        while j < new.count {
            if pending == nil { pending = Change(start: i, removed: [], added: []) }
            pending?.added.append(new[j])
            j += 1
        }
        flush()
        return changes
    }

    // MARK: - Lines

    /// Splits into lines with each line's newline still attached to it.
    ///
    /// Keeping the terminator is what makes putting the file back together a plain concatenation,
    /// and it makes "the file gained a final newline" a change like any other instead of a special
    /// case every caller has to remember. The cost is that a line carries a trailing `\n`, so
    /// anything showing one to Miguel trims it first.
    static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "\n" {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
