import AppKit
import SwiftUI

/// Puts a pane to sleep behind frosted glass, in a form that can be photographed.
///
/// The obvious way to do this is `.ultraThinMaterial`, and that is what the first attempt used. It
/// looks right and it costs nothing to write, but it is drawn by a layer tree the app's own frame
/// capture cannot read: `WindowRecorder` fell silent the moment Settings opened, which is the same
/// reason the recorder has never been able to photograph a sheet. A screen nobody can photograph is
/// a screen nobody can check without sitting at the keyboard, and this one is checked far more
/// often by a script than by a person.
///
/// So the blur is taken once, off the view itself, and what is laid over the pane is an image. An
/// image is just pixels — the recorder reads it like anything else. It also cannot go stale in a way
/// that matters: while the pane is inert nothing underneath is changing.
///
/// `reduceTransparency` is honoured with a flat fill and no blur at all. That path is also the
/// fallback when the snapshot fails for any reason, so the worst case is a plain quiet pane rather
/// than a pane that looks live but ignores the mouse.
struct FrostedPause: ViewModifier {
    /// Whether the pane is asleep.
    let active: Bool

    @AppStorage("reduceTransparency") private var reduceTransparency = false
    @State private var frost: NSImage?

    func body(content: Content) -> some View {
        content
            .disabled(active)
            .overlay {
                if active {
                    scrim
                        .transition(.opacity)
                        // The scrim is the thing that swallows clicks. The `disabled` above stops
                        // the controls responding; this stops the pointer even reaching them, so
                        // there is no hover flicker on a pane that is meant to be resting.
                        .contentShape(Rectangle())
                        .onTapGesture {}
                }
            }
            .background {
                if !reduceTransparency {
                    // Reads the pane as it is now, so the frost matches what is under it rather
                    // than whatever was there the first time Settings opened.
                    FrostSnapshot(active: active) { frost = $0 }
                }
            }
    }

    @ViewBuilder
    private var scrim: some View {
        if let frost, !reduceTransparency {
            Image(nsImage: frost)
                .resizable()
                .scaledToFill()
                .clipped()
                .overlay(V2.window.opacity(0.45))
        } else {
            // No snapshot, or transparency turned down: flat, and legible, and honest about it.
            V2.well.opacity(reduceTransparency ? 1 : 0.94)
        }
    }
}

extension View {
    /// See `FrostedPause`. Named for what it does to the pane rather than for the effect, because
    /// the effect is the part that may have to change again.
    func frostedPause(_ active: Bool) -> some View {
        modifier(FrostedPause(active: active))
    }
}

/// Takes one blurred picture of the view it is behind, each time the pause begins.
private struct FrostSnapshot: NSViewRepresentable {
    let active: Bool
    let onCapture: (NSImage?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard active, context.coordinator.lastActive != true else {
            context.coordinator.lastActive = active
            return
        }
        context.coordinator.lastActive = true
        // Next turn of the run loop: during `updateNSView` the pane is mid-layout, and reading it
        // now returns a half-drawn frame.
        DispatchQueue.main.async { [onCapture] in
            onCapture(Self.blurredSuperview(of: view))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastActive: Bool?
    }

    /// The pane, drawn into a bitmap and blurred with Core Image. `cacheDisplay` is the same call
    /// the recorder makes, so anything it can read here it can read there.
    private static func blurredSuperview(of view: NSView) -> NSImage? {
        guard let target = view.superview, target.bounds.width > 1, target.bounds.height > 1,
              let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds)
        else { return nil }
        rep.size = target.bounds.size
        target.cacheDisplay(in: target.bounds, to: rep)

        guard let input = rep.cgImage.map(CIImage.init(cgImage:)),
              let blur = CIFilter(name: "CIGaussianBlur")
        else { return nil }
        // Clamped *before* the blur, then cropped back after it. The comment claimed both and the
        // code only cropped: a Gaussian blur samples beyond the edges, finds transparency there, and
        // fades the frost out along its own border — the seam this is meant to prevent. Clamping
        // extends the edge pixels outwards so there is something to sample.
        blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        blur.setValue(18.0, forKey: kCIInputRadiusKey)
        guard let blurred = blur.outputImage?.cropped(to: input.extent) else { return nil }

        let image = NSImage(size: target.bounds.size)
        image.addRepresentation(NSCIImageRep(ciImage: blurred))
        return image
    }
}
