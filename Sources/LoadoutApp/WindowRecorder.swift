import AppKit
import Foundation

/// Records the app's own window to a sequence of PNGs, for the README's animation.
///
/// Deliberately not a screen recording. Capturing the *screen* needs the Screen Recording
/// permission, which a headless build has no way to be granted and no way to click through. An app
/// drawing its **own** window needs nothing at all — `bitmapImageRepForCachingDisplay` reads the
/// window's backing store, which already belongs to this process.
///
/// The result is the real interface, at real times, with whatever the assistant really said. It is
/// not a mock-up, and it must never become one: a picture of a program that does not exist is the
/// most expensive kind of lie a README can tell.
@MainActor
final class WindowRecorder {
    private let directory: URL
    private var timer: Timer?
    private var frame = 0
    private let scale: CGFloat
    /// When recording began, and one line per frame saying how long after that it was taken.
    ///
    /// Capturing a window is not free, and it competes with the app doing the thing being recorded,
    /// so frames do not arrive at an even rate — during a busy stretch they thin out. Playing them
    /// back at a fixed rate turns that into a lie: the busiest, most interesting part plays fastest.
    /// The times are written down so the animation can be assembled at the speed it really happened.
    private let started = Date()
    private var timings: [String] = []
    /// One line per step of a walkthrough: when it happened, what it was about, and the rectangle
    /// that thing occupied on screen. Nothing here changes the frames — it is what lets a cursor
    /// and a zoom be drawn on afterwards without anyone guessing at coordinates.
    private var marks: [String] = []

    /// - Parameters:
    ///   - directory: where the frames are written, one `frame-0000.png` per tick.
    ///   - fps: how many frames a second. Twelve reads as motion and keeps a README GIF small.
    ///   - scale: 1 for actual points, 2 for Retina pixels. The GIF is scaled down afterwards, so
    ///     1 is usually the right answer and a quarter of the bytes.
    init(directory: URL, fps: Double = 12, scale: CGFloat = 1) {
        self.directory = directory
        self.scale = scale
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A timer rather than a display link: the window is mostly still, and a missed frame in a
        // README animation costs nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        // Without this the timer stops the moment a menu or a sheet takes over the run loop.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    /// The window as PNG bytes, or nil when there is no window worth reading yet.
    ///
    /// The window itself, never an attached sheet: a sheet's content is drawn by a layer tree this
    /// cannot read, and capturing it produced blank white frames — worse than the window underneath,
    /// which at least shows something true.
    ///
    /// Static, because one-off photographs want it too: a driven step whose whole result is a layout
    /// — the fact cards folding and the document rising into the space — can only be checked by
    /// looking, and re-implementing the capture beside this one is how the two drift apart.
    static func windowPNG() -> Data? {
        let candidates = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        guard let window = candidates.first(where: { $0.isKeyWindow && $0.attachedSheet == nil })
                ?? candidates.first,
              let view = window.contentView,
              view.bounds.width > 1, view.bounds.height > 1
        else { return nil }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: NSBitmapImageRep.FileType.png, properties: [:])
    }

    /// One frame, to a path somebody named. True when a picture was written.
    @discardableResult
    static func writeWindow(to url: URL) -> Bool {
        guard let data = windowPNG() else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try data.write(to: url)
            return true
        } catch {
            return false
        }
    }

    private func capture() {
        guard let data = Self.windowPNG() else { return }
        let name = String(format: "frame-%04d.png", frame)
        try? data.write(to: directory.appendingPathComponent(name))
        timings.append(String(format: "%@ %.3f", name, Date().timeIntervalSince(started)))
        frame += 1
    }

    /// Writes down that a step landed on `key`, at `rect`, now.
    func mark(_ key: String, _ rect: CGRect) {
        marks.append(String(
            format: "%.3f %@ %.1f %.1f %.1f %.1f",
            Date().timeIntervalSince(started), key,
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
        ))
    }

    /// Stops recording and returns how many frames were written.
    @discardableResult
    func finish() -> Int {
        timer?.invalidate()
        timer = nil
        try? timings.joined(separator: "\n").write(
            to: directory.appendingPathComponent("timing.txt"), atomically: true, encoding: .utf8
        )
        try? marks.joined(separator: "\n").write(
            to: directory.appendingPathComponent("marks.txt"), atomically: true, encoding: .utf8
        )
        return frame
    }
}
