import SwiftUI

/// The document's outline as a column of dashes, with a card previewing whatever the pointer is
/// nearest. The compact form of "On this page", for panes with no room to spell it out.
///
/// The proportions, the falloff and the timings are Imark's, copied rather than re-derived. They
/// were tuned by hand there — its own note records the bell narrowing from 2.6, where "the third
/// tick either side still grew by half and the funnel read as a blunt bulge" — and re-deriving
/// them by eye would only arrive somewhere worse, slowly.
struct TickRail: View {
    /// H1 to H3 only, in document order. A mark has to be a place you can name, or the rail is
    /// texture rather than navigation.
    let headings: [DocumentHeading]
    /// Which heading the reader is in, as an index into `headings`.
    let active: Int
    /// The height the rail may spread over — the visible pane, not the document.
    let available: CGFloat
    /// Where each heading sits down the document, by heading index. Empty until the pane has laid
    /// out, in which case the rail still jumps but cannot scrub.
    let offsets: [Int: CGFloat]
    /// Where the reading page itself starts, down the document. The first mark goes here rather
    /// than to its own heading: everything above that heading — the frontmatter strip, the page's
    /// own top margin — is still the document, and stopping short of it reads as the jump failing.
    let pageTop: CGFloat
    /// A press: glide to this exact lazy-stack target. The proxy can materialize a heading that
    /// has not appeared yet, which avoids paying to lay the whole document out up front.
    let onJump: (DocumentHeading) -> Void
    /// A drag: put the document at this absolute offset, now, with no easing.
    let onScrub: (CGFloat) -> Void
    /// Until a lazy heading has appeared and published its exact offset, scrubbing uses its
    /// position in the document as a temporary estimate. A press never estimates.
    let estimatedOffset: (DocumentHeading) -> CGFloat

    /// Where the funnel is centred while the pointer is on the rail. Normally the centre follows
    /// the scroll; under the pointer it follows the hand, so you can look around the document
    /// before deciding to go there.
    @State private var hovered: Int?
    /// True from the press until the release. While it is, the hover follows the drag rather than
    /// the pointer's own tracking, and leaving the strip no longer clears the funnel.
    @State private var scrubbing = false

    // MARK: Imark's numbers

    /// How much of the pane the rail fills.
    private static let span: CGFloat = 0.72
    /// Between two headings. Every row is half of this, because a gradation sits in each gap.
    private static let pitchRange: ClosedRange<CGFloat> = 9...14
    private static let minorWidth: CGFloat = 4
    private static let minorOpacity: CGFloat = 0.15
    private static let minorAmplitude: CGFloat = 5
    /// Narrow on purpose: only the immediate neighbours grow clearly, and everything past them is
    /// back at rest.
    private static let sigma: CGFloat = 1.15
    /// How much longer the mark at the centre grows. Imark's 32 is for a rail out at a window's
    /// edge with nothing near it; against a page it reads as a lunge, so the whole scale here is
    /// smaller — the shape of the funnel is what carries, not its reach.
    private static let amplitude: CGFloat = 14
    /// The hit area's width, not the drawing's: a dash at the centre of the funnel runs past this,
    /// which is deliberate — the gutter it grows into is sized for it, and clipping the funnel to
    /// the hit area would flatten the shape at exactly its peak.
    private static let width: CGFloat = 28
    private static let dashInset: CGFloat = 8
    private static let cardWidth: CGFloat = 276
    /// The card clears the rail rather than sitting on it.
    private static let cardOffset: CGFloat = 46

    /// Rows are majors and gradations alternating, so the strip has no dead pixels between hit
    /// areas and the pointer-to-row arithmetic is exactly `y / row height`.
    private var rowCount: Int { max(0, headings.count * 2 - 1) }

    private var rowPitch: CGFloat {
        guard rowCount > 0 else { return Self.pitchRange.lowerBound / 2 }
        let ideal = available * Self.span / CGFloat(rowCount)
        // The comfortable minimum yields to the room there actually is. A strip held at its
        // floor past the point where the rows fit doesn't push the page down — it draws outside
        // the reading area, over whatever is above and below it. Tighter ticks are the lesser
        // fault, and it takes a document of forty-odd headings in a short window to reach this.
        let floor = min(Self.pitchRange.lowerBound / 2, available / CGFloat(rowCount))
        return min(Self.pitchRange.upperBound / 2, max(floor, ideal))
    }

    /// The row the funnel is centred on. A heading's row is at twice its index, the gradations
    /// filling the odd numbers between.
    private var centre: CGFloat {
        CGFloat(hovered ?? min(active, headings.count - 1) * 2)
    }

    /// A bell rather than a ramp with a cut-off, so the taper has no edge and the funnel reads as
    /// one soft shape however fast the pointer moves. Measured in headings, not rows.
    private func falloff(at row: Int) -> CGFloat {
        let distance = (CGFloat(row) - centre) / 2
        return exp(-(distance * distance) / (2 * Self.sigma * Self.sigma))
    }

    /// Headings stand slightly proud of one another, but only slightly: spread the resting widths
    /// too far and they compete with the funnel, and the rail reads as noise instead of one shape.
    private func restingWidth(_ level: Int) -> CGFloat { 8 + CGFloat(max(0, 3 - level)) * 2 }
    private func restingOpacity(_ level: Int) -> CGFloat { 0.34 + CGFloat(max(0, 3 - level)) * 0.06 }

    var body: some View {
        if headings.count >= 3 {
            rail
        }
    }

    private var rail: some View {
        VStack(spacing: 0) {
            ForEach(0..<rowCount, id: \.self) { row in
                dash(row)
            }
        }
        .frame(width: Self.width, alignment: .trailing)
        // Under the pointer the easing shortens rather than disappearing: none at all reads as
        // jitter, the full curve reads as lag.
        .animation(
            hovered == nil
                ? .timingCurve(0.16, 1, 0.3, 1, duration: 0.26)
                : .linear(duration: 0.09),
            value: centre
        )
        .overlay(alignment: .top) { card }
        .onContinuousHover { phase in
            guard case .active(let point) = phase, !scrubbing else {
                if !scrubbing { hovered = nil }
                return
            }
            hovered = row(at: point.y)
        }
        .gesture(scrub)
        // On the rail as a whole, not on each row: the rows are contiguous, so a hand per row would
        // push and pop the cursor stack every few points of travel to reach the same cursor.
        .pointingHand()
    }

    // MARK: Scrubbing

    /// Press to go to a heading, then keep dragging to take the page with you.
    ///
    /// The two do different things on purpose. A press snaps to the heading nearest the pointer and
    /// glides there — that is what a table of contents is for. A drag does *not* snap: it puts the
    /// page between the heading above and the one below in proportion, because snapping while
    /// dragging makes the page jump from section to section, which reads as the rail resisting the
    /// hand rather than following it.
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !headings.isEmpty else { return }
                hovered = row(at: value.location.y)
                if value.translation == .zero {
                    // The press itself.
                    scrubbing = true
                    onJump(headings[section(of: row(at: value.location.y))])
                } else {
                    onScrub(documentOffset(at: value.location.y))
                }
            }
            .onEnded { _ in scrubbing = false }
    }

    private func row(at y: CGFloat) -> Int {
        min(rowCount - 1, max(0, Int(y / rowPitch)))
    }

    /// A gradation belongs to the heading above it: it is a gradation, not a place of its own, and a
    /// row that swallows a press is worse than a row that isn't there.
    private func section(of row: Int) -> Int {
        min(headings.count - 1, row / 2)
    }

    /// Where the document should sit for a pointer anywhere along the rail, between headings as well
    /// as on them.
    private func documentOffset(at y: CGFloat) -> CGFloat {
        let at = min(max(y / rowPitch / 2, 0), CGFloat(headings.count - 1))
        let lower = Int(at.rounded(.down))
        let upper = min(lower + 1, headings.count - 1)
        let from = resolvedOffset(for: headings[lower])
        let to = resolvedOffset(for: headings[upper])
        return from + (to - from) * (at - CGFloat(lower)) - Self.topInset
    }

    private func resolvedOffset(for heading: DocumentHeading) -> CGFloat {
        if heading.id == headings.first?.id { return pageTop }
        return offsets[heading.id] ?? estimatedOffset(heading)
    }

    /// A heading landed flush against the top edge reads as clipped; Imark leaves the same 24.
    private static let topInset: CGFloat = 24

    private func dash(_ row: Int) -> some View {
        let minor = row % 2 == 1
        let heading = headings[section(of: row)]
        let weight = falloff(at: row)
        let base = minor ? Self.minorWidth : restingWidth(heading.level)
        let rest = minor ? Self.minorOpacity : restingOpacity(heading.level)
        let amplitude = minor ? Self.minorAmplitude : Self.amplitude
        let isActive = !minor && row == Int(centre)

        return Rectangle()
            // Monochrome, like the rest of the rail: the accent is loud enough to pull the eye
            // away from the text the marks are meant to be indexing.
            .fill(Color.white.opacity(rest + weight * (1 - rest)))
            .frame(width: base + weight * amplitude, height: isActive ? 3 : 2)
            .clipShape(Capsule())
            // Inset from the leading edge and growing inwards: the marks reach towards the text
            // they index rather than off the side of the page.
            .frame(width: Self.width - Self.dashInset, height: rowPitch, alignment: .leading)
            .frame(width: Self.width, alignment: .trailing)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var card: some View {
        if let row = hovered, !headings.isEmpty {
            let heading = headings[section(of: row)]
            // A zero-size anchor so the card centres on the row it belongs to, and glides between
            // rows instead of teleporting.
            Color.clear
                .frame(width: 0, height: 0)
                .overlay { tip(heading) }
                .offset(
                    x: Self.cardWidth / 2 + Self.cardOffset,
                    y: CGFloat(row) * rowPitch + rowPitch / 2
                )
                .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.22), value: row)
        }
    }

    private func tip(_ heading: DocumentHeading) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(Int(heading.progress * 100))% in".uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.7)
                .foregroundStyle(V2.textMid.opacity(0.75))
            Text(heading.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(V2.text)
                .lineLimit(2)
            if !heading.preview.isEmpty {
                Text(heading.preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(V2.textMid)
                    .lineLimit(3)
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 15)
        .padding(.bottom, 16)
        .frame(width: Self.cardWidth, alignment: .leading)
        // Solid, not translucent. Anything you can read through lets the document come straight
        // up into the card and neither one is legible — and this card is over text every time.
        .background(V2.popover, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(V2.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        .shadow(color: .black.opacity(0.34), radius: 16, y: 12)
        .allowsHitTesting(false)
    }
}
