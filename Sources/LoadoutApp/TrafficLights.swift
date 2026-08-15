import SwiftUI
import AppKit

/// Puts the system's window buttons on the custom bar's centre line.
///
/// macOS lays the traffic lights out for the 28pt title bar it believes it is drawing. The design's
/// bar is 52pt, so left alone the lights ride ten points above the sidebar toggle and the tabs they
/// are meant to line up with — measurable, and once seen, impossible to unsee.
///
/// The offset is computed from where the buttons actually are rather than from an assumed title bar
/// height, which makes it exact and also idempotent: applied a second time it computes a delta of
/// zero. It has to be reapplied, because AppKit puts them back on every relayout.
struct TrafficLights: NSViewRepresentable {
    /// The height of the custom bar the lights have to agree with.
    var barHeight: CGFloat

    func makeNSView(context: Context) -> NSView {
        // A view that reports when it lands in a window, rather than one asked once on the next
        // run-loop hop whether it has: if it hadn't, nothing retried and the lights stayed high
        // for the whole session. This also re-attaches if the view is ever rehosted.
        let view = HostedView()
        view.onWindow = { [coordinator = context.coordinator] window in
            coordinator.attach(to: window)
        }
        return view
    }

    private final class HostedView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(barHeight: barHeight) }

    /// Target/action registration rather than blocks, so `deinit` can unregister with one call
    /// instead of reaching into stored tokens it is not allowed to touch.
    @MainActor
    final class Coordinator: NSObject {
        private let barHeight: CGFloat
        private weak var window: NSWindow?

        init(barHeight: CGFloat) {
            self.barHeight = barHeight
            super.init()
        }

        /// Idempotent, because `viewDidMoveToWindow` fires on the way out as well as in: the same
        /// window twice is a no-op, and a different one takes its observers with it.
        func attach(to window: NSWindow?) {
            guard window !== self.window else { return }
            NotificationCenter.default.removeObserver(self)
            self.window = window
            guard let window else { return }
            centre()
            // The frame is not always final the moment the view lands in the window.
            DispatchQueue.main.async { [weak self] in self?.centre() }
            // Every one of these relays the title bar out from scratch.
            for name: Notification.Name in [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didExitFullScreenNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(relayout), name: name, object: window
                )
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func relayout() { centre() }

        private func centre() {
            guard let window,
                  let close = window.standardWindowButton(.closeButton),
                  let container = close.superview,
                  let frameView = container.superview
            else { return }
            let button = close.convert(close.bounds, to: frameView)
            // Frame coordinates have their origin at the bottom, so the bar's centre line sits a
            // half-bar down from the top of the window.
            let target = frameView.bounds.height - barHeight / 2
            let drop = target - button.midY

            // And across: the system's leading inset is measured against its own 28pt bar, where it
            // balances. In a 52pt one it doesn't — the lights end up half as far from the side as
            // they are from the top, which is what reads as them being jammed into the corner. The
            // inset that balances is the room the bar leaves above them.
            let margin = (barHeight - button.height) / 2
            let shift = margin - button.minX

            guard abs(drop) > 0.5 || abs(shift) > 0.5 else { return }
            container.frame = container.frame.offsetBy(dx: shift, dy: drop)
        }
    }
}
