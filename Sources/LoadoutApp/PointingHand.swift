import SwiftUI
import AppKit

/// A pointing-hand cursor over anything clickable.
///
/// macOS convention reserves `NSCursor.pointingHand` for text links and leaves the arrow over
/// buttons, rows and toggles. The owner asked for the hand everywhere something responds to a
/// click anyway, so this app departs from that convention on purpose, app-wide, rather than
/// living with an inconsistent mix of the two.
///
/// `NSCursor.push()`/`.pop()` is a stack, not a set-and-forget property, so a naive
/// `onHover { inside in inside ? .push() : .pop() }` can leave it unbalanced: if the mouse
/// leaves the view fast enough that AppKit coalesces or reorders the hover events, a `pop`
/// can fire without a matching `push` (or vice versa) and strand the wrong cursor over the
/// entire app until something else happens to push and pop in balance again. Keeping
/// per-instance state and only popping after a push guards against that.
private struct HoverCursorModifier: ViewModifier {
    /// The hand for anything clickable; the resize arrows for the one thing you drag instead.
    let cursor: NSCursor

    /// False for a control that is currently `.disabled(…)`. A hand over something that ignores the
    /// click is a worse lie than the plain arrow, so the hand is withheld while it can't be pressed.
    let enabled: Bool

    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && enabled {
                    guard !pushed else { return }
                    cursor.push()
                    pushed = true
                } else {
                    guard pushed else { return }
                    NSCursor.pop()
                    pushed = false
                }
            }
            // A control can switch off under a still cursor — Save greys out the moment the write
            // lands — and no hover event follows, so the hand has to be taken back here.
            .onChange(of: enabled) { _, nowEnabled in
                guard !nowEnabled, pushed else { return }
                NSCursor.pop()
                pushed = false
            }
            // A hovered view can vanish under the cursor — the list reloads by itself whenever
            // the watcher sees a change on disk — and no exit event ever arrives for it. Without
            // this, that leaves the hand stranded for the rest of the session.
            .onDisappear {
                guard pushed else { return }
                NSCursor.pop()
                pushed = false
            }
    }
}

extension View {
    /// Marks this view as clickable with a pointing-hand cursor, a deliberate departure from
    /// the platform default at the owner's request. See `HoverCursorModifier` for why it's
    /// safe against a fast mouse leaving push/pop unbalanced.
    ///
    /// Pass `enabled:` the same condition the control's own `.disabled(…)` reads, inverted, and the
    /// hand stays away while the control can't be pressed.
    func pointingHand(enabled: Bool = true) -> some View {
        modifier(HoverCursorModifier(cursor: .pointingHand, enabled: enabled))
    }

    /// Shows some other cursor while the pointer is over this view — the resize arrows over a drag
    /// handle, where the hand would promise a click that does nothing. Balanced the same way.
    func hoverCursor(_ cursor: NSCursor, enabled: Bool = true) -> some View {
        modifier(HoverCursorModifier(cursor: cursor, enabled: enabled))
    }
}
