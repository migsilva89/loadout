import SwiftUI
import AppKit

// MARK: - Tokens

/// One theme's chroma, and nothing else.
///
/// Every colour the window paints that is *about the theme* comes from here — surfaces,
/// accent, links, code, the reading grounds. What stays outside is deliberate: the white
/// opacity ramps for text and hairlines, the warning amber and the issue red, the editor's
/// syntax hues, and each assistant's own brand colour. Those mean the same thing in every
/// theme, so putting them in here would only be five copies of one fact.
struct Palette: Sendable {
    /// Selection, the one primary action, the marker beside the section being read.
    let accent: Color
    /// The healthy state: a switch that is on, a budget still inside its limit.
    let ok: Color

    /// The desk the window sits on — what shows through around it and behind a sheet.
    let page: Color
    /// The window's body, which is also the detail pane's ground.
    let win: Color
    /// The title bar.
    let bar: Color
    /// The sidebar column.
    let side: Color
    /// Cards on the detail pane.
    let card: Color
    /// Popovers: scope, sort, filters, Aa.
    let pop: Color
    /// The sidebar's footer strip and the editor's status bar.
    let foot: Color
    /// The code editor's ground.
    let editor: Color

    /// Links and quiet affordances — "Reveal", "Copy", the Ask sparkle, "add".
    let link: Color
    /// Inline code and fenced blocks.
    let code: Color
    /// The blinking caret in the editor.
    let caret: Color

    /// The accent as a gradient, top to bottom: the app's own icon-shaped marks wear it.
    let gradTop: Color
    let gradBottom: Color

    /// The three reading grounds the Aa popover offers, each a step darker than the last.
    let readerDark: Color
    let readerDarker: Color
    let readerInk: Color

    var grad: LinearGradient {
        LinearGradient(colors: [gradTop, gradBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// The five themes, by name. The raw value is what gets persisted, so it outlives any
/// reordering here.
enum ThemeName: String, CaseIterable, Identifiable, Sendable {
    case terracotta, graphite, violet, sage, plum

    var id: String { rawValue }

    /// What Settings calls it.
    var label: String {
        switch self {
        case .terracotta: return "Terracotta"
        case .graphite: return "Graphite"
        case .violet: return "Violet"
        case .sage: return "Sage"
        case .plum: return "Plum"
        }
    }

    /// One line for the swatch's tooltip — what this theme is, not what colour it is.
    var hint: String {
        switch self {
        case .terracotta: return "Terracotta — warm clay and olive"
        case .graphite: return "Graphite — no accent hue at all, a neutral tool"
        case .violet: return "Violet — indigo and mint"
        case .sage: return "Sage — forest green"
        case .plum: return "Plum — wine"
        }
    }

    var palette: Palette {
        switch self {
        case .terracotta: return .terracotta
        case .graphite: return .graphite
        case .violet: return .violet
        case .sage: return .sage
        case .plum: return .plum
        }
    }

    /// Where the choice lives between launches.
    static let storageKey = "theme"

    /// The stored choice, or Terracotta on a first run — read directly rather than through the
    /// store, so the palette is right from the very first colour the app asks for.
    static var persisted: ThemeName {
        ThemeName(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .terracotta
    }
}

extension Palette {
    /// The default: warm clay with an olive counterpart.
    static let terracotta = Palette(
        accent: Color(hex: 0xB85C38), ok: Color(hex: 0x8A9E63),
        page: Color(hex: 0x100E0D), win: Color(hex: 0x1D1A18), bar: Color(hex: 0x2B2724),
        side: Color(hex: 0x221F1C), card: Color(hex: 0x292522), pop: Color(hex: 0x332E2A),
        foot: Color(hex: 0x242018), editor: Color(hex: 0x1B1815),
        link: Color(hex: 0xDE8E68), code: Color(hex: 0xD6A97F), caret: Color(hex: 0xE0A582),
        gradTop: Color(hex: 0xCE7049), gradBottom: Color(hex: 0x9A4526),
        readerDark: Color(hex: 0x221F1C), readerDarker: Color(hex: 0x1A1714),
        readerInk: Color(hex: 0x100E0C)
    )

    /// No chroma in the accent at all — the one for people who want the tool to disappear.
    static let graphite = Palette(
        accent: Color(hex: 0x5D5D63), ok: Color(hex: 0xA8B0AC),
        page: Color(hex: 0x0E0E0E), win: Color(hex: 0x1C1C1C), bar: Color(hex: 0x2A2A2A),
        side: Color(hex: 0x212121), card: Color(hex: 0x272727), pop: Color(hex: 0x323234),
        foot: Color(hex: 0x232323), editor: Color(hex: 0x191919),
        link: Color(hex: 0xCBCBD0), code: Color(hex: 0xAEBAB5), caret: Color(hex: 0xDADADE),
        gradTop: Color(hex: 0x75757A), gradBottom: Color(hex: 0x4A4A4E),
        readerDark: Color(hex: 0x212121), readerDarker: Color(hex: 0x171717),
        readerInk: Color(hex: 0x0E0E0E)
    )

    static let violet = Palette(
        accent: Color(hex: 0x7A5AF8), ok: Color(hex: 0x4FD1A5),
        page: Color(hex: 0x0E0D12), win: Color(hex: 0x1A181F), bar: Color(hex: 0x282431),
        side: Color(hex: 0x1F1D26), card: Color(hex: 0x25222D), pop: Color(hex: 0x312D3C),
        foot: Color(hex: 0x211E28), editor: Color(hex: 0x17151C),
        link: Color(hex: 0xA996FF), code: Color(hex: 0x8FD3C8), caret: Color(hex: 0xB9A8FF),
        gradTop: Color(hex: 0x8D6DFF), gradBottom: Color(hex: 0x5B3AD6),
        readerDark: Color(hex: 0x1F1D26), readerDarker: Color(hex: 0x17151C),
        readerInk: Color(hex: 0x0D0C11)
    )

    static let sage = Palette(
        accent: Color(hex: 0x3F7D5F), ok: Color(hex: 0x7FBF97),
        page: Color(hex: 0x0D100E), win: Color(hex: 0x181B19), bar: Color(hex: 0x252A27),
        side: Color(hex: 0x1C201E), card: Color(hex: 0x222724), pop: Color(hex: 0x2C312E),
        foot: Color(hex: 0x1E2220), editor: Color(hex: 0x151816),
        link: Color(hex: 0x8FC9AB), code: Color(hex: 0xB7CFA8), caret: Color(hex: 0xA6DCC0),
        gradTop: Color(hex: 0x4E9273), gradBottom: Color(hex: 0x2E6047),
        readerDark: Color(hex: 0x1C201E), readerDarker: Color(hex: 0x151816),
        readerInk: Color(hex: 0x0C0F0D)
    )

    static let plum = Palette(
        accent: Color(hex: 0xA93F63), ok: Color(hex: 0xC98BA6),
        page: Color(hex: 0x100C0F), win: Color(hex: 0x1C171A), bar: Color(hex: 0x2A2327),
        side: Color(hex: 0x211B1F), card: Color(hex: 0x272025), pop: Color(hex: 0x322A2F),
        foot: Color(hex: 0x231D21), editor: Color(hex: 0x191418),
        link: Color(hex: 0xDE8FAC), code: Color(hex: 0xD3A6BC), caret: Color(hex: 0xE9A8C1),
        gradTop: Color(hex: 0xBE4E74), gradBottom: Color(hex: 0x8A2B4A),
        readerDark: Color(hex: 0x211B1F), readerDarker: Color(hex: 0x191418),
        readerInk: Color(hex: 0x100C0F)
    )
}

/// The one hex reader in the app. Colours are authored as hex because the design is, and
/// transcribing them into three decimals by hand is how a palette drifts from its own spec.
extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Switching

/// Which theme is on, and the only thing that changes it.
///
/// Two jobs, and they are not the same job. It writes the chosen palette into `V2`, which is
/// what every colour in the app actually reads — a plain value, readable from an `NSView`'s
/// `draw` as easily as from a SwiftUI body. And being observable, it also tells the window to
/// redraw: `ContentView` keys its identity on `name`, so a switch rebuilds the whole tree in
/// place. No reload, and nothing left painted in the previous theme.
@MainActor
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    var name: ThemeName {
        didSet {
            guard oldValue != name else { return }
            V2.palette = name.palette
            UserDefaults.standard.set(name.rawValue, forKey: ThemeName.storageKey)
        }
    }

    private init() {
        name = .persisted
        V2.palette = name.palette
    }
}

// MARK: - The palette in force

/// Every colour the app draws with.
///
/// The theme half is a lookup into whichever `Palette` is current; the shared half is stated
/// here once, because it is the same in all five themes. Text and hairlines are white
/// opacities rather than greys on purpose — that is what lets only the chroma change.
enum V2 {
    /// The palette in force. Written by `ThemeStore` on the main thread and read while
    /// drawing, which is also the main thread — `nonisolated(unsafe)` states that rather than
    /// forcing an actor hop into every `Hairline`'s default argument.
    nonisolated(unsafe) static var palette: Palette = ThemeName.persisted.palette

    // Surfaces, outermost inwards.
    static var page: Color { palette.page }
    static var window: Color { palette.win }
    static var bar: Color { palette.bar }
    static var sidebar: Color { palette.side }
    static var card: Color { palette.card }
    static var popover: Color { palette.pop }
    static var footer: Color { palette.foot }
    static var editor: Color { palette.editor }

    // Meaning.
    static var accent: Color { palette.accent }
    static var link: Color { palette.link }
    static var ok: Color { palette.ok }
    static var code: Color { palette.code }
    static var caret: Color { palette.caret }
    /// The accent as a gradient, for the icon-shaped marks that wear it.
    static var grad: LinearGradient { palette.grad }

    /// The reading surface behind the document, by the Aa popover's stored choice. Each step
    /// is darker than the one before it in every theme.
    static func reader(_ choice: String) -> Color {
        switch choice {
        case "dark": return palette.readerDark
        case "ink": return palette.readerInk
        default: return palette.readerDarker
        }
    }

    /// A budget past its documented limit. Shared across themes: it is a warning, and a
    /// warning that changed hue with the decor would be a warning you have to learn twice.
    static let amber = Color(hex: 0xFF9F0A)
    /// A live validation error — the editor's squiggle, the status bar's issue count.
    static let issue = Color(hex: 0xE34A4A)

    /// Text, from loudest to quietest. Shared: only chroma changes between themes.
    static let text = Color.white.opacity(0.92)
    static let textMid = Color.white.opacity(0.62)
    static let textDim = Color.white.opacity(0.45)

    /// A switched-off badge: the tile behind the glyph, and the glyph itself.
    ///
    /// Off has to read as *quiet*, never as *missing*. In the Plugins list the off tile was white
    /// at 6% with a `textDim` glyph on it, and the two were close enough that the icon disappeared
    /// into its own tile — a row that looked broken rather than switched off. The glyph is now the
    /// same weight the row's own dimmed text uses, over a tile dark enough to separate it from the
    /// sidebar. `ThemeCheck` measures the pair in every theme, so nudging either one is caught.
    static let offTile = Color.white.opacity(0.05)
    static let offGlyph = Color.white.opacity(0.62)
    static let textFaint = Color.white.opacity(0.32)

    /// Hairlines between and around surfaces.
    static let hairline = Color.white.opacity(0.10)
    static let hairlineSoft = Color.white.opacity(0.07)
    /// Inset wells (search fields, the segmented tabs' ground).
    static let well = Color.black.opacity(0.30)
    /// Raised buttons on any surface.
    static let button = Color.white.opacity(0.10)
    static let buttonHover = Color.white.opacity(0.16)
    /// A switch that is off, and the muted "nothing to load it with" state beside it.
    static let offTrack = Color.white.opacity(0.16)
    static let muted = Color.white.opacity(0.25)
}

// MARK: - Assistant brand hues

/// Each assistant's own colour, for the monogram drawn when its app isn't installed and there
/// is no real icon to read.
///
/// Deliberately outside the themes: this is whose mark it is, not what the window is wearing,
/// and a Codex monogram that turned plum in the plum theme would be saying something false.
enum AssistantBrand {
    private static let hues: [String: UInt32] = [
        "claude": 0xD97757,
        "codex": 0x10A37F,
        "cursor": 0x8A8F98,
        "windsurf": 0x58C4A0,
        "trae": 0xE5484D,
        "kiro": 0x7C5CFF,
        "factory": 0xF2652A,
        "hermes": 0xCFCFD4,
        "commandcode": 0xC9CBD0,
        "gemini": 0x4285F4,
        "copilot": 0x8B949E,
        "opencode": 0xF5A623,
        "droid": 0x3DDC84,
    ]

    /// Anything not listed — a dot-directory this app has never heard of — gets a neutral
    /// slate rather than a hue invented for it. Command Code and Hermes get one too: both
    /// draw themselves in white on black, so a hue here would be a hue nobody chose.
    static func color(for id: String) -> Color {
        Color(hex: hues[id] ?? 0x8A8F98)
    }
}

// MARK: - Shared pieces

/// The design's small uppercase caption — "TOKEN BUDGET", "DETAILS", "ASSISTANTS" on the cards,
/// and the reading rail's own section headings, which are the same caption drawn a half-point
/// smaller and quieter because the rail sits beside the text rather than over it.
struct V2CardCaption: View {
    let text: String
    var size: CGFloat = 11
    var weight: Font.Weight = .regular
    var color: Color = V2.textDim

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: weight))
            .kerning(0.5)
            .foregroundStyle(color)
    }
}

/// One card: the rounded surface every detail-pane section sits on.
struct V2Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(V2.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(V2.hairlineSoft, lineWidth: 0.5))
    }
}

/// A half-point hairline — the separator weight the whole design is drawn with.
struct Hairline: View {
    var color: Color = V2.hairline
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(
                width: vertical ? 0.5 : nil,
                height: vertical ? nil : 0.5
            )
    }
}

/// A label in a bar that adapts by dropping whole controls: it must refuse to wrap, so the bar
/// can find it doesn't fit and choose a smaller arrangement instead of a taller one.
///
/// Named once rather than spelled out per label, because the rule belongs to the mechanism — any
/// label added to one of these bars needs it, and a wrapped one fails quietly.
extension View {
    func fitsOnOneLine() -> some View {
        lineLimit(1).fixedSize(horizontal: true, vertical: false)
    }
}

/// The lift that marks the selected tile of any of the design's switches — a tile off the well,
/// not a lighter patch of it: half a point of drop, barely blurred.
struct V2SelectedTile: View {
    let selected: Bool
    var cornerRadius: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(selected ? V2.buttonHover : Color.clear)
            .shadow(color: .black.opacity(selected ? 0.4 : 0), radius: 0.75, y: 0.5)
    }
}

/// One segment of the design's inset segmented controls — the kind tabs in the title bar and
/// the document's Preview/Edit switch are the same tile, kept identical by construction.
struct V2SegmentTab: View {
    let label: String
    var count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.white : Color.white.opacity(0.55))
                    .fitsOnOneLine()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.white.opacity(selected ? 0.6 : 0.3))
                        .fitsOnOneLine()
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 4)
            .background(V2SelectedTile(selected: selected))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .pointingHand()
    }
}

/// Paints the window itself, which is the one surface SwiftUI never reaches: the desk colour
/// shows around the content while the window is resized, and behind a sheet as it slides.
struct WindowGround: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.backgroundColor = NSColor(V2.page) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.backgroundColor = NSColor(V2.page)
    }
}
