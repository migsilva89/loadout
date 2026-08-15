#!/usr/bin/env swift
//
// make-og-image.swift
//
// Draws the social preview card — the picture GitHub, Slack and every chat app show when somebody
// pastes a link to the repository. GitHub wants 1280×640.
//
//   swift Scripts/make-og-image.swift .github/assets/og-artwork.jpg
//
// The artwork behind it is generated separately and passed in. Everything on top of it comes from
// the app's own assets — the icon and the wordmark that `make-icon.swift` draws — so the card and
// the thing in the Dock are recognisably one object. Only the sentence is typeset here.
//
// Writes .github/assets/og-image.jpg. JPEG rather than PNG: the card is mostly gradient, GitHub
// refuses anything over 1 MB, and the same picture as a PNG is three times that.
//
// Upload it by hand in Settings › General › Social preview — GitHub has no API for it.

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("uso: swift Scripts/make-og-image.swift <artwork.png>")
    exit(2)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let artworkPath = URL(fileURLWithPath: arguments[1])
let output = root.appendingPathComponent(".github/assets/og-image.jpg")
/// GitHub's own ceiling for a social preview.
let sizeLimit = 1_000_000

guard let artwork = NSImage(contentsOf: artworkPath) else {
    print("não consegui abrir \(artworkPath.path)")
    exit(1)
}

// The card, and the type on it.
let size = NSSize(width: 1280, height: 640)
let margin: CGFloat = 84

// Straight from the app's terracotta palette, so the card and the window are recognisably the
// same thing.
func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: alpha
    )
}
let ink = hex(0xF2F3F6)
let inkSoft = hex(0xF2F3F6, alpha: 0.62)
let accent = hex(0xDE8E68)
let ground = hex(0x100E0D)

let image = NSImage(size: size)
image.lockFocus()

// 1. The ground, in case the artwork does not cover every pixel.
ground.setFill()
NSRect(origin: .zero, size: size).fill()

// 2. The artwork, cropped to the card's shape from the centre rather than squashed into it.
let artSize = artwork.size
let scale = max(size.width / artSize.width, size.height / artSize.height)
let scaled = NSSize(width: artSize.width * scale, height: artSize.height * scale)
artwork.draw(
    in: NSRect(
        x: (size.width - scaled.width) / 2,
        y: (size.height - scaled.height) / 2,
        width: scaled.width,
        height: scaled.height
    ),
    from: .zero, operation: .sourceOver, fraction: 1
)

// 3. A scrim from the left, so the type sits on something dark whatever the artwork does there.
// Type over a busy background is the one thing that makes a card look amateur at thumbnail size.
if let gradient = NSGradient(colors: [
    ground.withAlphaComponent(0.97),
    ground.withAlphaComponent(0.86),
    ground.withAlphaComponent(0.0),
]) {
    gradient.draw(in: NSRect(origin: .zero, size: size), angle: 0)
}

// 4. The name, the sentence, and what it runs on.
func draw(_ text: String, font: NSFont, colour: NSColor, at point: NSPoint, width: CGFloat) -> CGFloat {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = font.pointSize * 0.22
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: colour, .paragraphStyle: paragraph,
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let bounds = string.boundingRect(
        with: NSSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    string.draw(with: NSRect(x: point.x, y: point.y - bounds.height, width: width, height: bounds.height),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
    return bounds.height
}

let column = size.width * 0.56
var cursor = size.height - margin - 34

// The wordmark, which already carries the mark and the name. The app icon is not drawn beside it:
// the same symbol twice in one card reads as a mistake, and it is the mark plus the word that
// people recognise, not either alone.
if let wordmark = NSImage(contentsOf: root.appendingPathComponent("Resources/logo-dark.png")) {
    let width: CGFloat = 360
    let height = width * (wordmark.size.height / wordmark.size.width)
    wordmark.draw(
        in: NSRect(x: margin - 6, y: cursor - height, width: width, height: height),
        from: .zero, operation: .sourceOver, fraction: 1
    )
    cursor -= height - 4
} else {
    let name = NSFont.systemFont(ofSize: 92, weight: .bold)
    cursor -= draw("Loadout", font: name, colour: ink, at: NSPoint(x: margin, y: cursor), width: column) + 26
}

let sentence = NSFont.systemFont(ofSize: 31, weight: .regular)
cursor -= draw(
    "See and manage what your coding assistants load.",
    font: sentence, colour: inkSoft, at: NSPoint(x: margin, y: cursor), width: column
) + 34

// The footer line: what it is for, in the fewest words that are still true.
let footer = NSFont.monospacedSystemFont(ofSize: 21, weight: .medium)
_ = draw(
    "skills · commands · subagents · MCP",
    font: footer, colour: accent, at: NSPoint(x: margin, y: cursor), width: column
)

// A rule under the type, the width of the sentence, in the accent — the one flourish.
accent.withAlphaComponent(0.55).setFill()
NSRect(x: margin, y: margin - 6, width: 132, height: 3).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    print("não consegui ler o que foi desenhado")
    exit(1)
}

// Down the quality until it fits, rather than shipping something GitHub will refuse. It starts
// high enough that it never usually gets past the first step.
var data: Data?
for quality in [0.92, 0.85, 0.78, 0.7, 0.6] {
    guard let attempt = rep.representation(
        using: .jpeg, properties: [.compressionFactor: quality]
    ) else { continue }
    data = attempt
    if attempt.count <= sizeLimit { break }
}

guard let jpeg = data else {
    print("não consegui codificar a imagem")
    exit(1)
}

try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true
)
try jpeg.write(to: output)
print("✓ \(output.path) (\(jpeg.count / 1024) KB, \(Int(size.width))×\(Int(size.height)) points)")
if jpeg.count > sizeLimit {
    print("  aviso: passou o limite de 1 MB do GitHub, que vai recusá-la")
}
