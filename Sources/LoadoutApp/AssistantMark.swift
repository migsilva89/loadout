import SwiftUI
import AppKit
import LoadoutCore

/// The mark for one assistant.
///
/// When the assistant's app is installed, this is its real icon, read from the app bundle at
/// runtime — no trademark files copied into this repo, and it never goes stale. When there is
/// no app (Trae, Kiro, Factory and friends are CLIs here), it falls back to two letters.
struct AssistantMark: View {
    let assistant: Assistant
    let present: Bool
    var size: CGFloat = 16

    var body: some View {
        Group {
            if let icon = Self.icon(for: assistant) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                Text(assistant.initials)
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .frame(width: size, height: size)
                    .background(
                        Color.secondary.opacity(present ? 0.28 : 0.16),
                        in: RoundedRectangle(cornerRadius: size * 0.26)
                    )
                    .foregroundStyle(Color.primary.opacity(present ? 0.85 : 0.65))
            }
        }
        // Absent is dimmer, not invisible: on a dark background a fully desaturated icon at
        // a third opacity reads as a missing icon rather than as a state.
        .saturation(present ? 1 : 0.65)
        .opacity(present ? 1 : 0.6)
    }

    /// One lookup for both sources, shared with the Ask menu: a user-supplied file in
    /// `~/.claude/.loadout/cli-icons/` wins, then the installed app, then nothing and the
    /// caller draws initials. Five of the assistants here ship no Mac app at all.
    static func icon(for assistant: Assistant) -> NSImage? {
        AppIconCache.icon(forID: assistant.id, appPath: assistant.appPath)
    }
}
