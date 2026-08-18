import SwiftUI
import LoadoutCore

/// Getting the three fact cards out of the way, and the three ways of asking for it.
///
/// Token budget, Details and Assistants are worth reading once. After that they are 200-odd points
/// of chrome between the window's top and the document somebody opened the pane to read: on a
/// 1000pt window the first heading started in the bottom third. So they fold.
///
/// The name of the preference is `detailsCollapsed`, one answer for the whole app rather than one
/// per item. Per item, the pane would jump between two heights as the selection moved down the
/// list, and a control whose state changes when you select something else is a control nobody
/// trusts.
enum DetailsDisclosure {
    static let key = "detailsCollapsed"
    /// The easing the rest of the app collapses things with — the sidebar, the Files row, the
    /// Settings pane. A fold with its own timing reads as a different app for a sixth of a second.
    static let easing: Animation = .easeOut(duration: 0.16)

    /// Flips it from anywhere that isn't holding the `@AppStorage` — the menu command, the drive
    /// script. Written through `UserDefaults` because that is what `@AppStorage` is watching, the
    /// same way the sidebar's visibility is flipped from ⌘F.
    @MainActor
    static func toggle(_ defaults: UserDefaults = .standard) {
        defaults.set(!defaults.bool(forKey: key), forKey: key)
    }
}

/// The facts the cards hold, in the order the strip prints them.
///
/// Built by the pane rather than read from the item here, so the strip prints the very strings the
/// cards print — a summary that rounds a number the card spells out is a summary that gets
/// believed and is wrong.
struct DetailsSummary {
    var source: String
    var usage: String
    /// Nil on the kinds with no budget to report — an MCP server is a JSON entry, not a document.
    var tokens: String?
    var lines: String?
    var overBudget: Bool
    /// The assistants that load this, for the marks at the trailing edge.
    var assistants: [Assistant]
}

/// What the cards leave behind when they fold: one 32pt line carrying every number they were
/// showing, and the way back to them.
///
/// Hiding them outright was the obvious thing and the wrong one: the numbers are why the pane gets
/// opened, and a fold that takes them away makes people unfold it again immediately to check one
/// figure. The strip keeps the figures and doubles as the control.
struct DetailsSummaryStrip: View {
    let summary: DetailsSummary
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(V2.textDim)
                Text(summary.source)
                    .foregroundStyle(Color.white.opacity(0.72))
                    .fitsOnOneLine()
                fact(summary.usage)
                if let tokens = summary.tokens { fact(tokens, over: summary.overBudget) }
                if let lines = summary.lines { fact(lines, over: summary.overBudget) }
                Spacer(minLength: 8)
                // The same mark the rows and the Assistants grid draw, at the size the strip has
                // room for: the app's real icon where there is one, the brand monogram where there
                // isn't. Drawing letters here on purpose would make the strip the one place in the
                // window where Claude Code is two grey characters.
                ForEach(summary.assistants) { assistant in
                    AssistantMark(assistant: assistant, present: true, size: 17)
                }
            }
            // Tabular figures, because this line is read as a column of numbers against the cards
            // it replaced — proportional digits made "138 / 256" and "160 / 500" different widths.
            .font(.system(size: 11.5))
            .monospacedDigit()
            .padding(.horizontal, 13)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(V2.well, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(V2.hairline, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("Show the token budget, the details and the assistants again")
        .pointingHand()
    }

    private func fact(_ text: String, over: Bool = false) -> some View {
        Text(text)
            .foregroundStyle(over ? V2.amber : V2.textDim)
            .fitsOnOneLine()
    }
}

/// The quiet way in: a chip on the header's own line, right after the subtitle.
///
/// Beside the subtitle and not in the top-right corner of the header, where the first two people
/// to try this never looked — at 1920pt wide the right edge of the pane is most of a screen away
/// from the name being read.
struct DetailsChip: View {
    let collapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 12, weight: .medium))
                Text(collapsed ? "Show details" : "Hide details")
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(V2.textMid)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Bring the fact cards back (⌥⌘I)" : "Fold the fact cards away and give the document the room (⌥⌘I)")
        .pointingHand()
    }
}

/// The main affordance: the seam where the cards meet the document, made into a control.
///
/// This is where the hand already is — the eye is travelling from the last card down into the text,
/// and the gap between them is the thing being complained about. A hairline broken by a pill is the
/// design's own vocabulary for "there is a fold here", the double chevron says which way it moves,
/// and the word beside it removes the guess a bare glyph leaves behind: two testers read an
/// unlabelled chevron as "scroll down" and never pressed it.
///
/// The whole row is the target, hairlines included, not just the pill. A 20pt pill in the middle of
/// a 1400pt window is a dart-throw; the row is a 20pt band across the pane.
struct DetailsSeam: View {
    let collapsed: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Hairline(color: Color.white.opacity(0.07))
                HStack(spacing: 6) {
                    // Drawn rather than borrowed: `chevron.up.chevron.down` points both ways at
                    // once, which is exactly what this must not say. Two strokes with rounded caps,
                    // stacked, reading as a surface being pulled in one direction.
                    DoubleChevron(up: !collapsed)
                        .frame(width: 13, height: 9)
                    Text(collapsed ? "Show details" : "Hide details")
                        .font(.system(size: 11))
                }
                // White text on the neutral well, not the theme accent. Three loudnesses were drawn
                // and looked at: at `textMid` on a 62% row the control was there and nobody saw it,
                // and in the accent it carried the same weight as New skill and Remove plugin — an
                // action's weight, for a fold that gets opened and shut ten times an hour. This one
                // reads at a glance and stays chrome.
                .foregroundStyle(V2.text)
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(V2.well, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                Hairline(color: Color.white.opacity(0.07))
            }
            .frame(height: 20)
            // A tenth off until the hand is over it: enough to sit behind the document's first
            // heading in the reading order, not so much that the row has to be hunted for.
            .opacity(hovering ? 1 : 0.9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(collapsed ? "Bring the fact cards back (⌥⌘I)" : "Fold the fact cards away and give the document the room (⌥⌘I)")
        .pointingHand()
    }
}

/// The two chevrons of the seam's pill, pointing the way the cards will move.
struct DoubleChevron: View {
    let up: Bool

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            Path { path in
                for index in 0..<2 {
                    let top = h * (index == 0 ? 0.12 : 0.56)
                    let rise = h * 0.32
                    if up {
                        path.move(to: CGPoint(x: 0, y: top + rise))
                        path.addLine(to: CGPoint(x: w / 2, y: top))
                        path.addLine(to: CGPoint(x: w, y: top + rise))
                    } else {
                        path.move(to: CGPoint(x: 0, y: top))
                        path.addLine(to: CGPoint(x: w / 2, y: top + rise))
                        path.addLine(to: CGPoint(x: w, y: top))
                    }
                }
            }
            .stroke(style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
    }
}
