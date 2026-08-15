#!/usr/bin/env swift
//
// make-icon.swift
//
// Generates the Loadout app icon and wordmark logo programmatically (no
// external assets, no embedded fonts — SF Pro comes from the system).
//
// Produces, relative to the repo root:
//   Resources/Loadout.iconset/icon_{16,32,128,256,512}x{same}.png (+ @2x)
//   Resources/Loadout.icns              (built from the iconset via `iconutil`)
//   Resources/logo-light.png            (1024x512 wordmark, dark text, for light backgrounds)
//   Resources/logo-dark.png             (1024x512 wordmark, light text, for dark backgrounds)
//
// Run from the repo root:
//   swift Scripts/make-icon.swift
//
// Idempotent: the iconset directory is deleted and recreated on every run.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Paths

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesDir = repoRoot.appendingPathComponent("Resources")
let iconsetDir = resourcesDir.appendingPathComponent("Loadout.iconset")
let icnsPath = resourcesDir.appendingPathComponent("Loadout.icns")

let fm = FileManager.default
try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

// Reset iconset dir so re-runs are clean.
try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

// MARK: - Colors

extension NSColor {
    convenience init(hex: String, alpha: CGFloat = 1.0) {
        var hexString = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexString = hexString.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgb)
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgb & 0x0000FF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

// The icon is drawn from a theme's own tokens: the squircle runs from its title bar down to
// its desk, and the three plates are its accent gradient, brightening as they widen.
//
// Duplicated from `Sources/LoadoutApp/Theme.swift` rather than shared, because this is a
// standalone script with no access to the app target. Theme.swift is the source of truth; if a
// palette changes there, the matching four hexes change here.
//
//   swift Scripts/make-icon.swift            → Terracotta, the shipped default
//   swift Scripts/make-icon.swift plum       → any of the five, for a screenshot
struct IconTheme {
    let bar: String
    let page: String
    let gradTop: String
    let gradBottom: String
}

let iconThemes: [String: IconTheme] = [
    "terracotta": IconTheme(bar: "#2B2724", page: "#100E0D", gradTop: "#CE7049", gradBottom: "#9A4526"),
    "graphite": IconTheme(bar: "#2A2A2A", page: "#0E0E0E", gradTop: "#75757A", gradBottom: "#4A4A4E"),
    "violet": IconTheme(bar: "#282431", page: "#0E0D12", gradTop: "#8D6DFF", gradBottom: "#5B3AD6"),
    "sage": IconTheme(bar: "#252A27", page: "#0D100E", gradTop: "#4E9273", gradBottom: "#2E6047"),
    "plum": IconTheme(bar: "#2A2327", page: "#100C0F", gradTop: "#BE4E74", gradBottom: "#8A2B4A"),
]

let requestedTheme = CommandLine.arguments.dropFirst().first?.lowercased() ?? "terracotta"
guard let theme = iconThemes[requestedTheme] else {
    FileHandle.standardError.write(
        "Unknown theme \"\(requestedTheme)\". Known: \(iconThemes.keys.sorted().joined(separator: ", "))\n"
            .data(using: .utf8)!
    )
    exit(1)
}
print("Theme: \(requestedTheme)")

let bgTop = NSColor(hex: theme.bar)
let bgBottom = NSColor(hex: theme.page)

/// The plates, top to bottom: the gradient's dark end, its light end, then a step lighter
/// again — the widest plate is the brightest, which is what makes the stack read as lit.
func lightened(_ color: NSColor, _ fraction: CGFloat) -> NSColor {
    color.blended(withFraction: fraction, of: .white) ?? color
}

let barTop = NSColor(hex: theme.gradBottom)
let barMid = NSColor(hex: theme.gradTop)
let barBottom = lightened(NSColor(hex: theme.gradTop), 0.62)

let textDark = NSColor(hex: "#14161C")   // logo-light.png text
let textLight = NSColor(hex: "#F2F3F6")  // logo-dark.png text

// MARK: - Bitmap context helpers

/// Runs `body` with an AppKit graphics context pointed at a fresh ARGB
/// bitmap of `width` x `height` pixels, y-up (non-flipped), then returns
/// the resulting CGImage.
func renderImage(width: Int, height: Int, _ body: (CGContext, CGSize) -> Void) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create CGContext \(width)x\(height)")
    }

    NSGraphicsContext.saveGraphicsState()
    let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.current = nsContext
    body(ctx, CGSize(width: width, height: height))
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let image = ctx.makeImage() else {
        fatalError("Could not make CGImage from context")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for \(url.lastPathComponent)")
    }
    do {
        try data.write(to: url)
    } catch {
        fatalError("Could not write \(url.path): \(error)")
    }
}

// MARK: - Glyph geometry (three stacked, offset plates)
//
// All measurements are fractions of the drawing's short side (the "size"
// passed in), so the same function draws crisply at any resolution.

struct BarSpec {
    let leftX: CGFloat
    let bottomY: CGFloat
    let width: CGFloat
    let height: CGFloat
    let color: NSColor
}

/// Computes the three bar rects (in a `size`x`size` local space, y-up),
/// already centered as a group around the origin-relative center of
/// `containerSize`, with the group's own bounding box centered at
/// (centerX, centerY).
func barSpecs(fitting boxSize: CGFloat, centerX: CGFloat, centerY: CGFloat) -> [BarSpec] {
    // Proportions relative to boxSize (the glyph's own design square).
    let barHeight = boxSize * 0.150
    let gap = boxSize * 0.100
    let offsetStep = boxSize * 0.110

    let widths: [CGFloat] = [boxSize * 0.50, boxSize * 0.70, boxSize * 0.90]
    let colors = [barTop, barMid, barBottom]

    // Stack top-to-bottom (design space, top plate first). We'll build in
    // y-up coordinates with row 0 = topmost.
    let totalHeight = barHeight * 3 + gap * 2

    var rects: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)] = []
    for i in 0..<3 {
        let leftX = CGFloat(i) * offsetStep
        // y measured from the bottom of the whole group; row 0 (top plate)
        // sits at the top of the stack.
        let rowFromTop = CGFloat(i)
        let y = totalHeight - barHeight - rowFromTop * (barHeight + gap)
        rects.append((x: leftX, y: y, w: widths[i], h: barHeight))
    }

    // Bounding box of the raw layout.
    let minX = rects.map { $0.x }.min()!
    let maxX = rects.map { $0.x + $0.w }.max()!
    let minY = rects.map { $0.y }.min()!
    let maxY = rects.map { $0.y + $0.h }.max()!
    let bboxW = maxX - minX
    let bboxH = maxY - minY

    // Translate so the bounding box is centered at (centerX, centerY).
    let dx = centerX - (minX + bboxW / 2)
    let dy = centerY - (minY + bboxH / 2)

    return zip(rects, colors).map { rect, color in
        BarSpec(leftX: rect.x + dx, bottomY: rect.y + dy, width: rect.w, height: rect.h, color: color)
    }
}

func drawGlyph(in ctx: CGContext, boxSize: CGFloat, centerX: CGFloat, centerY: CGFloat, withShadow: Bool) {
    let bars = barSpecs(fitting: boxSize, centerX: centerX, centerY: centerY)

    for bar in bars {
        let rect = NSRect(x: bar.leftX, y: bar.bottomY, width: bar.width, height: bar.height)
        let radius = bar.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        ctx.saveGState()
        if withShadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowOffset = NSSize(width: 0, height: -boxSize * 0.010)
            shadow.shadowBlurRadius = boxSize * 0.020
            shadow.set()
        }
        bar.color.setFill()
        path.fill()
        ctx.restoreGState()
    }
}

// MARK: - App icon

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    return renderImage(width: size, height: size) { ctx, canvas in
        // Apple's grid: the visible squircle covers about 82% of the canvas.
        let margin = s * 0.09
        let squircleSide = s - margin * 2
        let cornerRadius = squircleSide * 0.224
        let squircleRect = NSRect(x: margin, y: margin, width: squircleSide, height: squircleSide)
        let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: cornerRadius, yRadius: cornerRadius)

        ctx.saveGState()
        squirclePath.addClip()

        let gradient = NSGradient(starting: bgTop, ending: bgBottom)
        gradient?.draw(
            from: NSPoint(x: squircleRect.midX, y: squircleRect.maxY),
            to: NSPoint(x: squircleRect.midX, y: squircleRect.minY),
            options: []
        )
        ctx.restoreGState()

        // Glyph: generous padding inside the squircle so it never touches
        // the edge. Design box ~56% of the squircle side.
        let glyphBox = squircleSide * 0.56
        drawGlyph(
            in: ctx,
            boxSize: glyphBox,
            centerX: squircleRect.midX,
            centerY: squircleRect.midY,
            withShadow: true
        )
    }
}

let iconSizes: [(name: String, size: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

print("Rendering app icon set...")
for entry in iconSizes {
    let image = drawIcon(size: entry.size)
    let url = iconsetDir.appendingPathComponent("\(entry.name).png")
    writePNG(image, to: url)
    print("  wrote \(url.lastPathComponent) (\(entry.size)x\(entry.size))")
}

// MARK: - Build .icns via iconutil

print("Building Loadout.icns via iconutil...")
try? fm.removeItem(at: icnsPath)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsPath.path]

let stderrPipe = Pipe()
iconutil.standardError = stderrPipe

do {
    try iconutil.run()
    iconutil.waitUntilExit()
} catch {
    FileHandle.standardError.write("Failed to launch iconutil: \(error)\n".data(using: .utf8)!)
    exit(1)
}

if iconutil.terminationStatus != 0 {
    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let errStr = String(data: errData, encoding: .utf8) ?? "(no output)"
    FileHandle.standardError.write("iconutil failed (status \(iconutil.terminationStatus)):\n\(errStr)\n".data(using: .utf8)!)
    exit(1)
}

print("  wrote \(icnsPath.lastPathComponent)")

// MARK: - Wordmark

func drawWordmark(dark: Bool) -> CGImage {
    let width = 1024
    let height = 512
    let s = CGFloat(height) // scale glyph relative to canvas height

    let textColor = dark ? textLight : textDark

    return renderImage(width: width, height: height) { ctx, canvas in
        // Transparent background — nothing to draw for the base.

        let paddingX = s * 0.10
        let glyphBox = s * 0.42
        let glyphCenterX = paddingX + glyphBox / 2 + s * 0.04
        let glyphCenterY = canvas.height / 2

        drawGlyph(in: ctx, boxSize: glyphBox, centerX: glyphCenterX, centerY: glyphCenterY, withShadow: false)

        // Wordmark text, vertically centered, starting to the right of the glyph.
        let font = NSFont.systemFont(ofSize: s * 0.34, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let string = NSAttributedString(string: "Loadout", attributes: attrs)
        let textSize = string.size()

        let textX = glyphCenterX + glyphBox / 2 + s * 0.14
        let textY = (canvas.height - textSize.height) / 2

        string.draw(at: NSPoint(x: textX, y: textY))
    }
}

print("Rendering wordmark logos...")
let logoLight = drawWordmark(dark: false)
writePNG(logoLight, to: resourcesDir.appendingPathComponent("logo-light.png"))
print("  wrote logo-light.png (1024x512)")

let logoDark = drawWordmark(dark: true)
writePNG(logoDark, to: resourcesDir.appendingPathComponent("logo-dark.png"))
print("  wrote logo-dark.png (1024x512)")

print("Done.")
