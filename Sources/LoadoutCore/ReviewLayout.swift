import Foundation

/// The document as it is shown while there are proposed changes in it: the file, with each change
/// opened up in place — the old lines struck through above the new ones.
///
/// This exists so the review happens *in* the document rather than in a narrow column beside it. A
/// diff of two lines is readable anywhere; a diff of forty is only readable at the width of the
/// pane, with the surrounding text around it for context.
public struct ReviewLayout: Sendable {
    /// What one line of the shown document is.
    public enum Kind: Hashable, Sendable {
        /// Unchanged text from the file.
        case context
        /// A line this change would remove, still undecided.
        case removed(block: Int)
        /// A line this change would add, still undecided.
        case added(block: Int)
        /// A line from a change already accepted — in the document for real now, and marked as
        /// having arrived this way.
        case accepted(block: Int)

        public var block: Int? {
            switch self {
            case .context: return nil
            case .removed(let id), .added(let id), .accepted(let id): return id
            }
        }
    }

    /// The text to show, which is *not* the file: it holds both sides of every undecided change.
    public let text: String
    /// One entry per line of `text`, in order.
    public let kinds: [Kind]
    /// Where each undecided change sits in the shown text, as a range of zero-based line indexes.
    /// This is what the Accept and Reject buttons are anchored to.
    public let pendingRanges: [Int: Range<Int>]

    public init(text: String, kinds: [Kind], pendingRanges: [Int: Range<Int>]) {
        self.text = text
        self.kinds = kinds
        self.pendingRanges = pendingRanges
    }

    public var hasPending: Bool { !pendingRanges.isEmpty }

    /// Builds the shown document.
    ///
    /// - Parameters:
    ///   - original: the file as it is on disk.
    ///   - blocks: every change found between the file and the assistant's copy.
    ///   - decisions: `true` accepted, `false` rejected, absent still to decide — keyed by each
    ///     change's signature, so a change the assistant has since edited comes back undecided.
    public static func make(
        original: String,
        blocks: [DiffBlock],
        decisions: [String: Bool]
    ) -> ReviewLayout {
        let old = DiffBlocks.lines(of: original)
        var lines: [String] = []
        var kinds: [Kind] = []
        var ranges: [Int: Range<Int>] = [:]
        var cursor = 0

        for block in blocks.sorted(by: { $0.start < $1.start }) {
            if block.start > cursor {
                for line in old[cursor..<block.start] {
                    lines.append(line)
                    kinds.append(.context)
                }
            }
            cursor = max(cursor, block.start)

            switch decisions[block.signature] {
            case .some(true):
                for line in block.added {
                    lines.append(line)
                    kinds.append(.accepted(block: block.id))
                }
            case .some(false):
                // Refused: the file's own lines, as if the change had never been proposed.
                for line in block.removed {
                    lines.append(line)
                    kinds.append(.context)
                }
            case nil:
                let start = lines.count
                for line in block.removed {
                    lines.append(line)
                    kinds.append(.removed(block: block.id))
                }
                for line in block.added {
                    lines.append(line)
                    kinds.append(.added(block: block.id))
                }
                ranges[block.id] = start..<lines.count
            }
            cursor += block.removed.count
        }

        if cursor < old.count {
            for line in old[cursor...] {
                lines.append(line)
                kinds.append(.context)
            }
        }

        // Lines carry their own newline, and the file's last line usually has none. Shown as-is,
        // the old last line and the new one it is replaced by would run together into a single line
        // on screen. So every line but the last gets a terminator.
        for index in lines.indices.dropLast() where !lines[index].hasSuffix("\n") {
            lines[index] += "\n"
        }
        return ReviewLayout(text: lines.joined(), kinds: kinds, pendingRanges: ranges)
    }
}
