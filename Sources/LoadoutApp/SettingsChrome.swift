import SwiftUI

/// The pieces every Settings section is built from.
///
/// They exist because the sections were first written for a 520pt preferences window and reused
/// in a pane that can be a thousand points wide. `Form` with `.formStyle(.grouped)` stretches its
/// rows to whatever it is given, so a switch ended up a hand's width away from the words it
/// belonged to, and a path ran the length of the screen. These lay out to a measured column
/// instead, and the column stops growing.
///
/// One row, one control. A row with a value *and* a button was the other thing that made the old
/// screen hard to read: the eye had two places to land and no idea which was the answer.
enum SettingsChrome {
    /// The widest the reading column ever gets, whatever the window does. Around ninety characters
    /// at this size — past that a line stops being one thing the eye takes in.
    static let columnWidth: CGFloat = 680
}

/// A titled group: heading, an optional line saying why it exists, one card of rows, and an
/// optional footnote under it.
struct SettingsGroup<Content: View>: View {
    let title: String
    var note: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                if let note {
                    Text(note)
                        .font(.system(size: 12))
                        .foregroundStyle(V2.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) { content }
                .background(V2.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(V2.hairline, lineWidth: 0.5)
                }

            if let footnote {
                Text(footnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(V2.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One line inside a group: what it is on the left, the single control on the right.
///
/// The hairline is drawn by the row rather than between rows, and the last row in a card asks for
/// `dividing: false` — a separator under the final row draws a line to nothing.
struct SettingsRow<Trailing: View>: View {
    let label: String
    var sub: String?
    /// A path, a size, an id: shown monospaced, because those are read character by character.
    var mono = false
    var dividing = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub {
                    Text(sub)
                        .font(.system(size: 11.5))
                        .foregroundStyle(V2.textFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if dividing { Hairline(color: Color.white.opacity(0.06)).padding(.leading, 14) }
        }
    }
}

/// A value on the right of a row: the answer, not a control. Tabular so a column of numbers lines
/// up, monospaced when it is a path.
struct SettingsValue: View {
    let text: String
    var mono = false

    var body: some View {
        Text(text)
            .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 12).monospacedDigit())
            .foregroundStyle(V2.textMid)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// A secondary or destructive action on the right of a row — Remove, Reveal.
///
/// Written as a word in the link colour rather than drawn as a button: a bordered button on every
/// row turns a list of facts into a wall of things to press, and the one button that matters stops
/// standing out.
struct SettingsLinkButton: View {
    let title: String
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(V2.link)
            .help(help.isEmpty ? title : help)
            .pointingHand()
    }
}
