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
                // The monogram wears the assistant's own brand hue in every theme — the mark
                // says whose it is, and a Codex badge that turned plum in the plum theme would
                // be saying something false. A tenth of it fills the tile, a third draws the
                // edge, so the two letters stay the loudest thing in it.
                let brand = AssistantBrand.color(for: assistant.id)
                let shape = RoundedRectangle(cornerRadius: size * 0.26)
                Text(assistant.initials)
                    .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                    .frame(width: size, height: size)
                    .background(brand.opacity(0.15), in: shape)
                    .overlay(shape.strokeBorder(brand.opacity(0.30), lineWidth: 0.5))
                    .foregroundStyle(brand)
            }
        }
        // Absent is dimmer, not invisible: on a dark background a fully desaturated icon at
        // a third opacity reads as a missing icon rather than as a state.
        .saturation(present ? 1 : 0.65)
        .opacity(present ? 1 : 0.6)
    }

    /// One lookup for both sources, shared with the Ask menu: a user-supplied file in
    /// `~/Library/Application Support/Loadout/cli-icons/` wins, then the installed app, then
    /// nothing and the caller draws initials. Several of the assistants here ship no Mac app.
    static func icon(for assistant: Assistant) -> NSImage? {
        AppIconCache.icon(forID: assistant.id, appPath: assistant.appPath)
    }
}
