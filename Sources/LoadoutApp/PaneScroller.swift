import SwiftUI
import AppKit

/// Hands back the `NSScrollView` a SwiftUI `ScrollView` is built on.
///
/// `ScrollViewProxy` can only ever land on a view it has an id for, and scrubbing has to land the
/// page *between* two headings — so the rail needs to set an offset, which on macOS 14 means asking
/// AppKit. Reported when the view lands in a window rather than on the next run-loop hop, because a
/// view asked too early has no scroll view above it yet and there would be nothing to retry from.
struct PaneScroller: NSViewRepresentable {
    let found: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReportingView()
        view.report = found
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        var report: ((NSScrollView?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report?(enclosingScrollView)
        }
    }
}

extension NSScrollView {
    /// Scrolls to an absolute offset down the document.
    ///
    /// A scrub asks for no animation and means it: it follows the hand one to one, and anything
    /// easing underneath reads as the rail lagging behind the pointer. A press is the opposite —
    /// it jumps somewhere you weren't looking, and wants the glide to show you where it went.
    func scrollDocument(to y: CGFloat, animated: Bool = false) {
        let maximum = max(0, (documentView?.bounds.height ?? 0) - contentView.bounds.height)
        let target = NSPoint(x: 0, y: min(maximum, max(0, y)))
        guard animated else {
            contentView.scroll(to: target)
            reflectScrolledClipView(contentView)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(target)
        } completionHandler: { [weak self] in
            guard let self else { return }
            reflectScrolledClipView(contentView)
        }
    }
}
