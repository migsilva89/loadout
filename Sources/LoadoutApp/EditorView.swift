import SwiftUI
import AppKit
import LoadoutCore

// MARK: - State the editor reports back

/// One live problem in the buffer, anchored to a line so the gutter can mark it.
struct EditorIssue: Equatable {
    let line: Int
    let message: String
}

/// What the status bar under the editor shows: where the caret is and what's wrong.
struct EditorState: Equatable {
    var line = 1
    var column = 1
    var issues: [EditorIssue] = []
}

/// The 1-based line the caret sits on — the status bar and the gutter both ask.
@MainActor
func caretLine(of textView: NSTextView) -> Int {
    let source = textView.string as NSString
    let upToCaret = source.substring(to: min(textView.selectedRange().location, source.length))
    return upToCaret.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
}

extension Notification.Name {
    /// ⌘F while the Edit mode is up: the menu command has no reference to the text view,
    /// so it posts this and the editor's coordinator opens the find bar.
    static let loadoutEditorFind = Notification.Name("loadout.editorFind")
}

// MARK: - The editor

/// A real Markdown editor, not a viewer with colours: an `NSTextView` that keeps syntax
/// highlighting and the caret in the same buffer, a gutter with line numbers, modified-line
/// bars and issue marks, a slightly lifted frontmatter region, live validation against the
/// documented limits, and the system find bar with its match counter.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    /// The on-disk version, for the gutter's modified-line bars.
    var original: String
    var onEdit: () -> Void
    var onState: (EditorState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(V2.editor)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        // The full programmatic-NSTextView sizing dance: without it the view keeps a zero
        // frame, the text never draws, and only the gutter betrays that a buffer exists.
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(V2.editor)
        textView.insertionPointColor = NSColor(red: 0.56, green: 0.72, blue: 1.0, alpha: 1)
        textView.font = Self.font
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.delegate = context.coordinator
        textView.string = text

        scroll.documentView = textView

        // Not an `NSRulerView`: a ruler inside a SwiftUI `ScrollView` makes SwiftUI drop the
        // rest of the pane's drawing entirely. The gutter is a plain sibling view that reads
        // the text view's visible rect and repaints whenever the clip view scrolls.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 646, height: 400))
        let gutter = LineGutter(frame: NSRect(x: 0, y: 0, width: 46, height: 400))
        gutter.textView = textView
        gutter.autoresizingMask = [.height]
        scroll.frame = NSRect(x: 46, y: 0, width: 600, height: 400)
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(gutter)
        container.addSubview(scroll)

        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak gutter] _ in
            // queue: .main guarantees main-thread delivery.
            MainActor.assumeIsolated { gutter?.needsDisplay = true }
        }

        context.coordinator.textView = textView
        context.coordinator.gutter = gutter
        context.coordinator.refresh(original: original)

        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.openFindBar),
            name: .loadoutEditorFind, object: nil
        )
        return container
    }

    /// Every Preview↔Edit flip and selection change tears the editor down; without this,
    /// each one left a block observer registered in NotificationCenter forever.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let token = coordinator.boundsObserver {
            NotificationCenter.default.removeObserver(token)
        }
        NotificationCenter.default.removeObserver(coordinator)
    }

    func updateNSView(_ scroll: NSView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        // Only push the binding's text in when it truly changed elsewhere (Revert, a new
        // selection) — echoing every keystroke back in would fight the caret.
        if textView.string != text {
            textView.string = text
            context.coordinator.refresh(original: original)
        } else if context.coordinator.lastOriginal != original {
            context.coordinator.refresh(original: original)
        }
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        weak var gutter: LineGutter?
        var lastOriginal = ""
        var boundsObserver: NSObjectProtocol?

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            parent.onEdit()
            refresh(original: parent.original)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            reportState()
            // The caret's own line number draws brighter, so moving it repaints the gutter.
            gutter?.needsDisplay = true
        }

        @objc func openFindBar() {
            guard let textView else { return }
            textView.window?.makeFirstResponder(textView)
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(item)
        }

        /// Re-highlights, re-validates and repaints the gutter — cheap enough to run on
        /// every keystroke at the sizes skills actually are.
        func refresh(original: String) {
            guard let textView else { return }
            lastOriginal = original
            MarkdownHighlighter.apply(to: textView)
            let issues = MarkdownHighlighter.validate(textView)
            gutter?.modifiedLines = Self.modifiedLines(current: textView.string, original: original)
            gutter?.issueLines = Set(issues.map(\.line))
            gutter?.needsDisplay = true
            reportState(issues: issues)
        }

        private var lastIssues: [EditorIssue] = []
        private var lastReported = EditorState()

        private func reportState(issues: [EditorIssue]? = nil) {
            guard let textView else { return }
            if let issues { lastIssues = issues }
            let line = caretLine(of: textView)
            let caret = textView.selectedRange().location
            let upToCaret = (textView.string as NSString).substring(to: min(caret, (textView.string as NSString).length))
            let column = upToCaret.distance(
                from: upToCaret.range(of: "\n", options: .backwards)?.upperBound ?? upToCaret.startIndex,
                to: upToCaret.endIndex
            ) + 1
            let state = EditorState(line: line, column: column, issues: lastIssues)
            guard state != lastReported else { return }
            lastReported = state
            // Never mutate SwiftUI state inside make/update — this runs during both, and a
            // synchronous write there makes SwiftUI silently drop the rest of the pane.
            let onState = parent.onState
            DispatchQueue.main.async { onState(state) }
        }

        /// Which line numbers differ from the file on disk — the gutter's blue bars. A real
        /// diff, not a positional compare: one inserted line used to flag everything below
        /// it, which drowned the signal the bars exist to give.
        static func modifiedLines(current: String, original: String) -> Set<Int> {
            let now = current.components(separatedBy: "\n")
            let disk = original.components(separatedBy: "\n")
            var changed: Set<Int> = []
            for case let .insert(offset, _, _) in now.difference(from: disk) {
                changed.insert(offset + 1)
            }
            return changed
        }
    }
}

// MARK: - Highlighting and validation

/// The design's editor palette, applied as attributes so the same buffer stays editable:
/// frontmatter keys pink and values red, headings white on a dim hash, inline code teal on a
/// faint chip, fenced blocks in the command yellow, and the frontmatter region lifted a step
/// above the editor's ground.
enum MarkdownHighlighter {
    static let plain = NSColor(white: 1, alpha: 0.86)
    static let dim = NSColor(red: 0.42, green: 0.47, blue: 0.53, alpha: 1)      // #6C7986
    static let key = NSColor(red: 0.99, green: 0.37, blue: 0.64, alpha: 1)      // #FC5FA3
    static let str = NSColor(red: 0.99, green: 0.42, blue: 0.36, alpha: 1)      // #FC6A5D
    static let head = NSColor.white
    static let code = NSColor(red: 0.56, green: 0.83, blue: 0.78, alpha: 1)     // #8FD3C8
    static let cmd = NSColor(red: 0.82, green: 0.75, blue: 0.41, alpha: 1)      // #D0BF69
    static let frontmatterGround = NSColor(white: 1, alpha: 0.03)
    static let issueRed = NSColor(red: 0.89, green: 0.29, blue: 0.29, alpha: 1)

    static func apply(to textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        let source = textView.string as NSString
        let full = NSRange(location: 0, length: source.length)

        storage.beginEditing()
        storage.setAttributes([
            .font: MarkdownEditor.font,
            .foregroundColor: plain,
        ], range: full)

        var inFrontmatter = false
        var closedFrontmatter = false
        var inFence = false
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
            defer { location = NSMaxRange(lineRange) }

            if line == "---", !inFence, !closedFrontmatter {
                if !inFrontmatter, lineRange.location == 0 {
                    inFrontmatter = true
                } else if inFrontmatter {
                    inFrontmatter = false
                    closedFrontmatter = true
                }
                storage.addAttribute(.foregroundColor, value: dim, range: lineRange)
                storage.addAttribute(.backgroundColor, value: frontmatterGround, range: lineRange)
                continue
            }
            if inFrontmatter {
                storage.addAttribute(.backgroundColor, value: frontmatterGround, range: lineRange)
                if let match = try? /^([\w-]+)(:)/.prefixMatch(in: line) {
                    let keyLength = line.distance(from: line.startIndex, to: match.output.1.endIndex)
                    storage.addAttribute(
                        .foregroundColor, value: key,
                        range: NSRange(location: lineRange.location, length: keyLength)
                    )
                    storage.addAttribute(
                        .foregroundColor, value: str,
                        range: NSRange(
                            location: lineRange.location + keyLength + 1,
                            length: max(0, lineRange.length - keyLength - 1)
                        )
                    )
                } else {
                    storage.addAttribute(.foregroundColor, value: str, range: lineRange)
                }
                continue
            }
            if line.hasPrefix("```") {
                inFence.toggle()
                storage.addAttribute(.foregroundColor, value: dim, range: lineRange)
                continue
            }
            if inFence {
                storage.addAttribute(.foregroundColor, value: cmd, range: lineRange)
                continue
            }
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                storage.addAttribute(
                    .foregroundColor, value: dim,
                    range: NSRange(location: lineRange.location, length: min(hashes + 1, lineRange.length))
                )
                let rest = NSRange(
                    location: lineRange.location + hashes + 1,
                    length: max(0, lineRange.length - hashes - 1)
                )
                storage.addAttribute(.foregroundColor, value: head, range: rest)
                storage.addAttribute(
                    .font, value: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold), range: rest
                )
                continue
            }
            if line.hasPrefix("- ") {
                storage.addAttribute(
                    .foregroundColor, value: key,
                    range: NSRange(location: lineRange.location, length: 2)
                )
            }
            // Inline code chips within the line.
            let lineNS = source.substring(with: lineRange) as NSString
            var search = 0
            while true {
                let open = lineNS.range(of: "`", range: NSRange(location: search, length: lineNS.length - search))
                guard open.location != NSNotFound else { break }
                let after = open.location + 1
                guard after < lineNS.length else { break }
                let close = lineNS.range(of: "`", range: NSRange(location: after, length: lineNS.length - after))
                guard close.location != NSNotFound else { break }
                let span = NSRange(
                    location: lineRange.location + open.location,
                    length: close.location - open.location + 1
                )
                storage.addAttribute(.foregroundColor, value: code, range: span)
                storage.addAttribute(.backgroundColor, value: NSColor(white: 1, alpha: 0.06), range: span)
                search = close.location + 1
            }
        }
        storage.endEditing()
    }

    /// The two live checks against Anthropic's documented limits, squiggled in place: a
    /// description costing more than its always-in-context budget, and a name past 64
    /// characters. Returns the issues so the gutter and status bar can point at them.
    @discardableResult
    static func validate(_ textView: NSTextView) -> [EditorIssue] {
        guard let storage = textView.textStorage else { return [] }
        let budget = Budget.measure(document: textView.string)
        var issues: [EditorIssue] = []

        let source = textView.string as NSString
        func squiggle(lineStarting prefix: String, message: String) {
            var location = 0
            var lineNumber = 0
            while location < source.length {
                let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
                lineNumber += 1
                let line = source.substring(with: lineRange)
                if line.hasPrefix(prefix) {
                    storage.addAttributes([
                        .underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                        .underlineColor: issueRed,
                    ], range: NSRange(location: lineRange.location, length: max(0, lineRange.length - 1)))
                    issues.append(EditorIssue(line: lineNumber, message: message))
                    return
                }
                location = NSMaxRange(lineRange)
            }
        }

        if budget.descriptionCharacters > Budget.maxDescriptionCharacters {
            squiggle(
                lineStarting: "description:",
                message: "Description is ~\(budget.descriptionTokens) tokens — over the ~\(Budget.estimatedTokens(characters: Budget.maxDescriptionCharacters)) budget it costs every session"
            )
        }
        if budget.nameCharacters > Budget.maxNameCharacters {
            squiggle(
                lineStarting: "name:",
                message: "Name is \(budget.nameCharacters) characters — the validator rejects anything past \(Budget.maxNameCharacters)"
            )
        }
        return issues
    }
}

// MARK: - Gutter

/// Line numbers plus the two indicators the design asks the gutter to carry: a 2pt blue bar
/// on every line that differs from the file on disk, and a red mark on lines with an issue.
/// A plain view beside the scroll view — deliberately not an `NSRulerView`, which SwiftUI's
/// own scrolling cannot host without dropping the rest of the pane.
final class LineGutter: NSView {
    weak var textView: NSTextView?
    var modifiedLines: Set<Int> = []
    var issueLines: Set<Int> = []

    override var isFlipped: Bool { true }

    override func draw(_ rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }

        NSColor(V2.editor).blended(withFraction: 0.35, of: .black)?.setFill()
        bounds.fill()
        NSColor(white: 1, alpha: 0.07).setFill()
        NSRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height).fill()

        let source = textView.string as NSString
        // View coords → container coords: without subtracting the inset, the visible slice
        // is computed one inset lower than what the eye actually sees.
        var visible = textView.visibleRect
        visible.origin.y -= textView.textContainerInset.height
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        // Count from the START of the line containing the first visible character: when the
        // top of the viewport lands mid-way through a wrapped line, counting up to the raw
        // location includes that partial line and every number comes out one too high.
        let firstLineStart = source.lineRange(for: NSRange(location: chars.location, length: 0)).location
        var lineNumber = 1
        source.enumerateSubstrings(
            in: NSRange(location: 0, length: firstLineStart), options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in lineNumber += 1 }

        let currentLine = caretLine(of: textView)
        var location = firstLineStart
        while location < NSMaxRange(chars) {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let glyphRange = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            lineRect.origin.y += textView.textContainerInset.height
            // Both views are flipped, so the y that comes back converts one to one.
            let y = convert(NSPoint(x: 0, y: lineRect.minY), from: textView).y

            if modifiedLines.contains(lineNumber) {
                NSColor(V2.accent).setFill()
                NSRect(x: 0, y: y + 2, width: 2, height: lineRect.height - 4).fill()
            }
            if issueLines.contains(lineNumber) {
                MarkdownHighlighter.issueRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: y + lineRect.height / 2 - 2.5, width: 5, height: 5)).fill()
            }

            let number = "\(lineNumber)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: NSColor(white: 1, alpha: lineNumber == currentLine ? 0.7 : 0.25),
            ]
            let size = number.size(withAttributes: attrs)
            number.draw(
                at: NSPoint(x: bounds.width - size.width - 9, y: y + (lineRect.height - size.height) / 2),
                withAttributes: attrs
            )

            lineNumber += 1
            location = NSMaxRange(lineRange)
        }
    }

}
