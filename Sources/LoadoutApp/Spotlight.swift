import SwiftUI

/// Where each control is on screen, so a recording can say where a thing happened.
///
/// The app drives itself through its own functions — `select`, `toggle`, `setAssistant` — and
/// there is no pointer anywhere in a recording, because moving the real one needs a permission a
/// script cannot be granted. A cursor and a zoom can be drawn on afterwards, but only if something
/// wrote down *where* on screen each step landed. That is this file's whole job: a view marks
/// itself with a name, and a walkthrough asks for the rectangle under that name.
///
/// The rectangles are in the window's own coordinates, which is what `WindowRecorder` photographs,
/// so a point here is a point in the frame — no offset, no guessing at a title bar.
///
/// Nothing is measured unless a recording asked for it. Off, `spotlight(_:)` returns the view
/// untouched: the app in someone's hands should not carry a `GeometryReader` per row for the sake
/// of a picture nobody is taking.
@MainActor
enum Spotlight {
    /// The coordinate space the rectangles are reported in — the root of the window's content.
    static let space = "loadout.window"

    /// Set once at launch, from the same environment variable that starts the recorder.
    static var isOn = false

    private static var rects: [String: CGRect] = [:]

    static func note(_ key: String, _ rect: CGRect) {
        guard isOn else { return }
        rects[key] = rect
    }

    static func forget(_ key: String) {
        rects[key] = nil
    }

    /// Where that control is, or nothing if it is not on screen — scrolled out of the list, on a
    /// tab that is not showing, inside a card that is not drawn.
    static func rect(_ key: String) -> CGRect? {
        rects[key]
    }

    // MARK: - The names
    //
    // One place for them, so a walkthrough asking for a rectangle and a view publishing one cannot
    // drift apart over a typo.

    static func row(_ id: String) -> String { "row:\(id)" }
    static func toggle(_ id: String) -> String { "switch:\(id)" }
    static func tab(_ name: String) -> String { "tab:\(name)" }
    static func assistant(_ id: String) -> String { "assistant:\(id)" }
}

private struct SpotlightModifier: ViewModifier {
    let key: String

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                let rect = proxy.frame(in: .named(Spotlight.space))
                Color.clear
                    .onAppear { Spotlight.note(key, rect) }
                    .onChange(of: rect) { _, new in Spotlight.note(key, new) }
                    .onDisappear { Spotlight.forget(key) }
            }
        )
    }
}

extension View {
    /// Publishes this view's rectangle under a name, while a recording is running.
    @ViewBuilder
    func spotlight(_ key: String) -> some View {
        if Spotlight.isOn {
            modifier(SpotlightModifier(key: key))
        } else {
            self
        }
    }
}
