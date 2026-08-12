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
private struct PointingHandModifier: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    guard !pushed else { return }
                    NSCursor.pointingHand.push()
                    pushed = true
                } else {
                    guard pushed else { return }
                    NSCursor.pop()
                    pushed = false
                }
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
    /// the platform default at the owner's request. See `PointingHandModifier` for why it's
    /// safe against a fast mouse leaving push/pop unbalanced.
    func pointingHand() -> some View {
        modifier(PointingHandModifier())
    }
}
