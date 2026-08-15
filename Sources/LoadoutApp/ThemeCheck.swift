import SwiftUI
import AppKit

/// The palettes, measured rather than eyeballed.
///
/// A theme is five surfaces and three hues that all have to keep working together, and the way
/// that quietly fails is a swatch someone nudged by two points until the text on it stopped
/// being readable. So the two things the design actually promises are checked as arithmetic:
/// body text stays legible on the window, white text stays legible on the accent it sits on
/// (the selected row, the Save button), and each theme's three reading grounds really do step
/// darker in the order the Aa popover offers them.
///
/// Run by `Loadout --self-check` alongside the model's own checks.
enum ThemeCheck {
    /// WCAG AA for body-sized text. Not a taste threshold — the one number there is.
    static let minimumContrast: Double = 4.5

    /// Every check, as a label and whether it held.
    static func results() -> [(label: String, passed: Bool)] {
        ThemeName.allCases.flatMap { theme -> [(String, Bool)] in
            let palette = theme.palette
            let name = theme.label

            // The pane's own text: white at 92%, so what the eye compares against the window
            // is the composite, not pure white.
            let body = composite(.white, over: palette.win, alpha: 0.92)
            let onWindow = contrast(body, palette.win)

            // And the text that rides on the accent: a selected row's name, the Save button's
            // label. This is the one that decides whether an accent can be as light as it likes.
            let onAccent = contrast(rgb(.white), palette.accent)

            let grounds = [palette.readerDark, palette.readerDarker, palette.readerInk]
            let steps = zip(grounds, grounds.dropFirst()).allSatisfy {
                luminance($0.0) > luminance($0.1)
            }

            return [
                (
                    "\(name): body text on the window reads at \(rounded(onWindow)):1",
                    onWindow >= minimumContrast
                ),
                (
                    "\(name): white on the accent reads at \(rounded(onAccent)):1",
                    onAccent >= minimumContrast
                ),
                ("\(name): Dark → Darker → Ink each step darker", steps),
            ]
        }
    }

    // MARK: Colour arithmetic

    private static func rounded(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// sRGB components, which is what every colour in the palette is authored in.
    private static func rgb(_ color: Color) -> (r: Double, g: Double, b: Double) {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return (0, 0, 0) }
        return (Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent))
    }

    /// A translucent colour flattened onto what is behind it — the only honest way to measure
    /// text drawn as a white opacity.
    private static func composite(
        _ top: Color, over bottom: Color, alpha: Double
    ) -> (r: Double, g: Double, b: Double) {
        let t = rgb(top)
        let b = rgb(bottom)
        return (
            t.r * alpha + b.r * (1 - alpha),
            t.g * alpha + b.g * (1 - alpha),
            t.b * alpha + b.b * (1 - alpha)
        )
    }

    /// WCAG relative luminance.
    private static func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    private static func luminance(_ color: Color) -> Double { luminance(rgb(color)) }

    private static func contrast(
        _ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double)
    ) -> Double {
        let first = luminance(a)
        let second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    private static func contrast(_ a: (r: Double, g: Double, b: Double), _ b: Color) -> Double {
        contrast(a, rgb(b))
    }
}
