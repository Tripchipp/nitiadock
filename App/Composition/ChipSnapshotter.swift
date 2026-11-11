import AppKit
import QuartzCore
import SwiftUI

/// Renders a chip synchronously into a bitmap for `DragController` to use as the floating copy.
///
/// **The snapshot must draw "the same view as the slot"**, otherwise the overlap on the drag-start frame and
/// the handover on the landing frame both show. The way to guarantee this is not a lookup table of "which
/// source draws which view": that is a second truth to sync by hand, and this repo has been bitten twice by
/// "a call site forgot an argument and it still compiled" (`ChipView.scale` silently rendering at the middle
/// level, the messaging zone having no name bubble at all). Instead, **the view that renders the slot takes
/// the snapshot itself, with the same function it uses to render the slot**
/// (`DockStripView.stripEntryContent` / `DrawerView.drawerChip`), passing only "hover" as false. So
/// "identical" holds by construction and cannot drift.
///
/// The implementation uses `NSHostingView` + `cacheDisplay`, **not `ImageRenderer`**. Three measured findings
/// (2026-08-18 spike, macOS 26.5):
///
/// 1. When `ImageRenderer` meets an `NSViewRepresentable` it paints that whole rect an opaque placeholder
///    yellow `(255, 204, 0)`. `ChipView` carries `.nativeContextMenu` (= `overlay(NativeMenuHost)`), so the
///    whole card becomes a yellow brick. Of the four combinations, the two with a representable both have an
///    average alpha of 255.
/// 2. `cacheDisplay` is completely immune to representables (the share of non-transparent pixels is identical
///    with or without one), transparency is preserved, and it **exists on macOS 12**. One path covers every
///    deployment target, with no version branch and no degraded drawing for 12.
/// 3. Cost: median 0.59ms, P95 0.87ms (budget 8ms). First call 0.74ms, no cold-start penalty.
enum ChipSnapshotter {
    /// The extra margin around the snapshot.
    ///
    /// Some things in a card **overflow the layout frame**: the stroke halo of folder names
    /// (`theme.labelHalo`) and the antialiased edges at each size level. On the bar that is fine (other cards
    /// are next to it and nothing clips it), but clipping the snapshot to the layout frame cuts them off, and
    /// the landing frame no longer matches the card on the bar. 6pt is enough for the largest level.
    ///
    /// (This used to say "room for the icon shadow". The icons' outer shadow was removed entirely on
    /// 2026-08-19, but the margin still has to stay, now for the reason above.)
    static let bleed: CGFloat = 6

    /// Backing scale used for rendering: that of **the display the slot is on**, no more, no less.
    ///
    /// "Take the largest of all displays" was a trap (2026-08-19): an image captured at 2x is downscaled and
    /// resampled for the whole drag on a 1.6x external display, slightly blurrier than the card on the bar,
    /// and only turns sharp when the real card replaces it on the last landing frame. Bitmap pixels = this
    /// display's pixels, plus the layer origin aligned to the pixel grid
    /// (`DragCarrierGeometry.pixelAligned`), is what makes CA move pixels 1:1.
    ///
    /// What is actually used is the backing scale **reported by the host window** (see
    /// `hostWindow(forScreenPoint:)`). That is the resolution the layer is really rasterized at, and the
    /// bitmap must match it; this function only puts the window on the right display.
    static func renderScale(forScreenPoint point: CGPoint) -> CGFloat {
        screen(forScreenPoint: point)?.backingScaleFactor.clampedToAtLeastOne ?? 2
    }

    private static func screen(forScreenPoint point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    /// Offscreen host window used only for snapshots. **Without a window it is always blurry.**
    ///
    /// The sublayers SwiftUI builds inside an `NSHostingView` take their `contentsScale` from the **window**;
    /// when the view is not in a window it is always `1.0`, so `cacheDisplay` goes through
    /// `CALayer.render(in:)`, rasterizes at 1x and scales up into the 2x rep. The copy is then slightly
    /// blurrier than the card on the bar for the whole drag and only turns sharp when the real card replaces
    /// it on landing (reported 2026-08-19: "the icon has a faint blur while dragging, and the blur only goes
    /// away after landing").
    ///
    /// Measured one by one in a spike on 2026-08-19 (same Calendar icon, sharpness = Laplacian variance):
    /// - Direct `NSImage.draw` into a 2x context (theoretical ceiling): **5430**
    /// - Bare `NSHostingView` + `cacheDisplay` as it was: **2274** (≈ blurred once at σ 0.5px)
    /// - Setting `contentsScale = 2` after capture: still 2274. **The content was already rasterized at 1x,
    ///   changing the flag does nothing**
    /// - Setting `contentsScale` then `setNeedsDisplay` + `displayIfNeeded`: **0** (a fully empty image,
    ///   worse)
    /// - Capturing after attaching to a window: **5430**, byte-identical to the ceiling
    ///
    /// The window is **never ordered on screen** (measured: it still reports a backing scale of 2.0 and a
    /// sharpness of 5430 without being on screen), so there is no risk of a flash; its only job is to give
    /// the layers a backing scale source. The same window is reused so one is not created for every snapshot.
    @MainActor
    private static func hostWindow(forScreenPoint point: CGPoint, fitting: CGSize) -> NSWindow {
        let window = sharedHostWindow ?? {
            let made = NSWindow(contentRect: CGRect(origin: .zero, size: defaultHostSize),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            made.isOpaque = false
            made.backgroundColor = .clear
            made.hasShadow = false
            made.ignoresMouseEvents = true
            made.isExcludedFromWindowsMenu = true
            made.alphaValue = 0            // Belt and braces: fully transparent even if it is ever ordered by mistake
            made.contentView = NSView(frame: CGRect(origin: .zero, size: defaultHostSize))
            sharedHostWindow = made
            return made
        }()
        // **Grow only when it does not fit, don't resize every time.** Changing the window size costs a trip
        // to WindowServer: measured, calling `setContentSize` on every snapshot pushes the cost from 0.6ms to
        // 4.4ms (max 11.7ms, over the 8ms budget), and this path runs on **mouse down** (`prepareCandidate`).
        // A large enough canvas that is reused avoids that cost.
        let current = window.contentView?.bounds.size ?? .zero
        if fitting.width > current.width || fitting.height > current.height {
            let grown = CGSize(width: max(fitting.width, current.width),
                               height: max(fitting.height, current.height))
            window.setContentSize(grown)
            window.contentView?.frame = CGRect(origin: .zero, size: grown)
        }
        // Place it on the target display: the backing scale follows the display the window is on, and with
        // displays of different resolutions this step cannot be skipped.
        if let screen = screen(forScreenPoint: point), window.frame.origin != screen.frame.origin {
            window.setFrameOrigin(screen.frame.origin)
        }
        return window
    }
    @MainActor private static var sharedHostWindow: NSWindow?
    /// Initial canvas size: fits the largest level's title card (about 200×70) with room to spare, so it
    /// normally never needs to grow.
    private static let defaultHostSize = CGSize(width: 400, height: 160)

    /// - Parameter screenPoint: the slot's position on screen (it decides which display's backing scale is
    ///   used).
    @MainActor
    static func snapshot<Content: View>(of content: Content, screenPoint: CGPoint) -> CarrierSnapshot? {
        let started = CACurrentMediaTime()
        let result = render(content, screenPoint: screenPoint)
        HoverTrace.carrierSnapshot(ms: (CACurrentMediaTime() - started) * 1000,
                                   width: result?.size.width ?? 0,
                                   height: result?.size.height ?? 0,
                                   ok: result != nil)
        return result
    }

    @MainActor
    private static func render<Content: View>(_ content: Content, screenPoint: CGPoint) -> CarrierSnapshot? {
        let host = NSHostingView(rootView: SnapshotRoot(content: AnyView(content)))
        // `fittingSize` forces SwiftUI layout **synchronously** (the first-frame transaction at launch has
        // long relied on this), so what we get here is the size this card takes on the bar, with no need to
        // wait for the next run loop turn.
        let fitting = host.fittingSize
        guard fitting.width > 0, fitting.height > 0 else {
            dismantle(host)
            return nil
        }
        let logical = CGSize(width: fitting.width + 2 * bleed, height: fitting.height + 2 * bleed)
        // **Enter the window first, then lay out**: a sublayer's `contentsScale` is fixed the moment it is
        // attached to a window, so the reverse order is wasted (see `hostWindow(forScreenPoint:)` for the
        // reasons and measurements). The window size follows the card: `contentView` is stretched to the
        // content size by the window, so without setting the window size first `host.frame` would be
        // overwritten.
        let window = hostWindow(forScreenPoint: screenPoint, fitting: logical)
        // Attached as a **subview**, not as `contentView`: the latter is stretched to the content size by the
        // window, so every card would need a window resize.
        host.frame = CGRect(origin: .zero, size: fitting)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        defer { host.removeFromSuperview() }      // Release this tree, don't leave it on the window across snapshots
        // **Bitmap resolution comes from what the window reports**, not from the screen: the layer is
        // rasterized at the window's scale and the two must match, otherwise it is back to resampling because
        // "the bitmap and the layer are not 1:1".
        let scale = window.backingScaleFactor.clampedToAtLeastOne
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((logical.width * scale).rounded()),
            pixelsHigh: Int((logical.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            dismantle(host)
            return nil
        }
        // **`bitmapImageRepForCachingDisplay(in:)` cannot be used**: it picks the resolution from the display
        // the view is currently on (the main display when not in a window), which is wrong with displays of
        // different resolutions. Building the rep by hand and setting `size` to the logical size is what puts
        // the scale under our control.
        rep.size = logical
        host.cacheDisplay(in: CGRect(x: -bleed, y: -bleed,
                                     width: logical.width, height: logical.height),
                          to: rep)
        dismantle(host)
        guard let drawn = rep.cgImage, let image = detached(drawn) else { return nil }
        // The layer's logical size is "pixel count / scale", not `logical`: on a 1.6x display 52pt is 83.2px,
        // the bitmap can only be 83px, and placing it at 52pt would resample; placing it at 83/1.6 = 51.875pt
        // is 1:1.
        let exact = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return CarrierSnapshot(image: image, size: exact, contentSize: fitting, scale: scale)
    }

    /// **The bitmap must be copied into an image that owns its backing store.**
    ///
    /// The `CGImage` returned by `NSBitmapImageRep.cgImage` **shares its pixel buffer** with that rep. The
    /// rep is a local variable here and is released as soon as it leaves scope, so `CALayer.contents` gets an
    /// image pointing at freed memory. The symptom is highly misleading: `contents != nil`, `bounds` /
    /// `position` / `opacity` / hierarchy all correct, no self-check fires, and **there is simply nothing on
    /// screen** (measured 2026-08-19: the carrier was invisible for the whole drag, while the same code
    /// worked in the spike because there the image was written to disk while the rep was still alive).
    ///
    /// `CGContext.makeImage()` returns a **snapshot** of the current bitmap with its own backing store, no
    /// longer tied to the context.
    private static func detached(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// **The tree must be torn down explicitly after the capture.**
    ///
    /// Measured: an `NSHostingView` without a window still fires `onAppear` but **never** fires
    /// `onDisappear`. `LauncherChip`'s launch bounce installs a `repeats: true` timer in `onAppear` and
    /// removes it in `onDisappear`, so every snapshot of a launching icon leaves behind a timer that never
    /// stops (in the spike, 5 snapshots ticked 40 times in 0.4 seconds). Setting the root view's content to
    /// nil and forcing one more layout makes SwiftUI run `onDisappear` synchronously; the bitmap already
    /// captured is unaffected.
    @MainActor
    private static func dismantle(_ host: NSHostingView<SnapshotRoot>) {
        host.rootView = SnapshotRoot(content: nil)
        host.layoutSubtreeIfNeeded()
    }
}

private extension CGFloat {
    /// backing scale fallback: on 0 / a negative number (should not happen in theory) use 1, so the bitmap
    /// size does not compute to 0.
    var clampedToAtLeastOne: CGFloat { self < 1 ? 1 : self }
}

/// Clearable host root view. Setting the content to nil means "this subtree is gone", which gives
/// `onDisappear` a chance to run.
struct SnapshotRoot: View {
    var content: AnyView?

    var body: some View {
        ZStack { if let content { content } }
            // **The drag-copy switch is set only here.** The four snapshot call sites go through
            // `stripEntryContent` / `drawerChipContent`, and those two helpers also render the real cards;
            // passing it as an argument would mean adding parameters with default values to them, and "forgot
            // to pass it and it still compiled" is exactly where this repo has tripped twice
            // (`ChipView.scale` silently at the middle level, the messaging zone having no name bubble at
            // all). Placed here, the existing four sites and any future snapshot are covered automatically
            // and cannot be forgotten.
            //
            // The project rule that "environment values cannot refresh a long-lived hosting root" does not
            // apply: the snapshot host is built and torn down each time.
            .environment(\.isDragCarrierSnapshot, true)
    }
}
