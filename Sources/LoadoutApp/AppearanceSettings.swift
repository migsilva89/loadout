import SwiftUI
import LoadoutCore

/// The five themes, and how a document reads.
///
/// The theme choice is a colour, so the control is the colour — but each disc is named as well,
/// because a ring around a circle says *which* one is on and never what it is called. Picking one
/// repaints the window behind this pane on the spot, which is the only preview worth having and the
/// best argument for Settings living in the window rather than over it.
struct AppearanceSettings: View {
    private let themes = ThemeStore.shared
    // The same three keys the reading pane and the ⌘+/− menu use. This is where a hand looks for
    // text size, and a preferences screen holding only five circles reads as unfinished.
    @AppStorage("readerFontSize") private var readerFontSize = 15.0
    @AppStorage("readerFont") private var readerFont = "system"
    @AppStorage("readerBackground") private var readerBackground = "darker"
    @AppStorage("listDensity") private var density = "compact"

    var body: some View {
        SettingsGroup(
            title: "Theme",
            note: themes.name.hint,
            footnote: "The window changes as you pick, and the choice is remembered for next launch."
        ) {
            HStack(spacing: 18) {
                ForEach(ThemeName.allCases) { theme in
                    swatch(theme)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }

        SettingsGroup(
            title: "The list",
            footnote: "Compact drops the descriptions and tightens the rows. With eighty skills the "
                + "descriptions are what turns the column into a wall, and somebody who knows their "
                + "own skills by name is only paying to scroll."
        ) {
            SettingsRow(label: "Density", dividing: false) {
                Picker("", selection: $density) {
                    Text("Comfortable").tag("comfortable")
                    Text("Compact").tag("compact")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .pointingHand()
            }
        }

        SettingsGroup(
            title: "Reading",
            footnote: "⌘+ and ⌘− change the size from anywhere; ⌘0 puts it back."
        ) {
            SettingsRow(label: "Text size") {
                HStack(spacing: 10) {
                    Slider(value: $readerFontSize, in: 12...22, step: 1)
                        .frame(width: 160)
                        .pointingHand()
                    SettingsValue(text: "\(Int(readerFontSize)) pt")
                }
            }
            SettingsRow(label: "Typeface") {
                Picker("", selection: $readerFont) {
                    Text("System").tag("system")
                    Text("Serif").tag("serif")
                    Text("Mono").tag("mono")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .pointingHand()
            }
            SettingsRow(
                label: "Reading background",
                sub: "The ground the document sits on, in the pane on the right",
                dividing: false
            ) {
                Picker("", selection: $readerBackground) {
                    Text("Card").tag("card")
                    Text("Darker").tag("darker")
                    Text("Ink").tag("ink")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .pointingHand()
            }
        }
    }

    private func swatch(_ theme: ThemeName) -> some View {
        let selected = themes.name == theme
        return Button {
            themes.name = theme
        } label: {
            VStack(spacing: 7) {
                Circle()
                    .fill(theme.palette.accent)
                    .frame(width: 30, height: 30)
                    // A hairline of its own, so Graphite's grey still reads as a disc against the
                    // pane's own grey — and the selected ring sits outside the disc, across a gap
                    // in the window colour, rather than on top of it.
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                    .padding(2)
                    .overlay {
                        Circle().strokeBorder(
                            selected ? Color.white.opacity(0.9) : Color.clear, lineWidth: 3.5
                        )
                    }
                Text(theme.label)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : V2.textFaint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(theme.hint)
        .accessibilityLabel(theme.label)
        .pointingHand()
    }
}
