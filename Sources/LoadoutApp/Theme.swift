import SwiftUI

/// The v2 palette, straight from the "Skills Manager Pro v2" design. One fixed dark theme:
/// the design commits to these exact surfaces and the blue accent, so the app stops following
/// the system appearance and owns its colours the way the mock does.
enum V2 {
    /// The detail pane and the window's own ground.
    static let window = Color(red: 0.118, green: 0.118, blue: 0.118)          // #1E1E1E
    /// The sidebar column, a step darker than the window.
    static let sidebar = Color(red: 0.137, green: 0.137, blue: 0.141)         // #232324
    /// The sidebar's footer strip.
    static let footer = Color(red: 0.145, green: 0.145, blue: 0.149)          // #252526
    /// Cards on the detail pane.
    static let card = Color(red: 0.165, green: 0.165, blue: 0.173)            // #2A2A2C
    /// Floating popovers (scope, sort, filters).
    static let popover = Color(red: 0.200, green: 0.200, blue: 0.208)         // #333335
    /// The editor's ground, darker than the card that holds it.
    static let editor = Color(red: 0.106, green: 0.106, blue: 0.114)          // #1B1B1D

    /// Selection and primary actions.
    static let accent = Color(red: 0.039, green: 0.420, blue: 0.878)          // #0A6BE0
    /// Links and quiet affordances ("Reveal", "add").
    static let link = Color(red: 0.298, green: 0.608, blue: 1.0)              // #4C9BFF
    /// Switches on, healthy budget bars, "loaded".
    static let green = Color(red: 0.196, green: 0.843, blue: 0.294)           // #32D74B
    /// A budget past its documented limit.
    static let amber = Color(red: 1.0, green: 0.624, blue: 0.039)             // #FF9F0A

    /// Text, from loudest to quietest — the design works in white opacities, not grays.
    static let text = Color.white.opacity(0.92)
    static let textMid = Color.white.opacity(0.62)
    static let textDim = Color.white.opacity(0.45)
    static let textFaint = Color.white.opacity(0.32)

    /// Hairlines between and around surfaces.
    static let hairline = Color.white.opacity(0.10)
    static let hairlineSoft = Color.white.opacity(0.07)
    /// Inset wells (search fields, the segmented tabs' ground).
    static let well = Color.black.opacity(0.30)
    /// Raised buttons on any surface.
    static let button = Color.white.opacity(0.10)
    static let buttonHover = Color.white.opacity(0.16)
}

/// The design's small uppercase card caption — "TOKEN BUDGET", "DETAILS", "ASSISTANTS".
struct V2CardCaption: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11))
            .kerning(0.5)
            .foregroundStyle(V2.textDim)
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
