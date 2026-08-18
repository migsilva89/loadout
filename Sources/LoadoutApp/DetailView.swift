import SwiftUI
import LoadoutCore

/// The reading scroller's *content* space. A position measured here is an offset down the document
/// and holds still while scrolling, which is what makes the heading offsets cheap to keep and
/// usable as scroll targets.
///
/// File scope, so the geometry closures that read these are not reaching into a main-actor type to
/// do it — and computed rather than stored, because `NamedCoordinateSpace` is not `Sendable`.
var readingContentSpace: NamedCoordinateSpace { .named("loadout.readingContent") }

/// And the reading scroller's viewport, which is what the scroll-spy's line is measured down from.
var readingViewportSpace: NamedCoordinateSpace { .named("loadout.readingViewport") }

/// The v2 detail pane: identity header with the one big switch, then cards — Token budget and
/// Details side by side, the Assistants grid, and the document with its own toolbar. Every
/// section is a rounded surface on the darker window ground, the way the design draws them.
struct DetailView: View {
    /// The narrowest the pane is allowed to be, which the sidebar gives way to keep.
    ///
    /// Not a round number by taste: the document toolbar's shortest honest arrangement needs about
    /// 390pt, and the card's 24pt margins and 10pt padding sit outside that. Under this the pane
    /// starts clipping controls instead of laying them out.
    static let minimumWidth: CGFloat = 470

    @Bindable var model: AppModel
    /// What the editor reports back — caret position and live issues — for the status bar.
    @State private var editorState = EditorState()
    /// Where the editor put each undecided change on screen, so its buttons follow it as the
    /// document scrolls.
    @State private var reviewFrames: [Int: CGRect] = [:]

    /// How tall the pane actually is right now — the editor sizes itself against this, so
    /// a taller window means a taller buffer instead of a fixed slab with dead space below.
    @State private var paneHeight: CGFloat = 900
    /// And how wide, which is what decides whether the reading rail has room to exist.
    @State private var paneWidth: CGFloat = 1200
    /// How much of the pane the identity header and the fact cards have already spent.
    ///
    /// Measured rather than assumed: the cards grow a row on the skills that have a folder
    /// beside the file, and the Assistants grid drops to two columns and then to one as the
    /// pane narrows. A constant here is what made the document ask for more height than was
    /// left, which is what put a second scroller around the whole page.
    @State private var chromeHeight: CGFloat = 380

    /// Whether the three fact cards are folded away, leaving the summary strip in their place.
    ///
    /// One answer for the whole app, and remembered: it is a preference about how somebody reads,
    /// like the reading size below, not state belonging to one skill. See DetailsDisclosure.
    @AppStorage(DetailsDisclosure.key) private var detailsCollapsed = false

    /// Whether the Details card is listing what sits beside the document. Shut by default, and
    /// deliberately not remembered between selections: opening it on one skill should not make
    /// every other skill's card taller before you have even looked at it.
    @State private var filesExpanded = false

    /// The document's headings as the renderer reports them, and which of them is being read.
    /// Both arrive as preferences, and both change rarely: the list only when the text does, the
    /// active one only when the reader crosses a heading.
    @State private var headings: [DocumentHeading] = []
    @State private var activeHeading: Int?

    /// Where each heading sits down the document, for the tick rail to scrub against, and the
    /// scroll view to put it there.
    @State private var headingOffsets: [Int: CGFloat] = [:]
    @State private var paneScroller: NSScrollView?

    /// The selected row and the cheap detail chrome must reach the screen before CoreText starts
    /// laying out the document. Keeping this separate from `selectedID` creates that paint boundary:
    /// a new selection initially gets the shell, then its Markdown enters on the next run-loop pass.
    @State private var renderedDocumentID: String?


    /// The projects the selected item was used in. Loaded when the selection or its usage
    /// changes rather than on every redraw — behind it is a query against the usage index.
    @State private var projectUsage: [ProjectUsage] = []
    /// Uses per assistant for the selected item, so the grid can show where the total came from.
    @State private var assistantUsage: [String: Int] = [:]

    // Reading preferences — the Aa popover's three choices, persisted because they are
    // preferences about reading, not state of one session.
    @AppStorage("readerFontSize") private var readerFontSize = 15.0
    @AppStorage("readerFont") private var readerFont = "system"
    @AppStorage("readerBackground") private var readerBackground = "darker"
    @State private var readerPopoverOpen = false

    private var readerDesign: Font.Design {
        switch readerFont {
        case "serif": return .serif
        case "mono": return .monospaced
        default: return .default
        }
    }

    /// The reading surface, darker than the card and the toolbar so the text reads as paper,
    /// not chrome. Ink is the extreme option, never the default. Each theme brings its own
    /// three, and in each of them the three step darker in this order.
    private var readerGround: Color { V2.reader(readerBackground) }

    var body: some View {
        if let item = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Self.sectionGap) {
                    chrome(item)
                    documentCard(item, rendersBody: renderedDocumentID == item.id)
                }
                .padding(.horizontal, Self.cardMargins)
                .padding(.top, Self.paneTopPadding)
                .padding(.bottom, Self.paneBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(V2.window)
                .onPreferenceChange(DocumentHeadingsKey.self) { headings = $0 }
                // Lazy headings report only while they are materialized. Keep the last concrete
                // heading instead of snapping the funnel back to the first between batches.
                .onPreferenceChange(ActiveHeadingKey.self) { if let value = $0 { activeHeading = value } }
                // Accumulate exact positions as lazy headings appear. Replacing the dictionary
                // would forget every heading that just scrolled out of the materialized region.
                .onPreferenceChange(HeadingOffsetsKey.self) { headingOffsets.merge($0) { _, next in next } }
                .onChange(of: item.id) { _, _ in
                    headings = []
                    headingOffsets = [:]
                    activeHeading = nil
                    paneScroller = nil
                    renderedDocumentID = nil
                    filesExpanded = false
                }
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                    paneHeight = size.height
                    paneWidth = size.width
                }
                // Re-read when the item changes, and again when a finished index pass gives
                // this one a different count than it had a moment ago. Not read at all until
                // there is a rail to read it into: it is a query, not a field on the item.
                .task(id: "\(item.id)#\(item.usage.count)#\(showsRail)") {
                    projectUsage = []
                    guard showsRail else { return }
                    let usage = await model.projectUsage(for: item)
                    guard !Task.isCancelled else { return }
                    projectUsage = usage
                }
                // The breakdown behind the total. Read whenever the total moves, so the parts
                // and the whole are never showing two different passes of the index.
                .task(id: "\(item.id)#\(item.usage.count)") {
                    assistantUsage = [:]
                    let counts = await model.usageByAssistant(for: item)
                    guard !Task.isCancelled else { return }
                    assistantUsage = counts
                }
                .task(id: item.id) {
                    // `yield()` alone may resume before AppKit's display observer. A short deadline
                    // guarantees one visible selection frame even when the run loop is busy.
                    try? await Task.sleep(for: .milliseconds(24))
                    guard !Task.isCancelled else { return }
                    renderedDocumentID = item.id
                }
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "square.stack.3d.up",
                description: Text("The list on the left contains everything Claude loads.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(V2.window)
        }
    }

    // MARK: - Chrome above the document

    /// Everything the pane shows before the document: who this is, what it costs, and who loads
    /// it. Grouped rather than laid out loose so its height can be measured in one piece — the
    /// document below is sized from what this leaves over.
    private func chrome(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: Self.sectionGap) {
            header(item)
            if let warning = item.warning {
                warningCallout(warning)
            }
            if case .project(let repository) = item.origin, item.kind != .mcp {
                projectCallout(item, repository: repository)
            }
            if detailsCollapsed {
                DetailsSummaryStrip(summary: summary(item)) { toggleDetails() }
            } else {
                factCards(item)
            }
            // The seam belongs to this block, not to the document below it, for two reasons: it is
            // the bottom edge of the thing it folds, and being inside the measured block means the
            // document's height is worked out from a number that already includes it.
            DetailsSeam(collapsed: detailsCollapsed) { toggleDetails() }
        }
        // Safe to read back into a height the document uses: nothing in here is sized from the
        // document, so the measurement can't chase what it caused.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            chromeHeight = height
            // Reported outwards for the driver that photographs this pane: the check that the
            // document really rose by what the cards vacated is a subtraction of two of these, and
            // a number the view measured is the only honest source for it. See DriveScript.
            model.reportChromeHeight(height)
        }
    }

    /// Token budget, Details and Assistants — the three the fold is about.
    @ViewBuilder
    private func factCards(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: Self.sectionGap) {
            // The two fact cards share a row while the pane is wide and stack when it
            // isn't — same content either way.
            ViewThatFits(in: .horizontal) {
                // Both surfaces take the height of the taller one, rows staying at the
                // top. With four rows each they already agree; this is what keeps them
                // agreeing on the skills whose folder adds a "Files" row to Details.
                //
                // The row is already as tall as its tallest card, so each card asking for
                // the full height is the whole mechanism — no measuring, no state, and
                // nothing that could feed a height back into what produced it.
                HStack(alignment: .top, spacing: 12) {
                    if showsBudget(item) {
                        budgetCard(item).frame(maxWidth: .infinity, alignment: .top)
                    }
                    detailsCard(item).frame(maxWidth: .infinity, alignment: .top)
                }
                VStack(spacing: 12) {
                    if showsBudget(item) { budgetCard(item) }
                    detailsCard(item)
                }
            }
            if showsAssistants(item) {
                assistantsCard(item)
            }
        }
        // Folded and unfolded are the same content at two heights, so the collapse is a move rather
        // than a cross-fade: the cards slide up under the header instead of dissolving through it.
        .transition(.move(edge: .top).combined(with: .opacity))
        .clipped()
    }

    /// Who the Assistants card is for: your own skills and commands, while they are switched on.
    private func showsAssistants(_ item: Item) -> Bool {
        (item.kind == .skill || item.kind == .command) && item.origin == .personal && item.enabled
    }

    /// The one gesture behind all three controls — the chip, the seam and ⌥⌘I — so they cannot
    /// drift into meaning three slightly different things.
    private func toggleDetails() {
        withAnimation(DetailsDisclosure.easing) { detailsCollapsed.toggle() }
    }

    /// The strip's line, built from the very strings the cards print above it.
    private func summary(_ item: Item) -> DetailsSummary {
        DetailsSummary(
            source: sourceText(item),
            usage: summaryUsage(item),
            tokens: showsBudget(item)
                ? "~\(item.budget.descriptionTokens) / ~\(Budget.estimatedTokens(characters: Budget.maxDescriptionCharacters)) tok"
                : nil,
            lines: showsBudget(item) ? "\(item.budget.bodyLines) / \(Budget.maxBodyLines) lines" : nil,
            overBudget: item.budget.isOverBudget,
            assistants: showsAssistants(item)
                ? model.visibleAssistants.filter { item.assistants.contains($0.id) }
                : []
        )
    }

    /// "14 uses · 6 projects" — the Details card's sentence with the strip's own separator, and the
    /// same window named when there is nothing to count, because "no uses" alone claims more than
    /// the index knows.
    private func summaryUsage(_ item: Item) -> String {
        guard !item.usage.neverUsed else { return "No uses in \(windowSuffix)" }
        return "\(uses(item.usage.count)) · \(count(item.usage.projectCount, of: "project"))"
    }

    /// The height the document card's body is given: the pane, less what the header and the
    /// cards took, less the document's own toolbar and the margins around the stack.
    ///
    /// This is what keeps the pane to one scroller. Asking for a share of the *window* — which
    /// is what a constant discount amounts to — left the page taller than the pane at every
    /// window size, so the whole thing scrolled to show a document that scrolls.
    private var documentBodyHeight: CGFloat {
        max(
            Self.minimumDocumentHeight,
            paneHeight - chromeHeight - Self.sectionGap
                - Self.paneTopPadding - Self.paneBottomPadding - Self.documentToolbarHeight
        )
    }

    /// The reading area inside that body, which sits on 12pt of padding all round.
    private var readingHeight: CGFloat { documentBodyHeight - Self.readingInset * 2 }

    /// Under this the document stops being readable, and the pane would rather scroll than
    /// shrink it further — the honest way for a window dragged shorter than its content to behave.
    static let minimumDocumentHeight: CGFloat = 260
    private static let sectionGap: CGFloat = 14
    private static let paneTopPadding: CGFloat = 20
    private static let paneBottomPadding: CGFloat = 28
    /// The toolbar's 40pt and the hairline under it.
    private static let documentToolbarHeight: CGFloat = 40.5
    private static let readingInset: CGFloat = 12
    private static let editorStatusBarHeight: CGFloat = 28

    // MARK: - Header

    private func header(_ item: Item) -> some View {
        HStack(alignment: .center, spacing: 12) {
            // The theme's own gradient, the same one the app icon is drawn with — the tile is
            // the item's icon, and which kind it is comes from the glyph on it and the tab you
            // are on, not from a hue borrowed from the system palette.
            RoundedRectangle(cornerRadius: 9)
                .fill(V2.grad)
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: icon(for: item.kind))
                        .font(.system(size: 18))
                        .foregroundStyle(.white)
                }
                .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1)
                .saturation(item.enabled ? 1 : 0.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(V2.text)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(subtitle(item))
                        .font(.system(size: 11.5))
                        .foregroundStyle(V2.textDim)
                        .lineLimit(1)
                        .help(subtitleHelp(item))
                    DetailsChip(collapsed: detailsCollapsed) { toggleDetails() }
                }
            }
            Spacer(minLength: 12)
            // Every skill has this switch now, whoever it belongs to: a plugin shipping 38 of them
            // used to mean all 38 or none.
            if item.kind != .plugin {
                Text(item.enabled ? "Enabled" : "Disabled")
                    .font(.system(size: 12.5))
                    .foregroundStyle(V2.textMid)
                    .help(switchHelp(item))
                MiniSwitch(on: item.enabled, width: 40, height: 24) { model.toggle(item) }
                    .help(switchHelp(item))
            }
        }
    }

    /// "Personal skill · 12 KB · modified 1 month ago" — origin, weight and age in one quiet line.
    private func subtitle(_ item: Item) -> String {
        var parts = [sourceText(item)]
        if let size = fileSize(item) { parts.append(size) }
        if let modified = item.modified { parts.append("modified \(Usage.relative(modified))") }
        return parts.joined(separator: " · ")
    }

    /// The quiet line under the name reads as three facts run together, and only the first of them
    /// says what it is. Named here rather than guessed at: the parts it prints are conditional, so
    /// the tooltip names only the ones that are actually on screen.
    private func subtitleHelp(_ item: Item) -> String {
        var parts = ["where this \(item.kind.briefingNoun) lives"]
        if fileSize(item) != nil { parts.append("how big its file is") }
        if item.modified != nil { parts.append("when that file last changed") }
        guard parts.count > 1 else { return "Where this \(item.kind.briefingNoun) lives" }
        let listed = parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        return listed.prefix(1).uppercased() + listed.dropFirst()
    }

    /// What turning the one big switch off actually does — which is never delete anything, and is
    /// worth saying, because a switch beside a file is read as one that might.
    private func switchHelp(_ item: Item) -> String {
        let noun = item.kind.briefingNoun
        if item.kind == .mcp {
            return item.enabled
                ? "Turn off to lift this server out of the assistant's configuration, keeping what it said so you can put it back"
                : "Turn on to put this server back into the assistant's configuration"
        }
        return item.enabled
            ? "Turn off and no assistant loads this \(noun) — its files move aside on disk, so nothing is lost"
            : "Turn on and assistants load this \(noun) again"
    }

    /// Where to send someone who wants to see this on disk: the folder for a skill, the file's
    /// folder for a command or an agent, and the JSON file itself for an MCP server.
    private func locationPath(_ item: Item) -> String? {
        if item.kind == .mcp { return item.path.map { displayPath($0) } }
        guard let folder = item.directory ?? item.path?.deletingLastPathComponent() else { return nil }
        return displayPath(folder)
    }

    private func sourceText(_ item: Item) -> String {
        // "Personal mcp" read like a typo. The kind's own noun — "MCP server" — is the word for it.
        if item.kind == .mcp {
            switch item.origin {
            case .personal: return "Personal MCP server"
            // Two different things read as "MCP server in loadout": one your own config filed under
            // that project, and one the repository ships for whoever checks it out. Only the second
            // arrives with a pull, so the row says which it is.
            case .project(let name):
                return item.declaredByRepository
                    ? "MCP server shipped by \(name)" : "MCP server in \(name)"
            case .plugin(let name): return "MCP server from the \(name) plugin"
            }
        }
        let kind = item.kind.label
        switch item.origin {
        case .personal: return "Personal \(kind.lowercased())"
        case .project(let name): return "\(kind) in \(name)"
        // "Command from codex" read as the Codex assistant, when it is a Claude Code plugin
        // called codex whose whole job is to send work to Codex.
        case .plugin(let name): return "\(kind) from the \(name) plugin"
        }
    }

    /// Something that lives inside a repository works only there, and the way out is one click —
    /// but only if the click can be found. As a link at the end of a row it could not: the first
    /// person to go looking for it walked past it twice. So it says what the limit is and offers
    /// the way out in the same breath, once, on the items where it is true.
    private func projectCallout(_ item: Item, repository: String) -> some View {
        // Once your copy exists there is nothing left to offer here, so the button goes and the row
        // is left saying what is true: this one belongs to the repository. Where the copy went was
        // said by the dialog that made it, path and all — leaving a live button beside a copy that
        // was already taken is how "Make global" came to be clicked twice.
        let copied = model.hasGlobalCopy(of: item)
        return HStack(spacing: 12) {
            Image(systemName: copied ? "checkmark.circle.fill" : "folder.badge.gearshape")
                .font(.system(size: 15))
                .foregroundStyle(copied ? V2.ok : V2.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(copied ? "You have your own copy of this" : "Only works inside \(repository)")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(V2.text)
                Text(
                    copied
                        ? "Yours works in every project. This one is \(repository)'s, and the two are separate files."
                        : "Make a copy of your own and it works in every project. The repository keeps its own, so nobody else loses it."
                )
                .font(.system(size: 11.5))
                .foregroundStyle(V2.textMid)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !copied {
                Button {
                    model.makeGlobal(item)
                } label: {
                    Text("Make global")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(V2.accent, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Copy \(item.name) into your own \(item.kind.briefingNoun)s, leaving the repository's copy where it is")
                .pointingHand()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(V2.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    private func warningCallout(_ warning: String) -> some View {
        Label(warning, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12.5))
            .foregroundStyle(V2.amber)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(V2.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Token budget card

    /// The budget measures a document: a description that is in context every session and a body
    /// that arrives on trigger. An MCP server has neither — it is a command line the assistant runs
    /// — so the card was four bars resting at zero against limits that do not apply to it.
    private func showsBudget(_ item: Item) -> Bool { item.kind != .mcp }

    private func budgetCard(_ item: Item) -> some View {
        V2Card {
            VStack(spacing: 0) {
                cardHeader { V2CardCaption(text: "Token budget") }
                // All four limits the budget actually measures, in loading order: the metadata
                // that is in context in every session, then the body that only arrives on
                // trigger. Showing two of the four was why this card came up short — of height,
                // and of the truth.
                meterRow(
                    label: "Description",
                    fraction: Double(item.budget.descriptionCharacters) / Double(Budget.maxDescriptionCharacters),
                    over: item.budget.descriptionCharacters > Budget.maxDescriptionCharacters,
                    value: "~\(item.budget.descriptionTokens) / ~\(Budget.estimatedTokens(characters: Budget.maxDescriptionCharacters)) tok"
                )
                // Skills only: a command is named after its file and has no name field, so this
                // row was a bar sitting at 0 / 64 for a rule that does not apply (AC10.3).
                if item.kind == .skill {
                    meterRow(
                        label: "Name",
                        fraction: Double(item.budget.nameCharacters) / Double(Budget.maxNameCharacters),
                        over: item.budget.nameCharacters > Budget.maxNameCharacters,
                        value: "\(item.budget.nameCharacters) / \(Budget.maxNameCharacters) chars"
                    )
                }
                meterRow(
                    label: "Body lines",
                    fraction: Double(item.budget.bodyLines) / Double(Budget.maxBodyLines),
                    over: item.budget.bodyLines > Budget.maxBodyLines,
                    value: "\(item.budget.bodyLines) / \(Budget.maxBodyLines) lines"
                )
                meterRow(
                    label: "Body words",
                    fraction: Double(item.budget.bodyWords) / Double(Budget.maxBodyWords),
                    over: item.budget.bodyWords > Budget.maxBodyWords,
                    value: "\(item.budget.bodyWords) / \(Budget.maxBodyWords) words"
                )
            }
            // Inside the card, so the surface is painted behind the taller frame. Outside it, the
            // container grew and the background stayed the size of the rows.
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .help(budgetHelp(item))
    }

    private func meterRow(label: String, fraction: Double, over: Bool, value: String) -> some View {
        HStack(spacing: 11) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.white.opacity(0.75))
                .frame(width: 78, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.4))
                    Capsule()
                        .fill(over ? V2.amber : V2.ok)
                        .frame(width: proxy.size.width * min(1, max(0.02, fraction)))
                }
            }
            .frame(height: 5)
            Text(value)
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(over ? V2.amber : Color.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.horizontal, 13)
        // The same 9 as a Details row: the two cards sit side by side, so they have to be one
        // grid rather than two that nearly agree.
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Hairline(color: Color.white.opacity(0.06)) }
    }

    private func budgetHelp(_ item: Item) -> String {
        let base = "The description is in context in every session, used or not. The body only when the skill triggers. Estimated at four characters per token."
        guard item.budget.isOverBudget else { return base }
        return (item.budget.breaches + [base]).joined(separator: "\n")
    }

    // MARK: - Details card

    private func detailsCard(_ item: Item) -> some View {
        V2Card {
            VStack(spacing: 0) {
                cardHeader { V2CardCaption(text: "Details") }
                // The way out of a repository is offered once, in the callout above, where it can
                // be seen. Twice on one screen is not twice as findable.
                detailRow(label: "Source", value: sourceText(item), help: sourceHelp(item))
                detailRow(label: "Usage", value: usageValue(item), help: usesHelp(item))
                detailRow(label: "Last used", value: lastUsedValue(item), help: lastUsedHelp(item))
                // An MCP server has no file of its own: it is a few lines inside `~/.claude.json`,
                // and pointing at the directory that file sits in named the home folder, which is
                // not where anybody would go looking.
                if let location = locationPath(item) {
                    detailRow(
                        label: "Location", value: location, mono: true,
                        action: ("Reveal", { model.revealInFinder() }),
                        actionHint: "Reveal \(location) in Finder",
                        help: locationHelp(item)
                    )
                }
                // Only for something that owns a folder. On a command or an agent this listed the
                // neighbours in the same directory — other people's files, under this one's name.
                if let folder = item.directory {
                    let extras = folderContents(folder).filter { $0 != item.path?.lastPathComponent }
                    if !extras.isEmpty {
                        filesRow(extras)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// What is beside the document, counted when shut and spelled out when opened.
    ///
    /// It used to be one line of names run together, cut in the middle when they did not fit —
    /// which on a skill like `remotion-best-practices`, whose folder holds a dozen sibling
    /// skills, printed `remotion-int…on-multimedia/`: a name cut in half tells you nothing, and
    /// a row whose height depended on the folder pushed the document below it out of room.
    ///
    /// Shut it states the size, which is the thing you actually want at a glance. Opened, each
    /// entry is a chip in the same flow layout the filter bar uses, so names wrap onto a second
    /// line rather than being cut. Shut is the default, so the card's height no longer depends on
    /// what happens to be in the folder.
    @ViewBuilder
    private func filesRow(_ entries: [String]) -> some View {
        let folders = entries.filter { $0.hasSuffix("/") }.count
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Files")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.white.opacity(0.5))
                .frame(width: 74, alignment: .leading)
                .help("What else sits in this folder, beside the document")
            VStack(alignment: .leading, spacing: filesExpanded ? 8 : 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { filesExpanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text(filesSummary(entries.count, folders: folders))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.white.opacity(0.88))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(V2.textMid)
                            .rotationEffect(.degrees(filesExpanded ? 0 : -90))
                    }
                }
                .buttonStyle(.plain)
                .help(filesExpanded ? "Hide what is in the folder" : "Show what is in the folder")
                .pointingHand()

                if filesExpanded {
                    ChipFlow(spacing: 6, lineSpacing: 6) {
                        ForEach(entries, id: \.self) { entry in
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(V2.textMid)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.white.opacity(0.05))
                                )
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Hairline(color: Color.white.opacity(0.06)) }
    }

    /// "12 items · 3 folders" — the folder count only when there is one, since "0 folders" is a
    /// fact nobody asked for.
    private func filesSummary(_ total: Int, folders: Int) -> String {
        let items = count(total, of: "item")
        return folders > 0 ? "\(items) · \(count(folders, of: "folder"))" : items
    }

    /// The actions whose symbol needs no word beside it. "Reveal" was here and should not have
    /// been: the row beside it is a path, but a lone folder glyph at the far edge is not something
    /// an eye finds — the same mistake this file already records about "Make global".
    private static let glyphOnlyActions: Set<String> = ["Copy"]

    /// The glyph for a row's action. Named after what the action is, so a second action added
    /// later either finds its symbol here or falls back to something honest rather than wrong.
    private func symbol(forAction title: String) -> String {
        switch title {
        case "Reveal": return "folder"
        case "Make global": return "arrow.up.right.circle"
        case "Copy": return "doc.on.doc"
        default: return "arrow.up.forward.app"
        }
    }

    private func detailRow(
        label: String, value: String, mono: Bool = false,
        action: (String, () -> Void)? = nil, actionHint: String = "",
        help: String? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.white.opacity(0.5))
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                .foregroundStyle(mono ? V2.textMid : Color.white.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let (title, act) = action {
                // A glyph alone for the ones whose symbol is universal — a folder means reveal,
                // and the row beside it is already a path. Anything else says its verb: an action
                // nobody can name is an action nobody finds, which is exactly what happened to
                // "Make global" when it shipped as a lone arrow in a circle.
                Button(action: act) {
                    HStack(spacing: 5) {
                        Image(systemName: symbol(forAction: title))
                            .font(.system(size: 12.5))
                        if !Self.glyphOnlyActions.contains(title) {
                            Text(title)
                                .font(.system(size: 12))
                                .fitsOnOneLine()
                        }
                    }
                    .foregroundStyle(V2.link)
                }
                .buttonStyle(.plain)
                .help(actionHint.isEmpty ? title : actionHint)
                .accessibilityLabel(title)
                .pointingHand()
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Hairline(color: Color.white.opacity(0.06)) }
        // The row's own explanation covers the label and the value; the action keeps the tooltip
        // it already had, since a button has to say what it does rather than what it shows.
        .help(help ?? "\(label): \(value)")
    }

    /// The chosen window without its article, for reading inside brackets and after "None in".
    private var windowSuffix: String {
        model.usageWindowLabel.replacingOccurrences(of: "the ", with: "")
    }

    private func usageValue(_ item: Item) -> String {
        // "Never used" claimed more than the numbers can: they cover the window chosen in Settings
        // › Usage, not all time. So the value says which window it looked at.
        guard !item.usage.neverUsed else { return "None in \(windowSuffix)" }
        return "\(uses(item.usage.count)) in \(count(item.usage.projectCount, of: "project"))"
    }

    /// "1 use" / "4 uses" — the phrase the Details row, the rail's Uses pair and every project
    /// row all print. One spelling, so the same number never reads two ways in one pane.
    private func uses(_ count: Int) -> String { self.count(count, of: "use") }

    private func count(_ number: Int, of noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }

    private func lastUsedValue(_ item: Item) -> String {
        // The window is a setting, so writing 90 days here said 90 days to somebody who had chosen
        // 30 — the row contradicting the preference that produced it.
        guard item.usage.count > 0, let last = item.usage.lastUsed else {
            return "— (\(windowSuffix))"
        }
        return Usage.relative(last)
    }

    /// A date here is the newest activation the histories could prove, and a dash is not the same
    /// thing as never: it can also mean no history Loadout can read covers this one.
    private func lastUsedHelp(_ item: Item) -> String {
        guard item.usage.count > 0, item.usage.lastUsed != nil else {
            return "Nothing in \(model.usageWindowLabel) proves this ran. Settings › Usage says which histories could be read and which formats prove nothing."
        }
        return "The most recent time an assistant fired this \(item.kind.briefingNoun), out of \(model.usageWindowLabel)"
    }

    /// Where it lives decides where it works, which is the part the words "Personal", "in a
    /// repository" and "from a plugin" leave out.
    private func sourceHelp(_ item: Item) -> String {
        let noun = item.kind.briefingNoun
        switch item.origin {
        case .personal:
            return "Yours, in your home folder, so every project can load this \(noun)"
        case .project(let name):
            if item.declaredByRepository {
                return """
                Committed in \(name), so everyone who checks it out gets it. Switching it off is \
                recorded in your own settings and changes nothing for anybody else
                """
            }
            return "Lives inside \(name), so it loads only while you work in that repository"
        case .plugin(let name):
            return "Comes with the \(name) plugin, so updating the plugin can replace this \(noun)"
        }
    }

    private func locationHelp(_ item: Item) -> String {
        if item.kind == .mcp {
            return "The settings file this server is defined in, a few lines among the assistant's other settings"
        }
        return item.directory == nil
            ? "The folder on disk the file sits in"
            : "The folder on disk that holds this \(item.kind.briefingNoun)"
    }

    private func fileSize(_ item: Item) -> String? {
        guard let path = item.path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let bytes = attributes[.size] as? Int
        else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Everything beside the markdown, folders marked with a trailing slash. Resolves symlinks
    /// first: several real skills are links into a shared `.agents/skills` tree, and listing
    /// a link's contents without resolving it returns nothing at all.
    private func folderContents(_ folder: URL) -> [String] {
        let fm = FileManager.default
        let target = folder.resolvingSymlinksInPath()
        guard let entries = try? fm.contentsOfDirectory(
            at: target, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .map { url -> String in
                var isDirectory: ObjCBool = false
                _ = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
                return url.lastPathComponent + (isDirectory.boolValue ? "/" : "")
            }
            .sorted()
    }

    private func displayPath(_ url: URL) -> String {
        url.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"
        )
    }

    // MARK: - Assistants card

    private func assistantsCard(_ item: Item) -> some View {
        let assistants = model.visibleAssistants
        let loaded = assistants.filter { item.assistants.contains($0.id) }.count
        return V2Card {
            VStack(spacing: 0) {
                cardHeader {
                    HStack(spacing: 8) {
                        V2CardCaption(text: "Assistants")
                        Text("\(loaded) loaded of \(assistants.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(V2.textFaint)
                            .help("How many of the assistants below have this skill, out of the ones Loadout found on this Mac and Settings keeps in view")
                    }
                }
                // Four up is the design's shape, but only while a cell has room for a name and a
                // verb beside it. Below that it drops to two and then to one, because a squeezed
                // four-up turns "loaded" into three stacked letters.
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 0), count: assistantColumns
                    ),
                    spacing: 0
                ) {
                    ForEach(assistants) { assistant in
                        assistantCell(assistant, item: item)
                    }
                }
            }
        }
    }

    /// One cell needs about 200pt before the label starts truncating into initials.
    private var assistantColumns: Int {
        if cardWidth >= 800 { return 4 }
        if cardWidth >= 400 { return 2 }
        return 1
    }

    /// How wide a card actually is: the pane, less the margins the stack holds them in. Every
    /// decision about what fits on a card is about this number, not about the pane's own width.
    private var cardWidth: CGFloat { paneWidth - Self.cardMargins * 2 }
    private static let cardMargins: CGFloat = 24

    private func assistantCell(_ assistant: Assistant, item: Item) -> some View {
        let has = item.assistants.contains(assistant.id)
        let none = !has && !assistant.hasSkillsFolder
        return Button {
            model.setAssistant(assistant, on: item, present: !has)
        } label: {
            HStack(spacing: 9) {
                AssistantMark(assistant: assistant, present: has || !none, size: 20)
                Text(assistant.label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.white.opacity(none ? 0.4 : 0.88))
                    .lineLimit(1)
                    .fixedSize()
                // Beside the name, not out in the state column: it belongs to this assistant,
                // and against the column it read as part of the word next to it.
                if let count = assistantUsage[assistant.id], count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(V2.textFaint)
                        .fitsOnOneLine()
                }
                Spacer(minLength: 6)
                // One glyph per state, all the same size and shape, so the column reads as a
                // column. Colour still carries the meaning at a distance — the healthy hue for
                // carried, the link hue for available, grey for nothing to carry it with — and
                // the words move to the tooltip, where the space is free. It also stops "loaded"
                // from stacking into three letters when the grid squeezes to four up.
                Image(systemName: has ? "checkmark.circle.fill" : (none ? "minus.circle" : "plus.circle"))
                    .font(.system(size: 13))
                    .foregroundStyle(has ? V2.ok : (none ? V2.muted : V2.link))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) { Hairline(color: Color.white.opacity(0.06)) }
            .overlay(alignment: .trailing) { Hairline(color: Color.white.opacity(0.06), vertical: true) }
            .contentShape(Rectangle())
            // On the content, not on the Button around it. A plain-styled button hands its
            // tracking area to the label, and a tooltip hung outside that never fires — which is
            // why no cell in this grid had one, whatever it showed.
            .help(assistantHelp(assistant, has: has))
        }
        .buttonStyle(.plain)
        .pointingHand()
        .spotlight(Spotlight.assistant(assistant.id))
    }

    private func assistantHelp(_ assistant: Assistant, has: Bool) -> String {
        let count = assistantUsage[assistant.id] ?? 0
        let fired = count > 0
            ? "\(assistant.label) fired it \(uses(count)) in \(model.usageWindowLabel). "
            : ""
        if has {
            // The glyph says carried; the tooltip is where "loaded" now lives in words.
            return "Loaded in \(assistant.label). " + fired
                + "Click to stop \(assistant.label) from loading this skill."
        }
        if assistant.hasSkillsFolder {
            // The one that reads as a contradiction until it is spelled out: used, not loaded.
            let past = count > 0 ? "It isn't loaded there now. " : ""
            return fired + past + "Click to add this skill to \(assistant.label)."
        }
        return "\(assistant.label) doesn't have a skills folder yet. Click to create \(assistant.skillsRoot.path) and add this skill."
    }

    // MARK: - Document card

    /// Whether the bar above the document has anything in it. On a server the repository ships,
    /// everything it can hold is gone — no Preview/Edit, no reader, no Ask, no budget chip, no
    /// Remove — and drawing it anyway left an empty band with a hairline under it.
    private func showsDocumentToolbar(_ item: Item) -> Bool {
        item.kind != .mcp || model.canRemove(item)
    }

    private func documentCard(_ item: Item, rendersBody: Bool) -> some View {
        V2Card {
            VStack(spacing: 0) {
                if showsDocumentToolbar(item) {
                    documentToolbar(item)
                    Hairline(color: Color.white.opacity(0.08))
                }
                if rendersBody {
                    documentBody(item)
                } else {
                    // Same footprint as the reader, so admitting the document never moves the
                    // cards above it or causes a second window-level layout jump.
                    Color.clear.frame(height: documentBodyHeight)
                }
            }
        }
    }

    /// The bar gives up the budget chip first — the same two numbers sit in the Token budget card
    /// a few points above — and then the ⌘S hint on Save. What it never gives up is a control:
    /// truncating "Revert" to "R" is worse than not showing a duplicate line count.
    private func documentToolbar(_ item: Item) -> some View {
        ViewThatFits(in: .horizontal) {
            toolbarRow(item, chip: true, shortcut: true)
            toolbarRow(item, chip: false, shortcut: true)
            toolbarRow(item, chip: false, shortcut: false)
        }
    }

    private func toolbarRow(_ item: Item, chip: Bool, shortcut: Bool) -> some View {
        HStack(spacing: 8) {
            // Reading or editing: one segmented switch, because they are the same document
            // in two modes. A server has no document and nothing to edit, so it gets neither
            // segment — offering Edit there was a control that could only disappoint.
            if item.kind != .mcp {
                HStack(spacing: 1) {
                    viewModeTab("Preview", selected: model.showsPreview) { model.showsPreview = true }
                    // The dot is the unsaved marker the design asks for on the Edit segment
                    // itself, so the state is visible even while reading the preview.
                    viewModeTab(model.isDirty ? "Edit •" : "Edit", selected: !model.showsPreview) {
                        model.showsPreview = false
                    }
                }
                .padding(2)
                .background(V2.well, in: RoundedRectangle(cornerRadius: 7))
            }

            // Reading before asking: Aa belongs with the Preview/Edit switch it modifies.
            if model.showsPreview, item.kind != .mcp {
                readerButton
            }

            if item.isEditable {
                askButton
            }

            Spacer(minLength: 8)

            // Same reason the card above is gone on a server: there is no body to count lines of.
            if chip, showsBudget(item) {
                budgetChip(item)
            }

            // The one destructive thing a server has. It is here rather than only in the row's
            // context menu because a menu nobody opens is not where a person looks for it.
            if model.canRemove(item) {
                Button("Remove") { model.isConfirmingDelete = true }
                    .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                    .help("Take this server out of the assistant's settings. There is no Trash for it, so Loadout copies the file to its backups first")
                    .pointingHand()
            }

            if item.isEditable {
                Button("Revert") { model.revert() }
                    .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: model.isDirty))
                    .disabled(!model.isDirty)
                    .help("Throw away the unsaved changes and reload the file from disk")
                    .pointingHand(enabled: model.isDirty)
                Button {
                    model.save()
                } label: {
                    HStack(spacing: 6) {
                        Text("Save")
                        if shortcut {
                            Text("⌘S")
                                .font(.system(size: 11))
                                .opacity(0.6)
                        }
                    }
                }
                .buttonStyle(V2ToolbarButtonStyle(prominent: true, enabled: model.isDirty))
                .disabled(!model.isDirty)
                .keyboardShortcut("s", modifiers: .command)
                .help("Write your changes to the file on disk (⌘S)")
                .pointingHand(enabled: model.isDirty)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    private func viewModeTab(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        V2SegmentTab(label: name, selected: selected, action: action)
            .help(name.hasPrefix("Preview") ? "Read the document as rendered Markdown" : "Edit the raw file")
    }

    /// The body's line count against the documented limit, always in view while editing —
    /// in the healthy hue while inside, amber the moment the file crosses the line.
    private func budgetChip(_ item: Item) -> some View {
        let over = item.budget.bodyLines > Budget.maxBodyLines
        let color = over ? V2.amber : V2.ok
        return HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.system(size: 10))
            Text("\(item.budget.bodyLines) / \(Budget.maxBodyLines) lines")
                .monospacedDigit()
        }
        .font(.system(size: 11.5))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.28), lineWidth: 0.5))
        .help(budgetHelp(item))
    }

    /// Safari Reader's pattern: one quiet Aa button, and the three reading choices live in
    /// its popover — never as loose sliders on the bar.
    private var readerButton: some View {
        Button("Aa") { readerPopoverOpen.toggle() }
            .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
            .help("Reading size, typeface and background")
            .pointingHand()
            .popover(isPresented: $readerPopoverOpen, arrowEdge: .bottom) {
                readerPopover
            }
            .onAppear {
                // The screenshot hook again — presented after the window settles, since a
                // popover asked for before its anchor has laid out never shows at all.
                if ProcessInfo.processInfo.environment["LOADOUT_OPEN"] == "reader" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { readerPopoverOpen = true }
                }
            }
    }

    private var readerPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button("A") { readerFontSize = max(13, readerFontSize - 1) }
                    .font(.system(size: 11))
                    .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: readerFontSize > 13))
                    .pointingHand(enabled: readerFontSize > 13)
                Slider(value: $readerFontSize, in: 13...20, step: 0.5)
                    .controlSize(.small)
                    .tint(V2.accent)
                    .pointingHand()
                Button("A") { readerFontSize = min(20, readerFontSize + 1) }
                    .font(.system(size: 15))
                    .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: readerFontSize < 20))
                    .pointingHand(enabled: readerFontSize < 20)
                Text("\(readerFontSize, specifier: "%.0f") pt")
                    .font(.system(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(V2.textDim)
                    .frame(width: 36, alignment: .trailing)
            }
            readerSegments(
                options: [("system", "System"), ("serif", "Serif"), ("mono", "Mono")],
                selection: $readerFont,
                help: "The typeface the document is read in"
            )
            readerSegments(
                options: [("dark", "Dark"), ("darker", "Darker"), ("ink", "Ink")],
                selection: $readerBackground,
                help: "How dark the page behind the text is, Ink being the darkest"
            )
        }
        .padding(12)
        .frame(width: 280)
        .background(V2.popover)
    }

    private func readerSegments(
        options: [(String, String)], selection: Binding<String>, help: String
    ) -> some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.0) { value, label in
                V2SegmentTab(label: label, selected: selection.wrappedValue == value) {
                    selection.wrappedValue = value
                }
                .frame(maxWidth: .infinity)
                // On each segment rather than the row: "Ink" and "Darker" name a shade nobody can
                // rank on sight, and the row's own tooltip never reaches the segments' hit areas.
                .help(help)
            }
        }
        .padding(2)
        .background(V2.well, in: RoundedRectangle(cornerRadius: 7))
    }

    /// One button when exactly one assistant CLI is installed, a menu when there's a choice,
    /// and a disabled button naming what it's looking for when there's none.
    @ViewBuilder
    private var askButton: some View {
        // Only the assistants Loadout can actually hold a conversation with. Offering one it
        // can't would be a menu entry that opens a window and then apologises.
        let clis = model.askableCLIs
        if clis.isEmpty {
            Button {} label: { askLabel }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: false))
                .disabled(true)
                .help("Looks for \(AssistantCLIRegistry.chatCapableLabels.joined(separator: " or ")) on your PATH — neither is installed.")
        } else if let only = clis.count == 1 ? clis.first : nil {
            Button { model.askAssistant(only) } label: { askLabel }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                .help(askHelp(only))
                .pointingHand()
        } else {
            Menu {
                ForEach(clis) { cli in
                    Button(cli.label) { model.askAssistant(cli) }
                }
            } label: {
                askLabel
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            // Inside the pill's padding on purpose: a borderless menu hit-tests only its own label,
            // so the 10pt of pill either side is decoration, and the hand must not claim otherwise.
            .pointingHand()
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(V2.button, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .help("Ask an assistant about this skill. Nothing is written until you accept a change and save.")
            .pointingHand()
        }
    }

    /// The button says which of the two things it does, because they are not the same promise: a
    /// conversation can change the file once you accept a change, and the one-shot sheet cannot.
    private func askHelp(_ cli: AssistantCLI) -> String {
        AskModel.canChat(cli)
            ? "Talk to \(cli.label) about this skill, beside the document. It works in a copy of the folder, so your file changes only when you accept a change and save."
            : "Ask \(cli.label) one question about this skill. It answers as text and writes nothing."
    }

    private var askLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(V2.link)
            Text("Ask")
                .font(.system(size: 12))
        }
    }

    // MARK: Document body

    @ViewBuilder
    private func documentBody(_ item: Item) -> some View {
        if item.kind == .mcp {
            // One of these is in a file of its own and the other is not, so the sentence cannot be
            // the same. Saying "~/.claude.json" over a server that came out of a repository's
            // `.mcp.json` pointed at the wrong file and read as the app not knowing where it was.
            Text(item.declaredByRepository
                ? "This server comes from the .mcp.json the repository commits, so everyone who checks it out gets it. Switching it off is recorded in your own settings and changes nothing for anybody else."
                : "This server is defined in ~/.claude.json, not in a separate file.")
                .font(.system(size: 12.5))
                .foregroundStyle(V2.textMid)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.showsPreview {
            readingArea(item)
        } else if item.isEditable {
            VStack(spacing: 0) {
                if model.reviewLayout != nil {
                    reviewBanner
                }
                ZStack(alignment: .topTrailing) {
                    MarkdownEditor(
                        text: $model.draft,
                        original: model.diskDraft,
                        review: model.reviewLayout,
                        onReviewFrames: { reviewFrames = $0 },
                        onEdit: { model.isDirty = true },
                        onState: { editorState = $0 }
                    )
                    // Each undecided change gets its pair of buttons at its own height, so the
                    // decision is taken where the change is rather than in a list somewhere else.
                    ForEach(reviewFrames.sorted(by: { $0.value.minY < $1.value.minY }), id: \.key) { block, rect in
                        reviewControls(block: block)
                            .offset(y: max(2, rect.minY + 2))
                            .padding(.trailing, 14)
                    }
                }
                // As tall as the pane has left — the buffer scrolls inside the editor, and the
                // status bar under it comes out of the same allowance rather than off the end.
                .frame(height: max(120, documentBodyHeight - Self.editorStatusBarHeight))
                .clipped()
                editorStatusBar(item)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("This comes from a plugin, so it's read-only.", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(V2.textDim)
                ScrollView {
                    Text(model.draft)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 300)
            }
            .padding(16)
        }
    }

    // MARK: Reviewing the assistant's changes

    /// Says what the buffer is, because it is not the file: it holds both sides of every undecided
    /// change, and typing is off until they are decided.
    private var reviewBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(V2.link)
            Text(model.ask.pendingCount == 1
                 ? "1 proposed change — accept or reject it to keep editing"
                 : "\(model.ask.pendingCount) proposed changes — decide them to keep editing")
                .font(.system(size: 11))
                .foregroundStyle(V2.text)
            Spacer(minLength: 6)
            Button("Accept all") { model.acceptAllReviewChanges() }
                .buttonStyle(V2ToolbarButtonStyle(prominent: true, enabled: true))
                .help("Take every proposed change into the document (you still have to save)")
                .pointingHand()
            Button("Reject all") { model.rejectAllReviewChanges() }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                .help("Drop every proposed change and leave the file as it is")
                .pointingHand()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(V2.link.opacity(0.10))
        .overlay(alignment: .bottom) { Rectangle().fill(V2.hairline).frame(height: 0.5) }
    }

    private func reviewControls(block: Int) -> some View {
        HStack(spacing: 4) {
            Button("Reject") { model.rejectReviewChange(block) }
                .buttonStyle(V2ToolbarButtonStyle(prominent: false, enabled: true))
                .help("Leave the file as it is here")
                .pointingHand()
            Button("Accept") { model.acceptReviewChange(block) }
                .buttonStyle(V2ToolbarButtonStyle(prominent: true, enabled: true))
                .help("Take this change into the document (you still have to save)")
                .pointingHand()
        }
        .padding(3)
        .background(V2.popover, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(V2.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }

    // MARK: Reading area and rail

    /// Text plus rail. The reading measure belongs to reading, not to the window, so a wide
    /// pane can't be spent on longer lines — but it needn't be spent on nothing either: the
    /// width the text refuses goes to a rail holding what you would otherwise have to scroll
    /// away from. Under the breakpoint there is no room for both and the text stands alone.
    private func readingArea(_ item: Item) -> some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                // Both rails sit outside the scroller, so they hold still while the document moves —
                // no sticky offsets, no measuring, nothing chasing a viewport.
                tickRail { heading in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(
                            heading.id == headings.first?.id
                                ? DocumentAnchor.frontmatter
                                : DocumentAnchor.heading(heading.id),
                            anchor: .top
                        )
                    }
                }
                    .frame(width: Self.tickRailGutter, alignment: .leading)
                    // Above the page, not behind it. The rail is the earlier sibling, so without this
                    // the card it opens — which reaches into the page by design — was drawn under the
                    // page's own ground and never seen.
                    .zIndex(1)
                page(item)
            }
        }
        // As tall as the pane has left and no taller, the way the editor already is: the document
        // scrolls inside the card instead of taking the header and the fact cards up with it.
        .frame(height: readingHeight)
        .padding(Self.readingInset)
    }

    /// The width the reading area has to lay out in: the card, less its own inset and the strip
    /// the ticks are pinned to.
    private var readingWidth: CGFloat {
        cardWidth - Self.readingInset * 2 - Self.tickRailGutter
    }

    private func page(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: showsRail ? Self.railGap : 0) {
            ScrollView {
                MarkdownView(
                    text: model.draft, fontSize: readerFontSize, design: readerDesign,
                    proseWidth: column
                )
                    .frame(maxWidth: column, alignment: .leading)
                    .padding(.vertical, 18)
                    // On the content: a heading's offset in here is its offset down the document,
                    // and holds still while scrolling.
                    .coordinateSpace(readingContentSpace)
                    .background(PaneScroller { paneScroller = $0 })
            }
            .coordinateSpace(readingViewportSpace)
            // No second bar down the middle of the window. The page keeps the one scroller the eye
            // expects, and what says where you are inside the document is the tick rail — which is
            // the whole reason it grew a funnel.
            .scrollIndicators(.hidden)
            .frame(maxWidth: column)
            .id(item.id)
            if showsRail {
                // The rail gets a scroller of its own rather than a height it may exceed. Its
                // outline and its project list both grow with the document, and a column that
                // asks for more than the card has does not push anything aside — SwiftUI centres
                // it in the frame it was given and lets it draw outside, over the toolbar above
                // and past the card below. Scrolling is what turns the height into a fact.
                ScrollView {
                    readingRail(item)
                }
                .scrollIndicators(.hidden)
                .frame(width: Self.railWidth)
                .padding(.vertical, 18)
            }
        }
        // The sheet takes the whole card, and it is the document that fills it — the rail and the
        // margins keep the widths the design drew them at, and everything past those goes to the
        // text. It used to be the other way round: the text held a fixed measure and the leftover
        // width was spent on nothing, which is what left a sheet of paper floating in a band of
        // window on either side.
        .padding(.horizontal, Self.readingPadding)
        .background(readerGround, in: RoundedRectangle(cornerRadius: 10))
        // Fills what is left after the ticks' strip, so the ticks stay pinned to the leading edge
        // at every width instead of travelling inwards with the page.
        .frame(maxWidth: .infinity)
    }

    /// How wide the document itself is drawn: everything the reading area has, less the rail and
    /// the sheet's margins.
    ///
    /// No cap. The 84-character measure is still the *floor* — it is what the rail has to leave
    /// standing to be allowed to exist at all — but above that the width belongs to the document,
    /// because the alternative is what this replaced: a fixed column and a band of empty sheet
    /// beside it. Never below a readable minimum, so a pane dragged narrow crushes nothing.
    private var column: CGFloat {
        let rail = showsRail ? Self.railGap + Self.railWidth : 0
        return max(Self.narrowestColumn, readingWidth - Self.readingPadding * 2 - rail)
    }

    /// Under this the document is no longer a document, and the pane would rather clip than keep
    /// shrinking it — the same bargain `minimumWidth` makes for the pane as a whole.
    private static let narrowestColumn: CGFloat = 260

    /// The ticks, at the top of the reading area rather than centred in it: the first mark starts
    /// level with the top of the sheet beside it, and the column reads as a ruler down the page
    /// instead of a thing floating in the middle of it.
    private func tickRail(onJump: @escaping (DocumentHeading) -> Void) -> some View {
        TickRail(
            headings: headings,
            active: activeIndex,
            // What the strip may actually occupy: the reading area, less the inset it starts on.
            // The ticks size themselves from this, so it has to be the room they really have.
            available: readingHeight - Self.railTopInset,
            offsets: headingOffsets,
            pageTop: 0,
            onJump: onJump,
            onScrub: { offset in paneScroller?.scrollDocument(to: offset) },
            estimatedOffset: { heading in
                heading.progress * (paneScroller?.documentView?.bounds.height ?? 0)
            }
        )
        .padding(.top, Self.railTopInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The inset the ticks start on: none.
    ///
    /// They used to start on the same 18pt the text is inset by, on the theory that the first mark
    /// should be level with the document's first line. It isn't what the eye judges — beside a
    /// sheet of paper, the column of marks is read against the *top of the sheet*, and 18 points of
    /// nothing above the first mark reads as the ruler having slipped down.
    private static let railTopInset: CGFloat = 0

    /// The active heading as a position in the outline rather than its id, which is what the ticks
    /// count in — the frontmatter's mark is not a heading and has no heading number.
    private var activeIndex: Int {
        guard let activeHeading,
              let index = headings.firstIndex(where: { $0.id == activeHeading })
        else { return 0 }
        return index
    }

    /// The rail is Fluida's whole point, and even there it has to earn its place: the prose
    /// measure, the gutter, the rail and the reading surface's own padding all have to fit inside
    /// the card before the rail is allowed to exist.
    ///
    /// The 84-character measure is what it is tested against, and it is the only place that number
    /// still decides anything: above the threshold the document takes whatever width there is, but
    /// the rail may never be what pushes the text below a comfortable line. Derived from the
    /// reading size rather than fixed, so it tracks the Aa panel's larger sizes — at the default
    /// 15pt it works out at 1172pt of pane, within eight points of the 1180 the design asked for.
    private var showsRail: Bool {
        cardWidth >= proseColumn + Self.railGap + Self.railWidth + Self.readingPadding * 2
    }

    private var proseColumn: CGFloat {
        MarkdownView.width(fontSize: readerFontSize, characters: MarkdownView.proseCharacters)
    }
    private static let railWidth: CGFloat = 264
    private static let railGap: CGFloat = 64
    /// The sheet's own margin, left and right of everything on it.
    ///
    /// Wider than it was: at 20 the text sat almost against the edge of the paper, which reads as
    /// a document that overflowed rather than one that was placed. It comes out of the text's
    /// width, which is now the width that has room to give.
    private static let readingPadding: CGFloat = 32
    private static let tickRailGutter: CGFloat = 52

    private func readingRail(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if !headings.isEmpty {
                railOnThisPage
                railRule
            }
            railMetadata(item)
            railRule
            railUsedIn(item)
            Spacer(minLength: 0)
        }
        .frame(width: Self.railWidth, alignment: .leading)
    }

    /// Where a section starts, for either rail to jump to. The first entry goes to the very top:
    /// above it is the frontmatter's own margin, and stopping short of that reads as a failed jump.
    private func destination(of heading: DocumentHeading) -> CGFloat {
        guard heading.id != headings.first?.id else { return 0 }
        return max(0, (headingOffsets[heading.id] ?? 0) - Self.readingTopInset)
    }

    static let readingTopInset: CGFloat = 24

    private var railRule: some View {
        Hairline(color: V2.hairlineSoft).padding(.vertical, 9)
    }

    // MARK: On this page

    private var railOnThisPage: some View {
        VStack(alignment: .leading, spacing: 7) {
            V2CardCaption(text: "On this page", size: 10.5, weight: .medium, color: V2.textFaint)
            ForEach(headings) { heading in
                railHeadingRow(heading)
            }
        }
    }

    private func railHeadingRow(_ heading: DocumentHeading) -> some View {
        // Before the reader has passed anything, the first entry stands for where they are.
        let active = heading.id == (activeHeading ?? headings.first?.id)
        return Button {
            // The same destination the ticks use, so the two readings of the outline can't disagree
            // about where a section starts.
            paneScroller?.scrollDocument(to: destination(of: heading), animated: true)
        } label: {
            Text(heading.title)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(active ? 0.92 : 0.42))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Every row carries the indent, active or not, so arriving at a section
                // lights its marker instead of nudging the text sideways.
                .padding(.leading, 9 + CGFloat(heading.level - 1) * 8)
                .padding(.vertical, 1)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(V2.accent)
                        .frame(width: 2)
                        .opacity(active ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(heading.title)
        .pointingHand()
    }

    // MARK: Metadata pairs

    private func railMetadata(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            railPair(
                "Modified", item.modified.map { Usage.relative($0) } ?? "—",
                help: "When the file on disk last changed"
            )
            railPair(
                "Uses", item.usage.neverUsed ? "None in \(windowSuffix)" : uses(item.usage.count),
                help: usesHelp(item)
            )
            railPair("Source", sourceText(item), help: sourceHelp(item))
        }
    }

    /// What the number actually counts. It used to read Claude Code alone; now that it adds up
    /// several assistants over a window the person chose, "1 use" on its own is a riddle.
    private func usesHelp(_ item: Item) -> String {
        let assistants = model.countedAssistantLabels
        let counted = assistants.count > 1
            ? assistants.dropLast().joined(separator: ", ") + " and " + assistants[assistants.count - 1]
            : assistants.joined()
        let scope = "Counts proven activations by \(counted), in \(model.usageWindowLabel)."

        guard !item.usage.neverUsed else {
            return scope + " This one has none — check Settings › Usage for which histories could be read."
        }
        let ordered = assistantUsage.sorted { left, right in
            left.value == right.value ? left.key < right.key : left.value > right.value
        }
        let breakdown = ordered.map { entry -> String in
            let label = model.assistants.first { $0.id == entry.key }?.label ?? entry.key
            return "\(label): \(entry.value)"
        }.joined(separator: ", ")
        let where_ = breakdown.isEmpty ? "" : " — \(breakdown)."
        return "\(uses(item.usage.count)) in \(count(item.usage.projectCount, of: "project"))\(where_) \(scope)"
    }

    private func railPair(_ label: String, _ value: String, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(help ?? "\(label): \(value)")
    }

    // MARK: Used in

    private func railUsedIn(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            V2CardCaption(text: "Used in", size: 10.5, weight: .medium, color: V2.textFaint)
                .help("The projects this fired in, busiest first, over \(model.usageWindowLabel)")
            if projectUsage.isEmpty {
                Text("No recorded uses")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .help("No project in \(model.usageWindowLabel) has a record of this running. Settings › Usage says which histories could be read and which formats prove nothing.")
            } else {
                ForEach(projectUsage) { usage in
                    railProjectRow(usage)
                }
                // The Details card in this same pane says "in N projects", so a silently
                // truncated list reads as a contradiction rather than as a top eight.
                if item.usage.projectCount > projectUsage.count {
                    Text("+\(item.usage.projectCount - projectUsage.count) more")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.35))
                        .padding(.leading, 19)
                        .help("The list stops at the eight projects that used it most")
                }
            }
        }
    }

    private func railProjectRow(_ usage: ProjectUsage) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(V2.textFaint)
            Text(usage.project)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(usage.count)")
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(V2.textFaint)
        }
        .help("\(uses(usage.count)) in \(usage.project), over \(model.usageWindowLabel)")
    }

    /// The design's editor footer: where the caret is, how big the buffer is, whether it is
    /// saved, what it costs in tokens, and how many live issues the validator sees.
    private func editorStatusBar(_ item: Item) -> some View {
        let liveBudget = Budget.measure(document: model.draft)
        return HStack(spacing: 14) {
            Text("Ln \(editorState.line), Col \(editorState.column)")
                .help("Where the cursor is — line, then column")
            Text("\(model.draft.components(separatedBy: "\n").count) lines")
                .help("Lines in the whole file, frontmatter included. The budget counts only the body, so its number is smaller.")
            Text("Markdown")
            Text("UTF-8")
            Spacer()
            if !editorState.issues.isEmpty {
                Text("\(editorState.issues.count) \(editorState.issues.count == 1 ? "issue" : "issues")")
                    .foregroundStyle(V2.issue)
                    .help(editorState.issues.map(\.message).joined(separator: "\n"))
            }
            Text("~\(liveBudget.descriptionTokens) tok desc · \(liveBudget.bodyLines)/\(Budget.maxBodyLines) lines")
                .foregroundStyle(liveBudget.isOverBudget ? V2.amber : V2.textDim)
                .help("Measured on what is in the editor now, not on the saved file: the description's tokens, and body lines against the recommended limit")
            Text(model.isDirty ? "Edited" : "Saved")
                .foregroundStyle(model.isDirty ? V2.amber : V2.textDim)
                .help(model.isDirty
                      ? "The editor holds changes that are not in the file yet"
                      : "The file on disk matches what is in the editor")
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(V2.textDim)
        .padding(.horizontal, 12)
        .frame(height: Self.editorStatusBarHeight)
        .background(V2.footer)
        .overlay(alignment: .top) { Hairline(color: Color.white.opacity(0.07)) }
    }

    // MARK: - Shared pieces

    private func cardHeader<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
            Spacer()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Hairline(color: Color.white.opacity(0.08)) }
    }

    private func icon(for kind: ItemKind) -> String {
        switch kind {
        case .skill: return "doc.text"
        case .command: return "terminal"
        case .agent: return "person.2"
        case .mcp: return "network"
        case .plugin: return "puzzlepiece.extension"
        }
    }
}

/// The document toolbar's buttons: quiet pill normally, accent-filled for the one primary
/// action, both fading out instead of vanishing while there is nothing to act on.
struct V2ToolbarButtonStyle: ButtonStyle {
    var prominent: Bool
    var enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            // "Revert" clipped to "R" is not a smaller button, it is a broken one. The bar around
            // it drops whole items instead of letting its labels dissolve.
            .fitsOnOneLine()
            .foregroundStyle(
                enabled ? (prominent ? Color.white : Color.white.opacity(0.85)) : Color.white.opacity(0.28)
            )
            .padding(.horizontal, prominent ? 12 : 11)
            .frame(height: 24)
            .background(
                enabled ? (prominent ? V2.accent : V2.button) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
                Color.white.opacity(enabled && prominent ? 0.14 : 0.08), lineWidth: 0.5
            ))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
