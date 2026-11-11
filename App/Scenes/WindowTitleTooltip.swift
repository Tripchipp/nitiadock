import AppKit
import os
import SwiftUI

/// Metrics for **the window title line inside the pill** on the bar. Serves pill layout only: how wide it
/// grows and its maximum width.
///
/// 2026-08-17: removed `isTruncated` / `needsTooltip` / `truncationTolerance`. They were the threshold for
/// "show a tooltip only when the title is truncated"; the bubble first became "show on hover" and then "app
/// name only", so truncation no longer affects any behavior and no production caller is left. For the full
/// window title see `.help(fullTitle)` on both `ChipView` branches (system tooltip fallback).
///
/// Corrected 2026-09-04: until then this said "`.help(displayTitle)`" and only `bareIconChip` actually
/// attached it, so a truncated titled card showed its full title nowhere (issue #41). Both branches attach it
/// now, and it is the full title **with the app-name suffix kept**.
enum WindowTitleTextMetrics {
    /// Maximum width of the in-bar title (medium tier baseline). Once the taskbar is scaled, always go
    /// through `maximumWidth(for:)`; do not write another literal at the call site: two separate copies once
    /// made the pill and the check disagree.
    static let maximumWidth: CGFloat = 140

    /// fork: the cap comes from the Appearance overrides (max card width / title mode). Untouched it
    /// is `maximumWidth` above; "Fit to text" makes it effectively infinite, which every caller
    /// already handles because they all take `min(intrinsic, cap)` or compare against it.
    static func maximumWidth(for scale: CGFloat) -> CGFloat {
        let cap = ForkAppearanceModel.current.resolvedTitleCap()
        return cap == .greatestFiniteMagnitude ? cap : cap * scale
    }

    /// fork: the single place the title's point size is decided. `ChipView` draws with it and
    /// `font(scale:)` measures with it, so an Appearance font offset can never split the two.
    static func fontSize(scale: CGFloat) -> CGFloat {
        ForkAppearanceModel.current.resolvedTitleFontSize(upstream: max(10, 12 * scale))
    }

    static func font(scale: CGFloat) -> NSFont {
        let size = fontSize(scale: scale)
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else {
            return base
        }
        return rounded
    }

    static func intrinsicWidth(of title: String, scale: CGFloat) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: font(scale: scale)]).width
    }

}

/// Curve for label width changes. Drives only the in-bar `LabelBoxWidthDriver`; the panel backing runs no
/// animation of its own, instead the follow window of `PanelCoordinator.beginLabelWidthFollow` measures the
/// content width every frame and sets the frame directly (in sync by construction).
///
/// Default: gentle start, long tail ("soft", 2026-09-12). `DOCK_LABEL_ANIM="ms,c1x,c1y,c2x,c2y"` tries other
/// values without a reinstall, read once at process launch; once chosen, change `defaultCurve`. The follow
/// window's duration follows `curve.duration`.
enum LabelWidthAnimation {
    struct Curve: Equatable {
        let duration: TimeInterval
        let c1x: Double, c1y: Double, c2x: Double, c2y: Double
    }

    static let defaultCurve = Curve(duration: 0.60, c1x: 0.5, c1y: 0, c2x: 0.15, c2y: 1)   // 2026-09-13: slow start, long overall
    static let curve: Curve = parse(DebugSwitch.labelAnim.value()) ?? defaultCurve

    static var swiftUI: Animation {
        .timingCurve(curve.c1x, curve.c1y, curve.c2x, curve.c2y, duration: curve.duration)
    }


    /// "ms,c1x,c1y,c2x,c2y" -> curve; bad format, non-positive duration or control point x out of range
    /// (Bezier requires 0...1) -> nil, use the default.
    static func parse(_ raw: String?) -> Curve? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 5, let ms = parts[0], let c1x = parts[1], let c1y = parts[2],
              let c2x = parts[3], let c2y = parts[4], ms > 0,
              (0...1).contains(c1x), (0...1).contains(c2x) else { return nil }
        return Curve(duration: ms / 1000, c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y)
    }
}

/// Layout constants for the "pill" of a titled window card. **Rendering and derivation must share them**: the
/// tooltip anchor contract is the pill rect (see `PanelGeometry.windowTitleTooltipTargetFrame`), while the
/// screen-coordinate probe measures the whole card's rect to avoid the press scale, so the pill rect can only
/// be derived from these constants. Two copies drift apart sooner or later, same reason as
/// `WindowTitleTextMetrics`.
enum ChipPillMetrics {
    /// Total card height (= panel content height, `DockSize` medium tier baseline). **Must equal
    /// `DockSize.medium.panelHeight`**: the card fills the bar height with no gap above or below, and the
    /// right-click test for the taskbar's blank area relies on "no vertical gap". Changed 2026-08-16 along
    /// with medium 52->54.
    static let chipHeight: CGFloat = 54
    /// Height of the pill's layout box. **No longer changes on hover** (2026-08-16: the app name moved into
    /// the bubble above the icon, so the pill no longer has to make room).
    static let boxHeight: CGFloat = 34
    static let horizontalPadding: CGFloat = 10
    /// Extra space on both sides of the pill in a titled window card.
    ///
    /// Icon cards get their visible gap from the transparent margin built into the icon asset; the pill has a
    /// solid background and cannot, so after `Style.chipSpacing` went from 8 to 2 (matching native icon
    /// spacing) two titled cards touched each other (2026-08-16: "make the gap between multi-window tabs
    /// larger"). Visible gap between two titled cards = `2 * titledCardInset + Style.chipSpacing` = 10pt,
    /// matching the visible gap between icons (measured 10pt).
    ///
    /// Applied to **the whole card**, not inside the pill: the pill size is a signed-off look, and
    /// `pillRect(inCard:)` derives the tooltip anchor from "the pill is horizontally centered in the card", a
    /// contract symmetric insets do not affect.
    static let titledCardInset: CGFloat = 4
    /// The icon's **layout** slot (the visual size 22->18 shrinks only within the slot; the slot is fixed, so
    /// the width does not change on hover).
    static let iconSlot: CGFloat = 22
    static let iconSpacing: CGFloat = 6

    /// Icon size of an untitled (icon-only) card: at rest = the native Dock's tilesize, shrinking on hover to
    /// make room for the app name.
    ///
    /// **`bareIconSlot` is also the height of the layout slot**: the `ZStack` in `ChipView` is `.top`
    /// aligned, so a slot smaller than the resting icon makes the whole icon overflow downward (2026-08-16:
    /// the icon went from 36 to 40 while the slot was still hardcoded to 36, and the icon measured 4pt lower
    /// in the card, with 12.5 / 8.0 padding above / below). Both must be the same constant.
    static let bareIconSlot: CGFloat = 40
    /// Size of the **square actually drawn** inside the icon slot.
    ///
    /// Apple's icon assets carry about 18% transparent margin (measured 2026-08-16: a 32.5pt visible square
    /// in a 40pt slot), which is where the visible gap between icons on the bar comes from. So **any shape we
    /// draw ourselves without a transparent margin** (the shelf glyph) must be drawn at this size, or it
    /// looks clearly larger than its neighbors: half of the reported "too jarring" was size, not just color.
    static let bareIconVisibleSlot: CGFloat = 32.5

    /// **Upper bound** of the whole-card scale on hover in the quiet tier (see `View.chipQuietHoverScale`).
    ///
    /// 1.10 does not make the visible pixels of adjacent icons collide: the card is 40 wide and the visible
    /// icon square only 32.5, scaled to 35.75 it is still inside the card with a bit over 2pt of transparent
    /// margin left on each side.
    ///
    /// **This argument covers icon cards only**, see `quietHoverScale(forCardWidth:scale:)` below.
    static let quietHoverScale: CGFloat = 1.10

    /// Maximum outward growth per side of a card when scaled on hover (unscaled, multiplied by the tier's
    /// `scale`).
    ///
    /// The visible gap between two titled cards is `2 * titledCardInset + Style.chipSpacing` = 10pt;
    /// with a 3pt budget, the worst case still leaves 7pt.
    static let quietHoverEdgeBudget: CGFloat = 3

    /// Scale factor clamped by card width.
    ///
    /// **The absolute displacement of a proportional scale follows the card width, so "the same 1.10" was
    /// never "the same amount of feedback".** Reported 2026-08-17: "very wide tabs push into the neighboring
    /// tab when scaled". Measured on that screenshot: an icon card 40pt wide -> 2.0pt outward per side; that
    /// titled card 168.5pt wide -> **8.4pt** per side (4x), eating the 10pt gap down to 3.5pt. The argument
    /// for `quietHoverScale` above does not cover titled cards at all.
    ///
    /// The fix caps the **outward growth per side** instead of branching on card type: an icon card computes
    /// to 1.15 and is clamped back to 1.10 (**not one pixel changes**); only cards wide enough to crowd are
    /// reduced. One rule covers all four card kinds, and a future kind cannot miss a branch.
    ///
    /// The ratio is tier-independent (budget and card width are both multiplied by `scale`); it is spelled
    /// out because callers pass the scaled card width.
    static func quietHoverScale(forCardWidth width: CGFloat, scale: CGFloat) -> CGFloat {
        guard width > 0 else { return quietHoverScale }
        return min(quietHoverScale, 1 + 2 * quietHoverEdgeBudget * scale / width)
    }
    /// Card width of an icon-only card. **Center spacing = `cardWidth + Style.chipSpacing`; consider the two
    /// together.** Measured 2026-08-16: the native Dock's icon center spacing is 42pt (40 tile + 2pt gap),
    /// NitiaDock used to be 52pt (44 + 8), much sparser; changed to 40 + 2 to match. The card width equals
    /// the icon size, so the icon has no extra horizontal room, same as native; the visible gap comes from
    /// the transparent margin built into the icon asset.
    static let cardWidth: CGFloat = 40

    /// Spacing between cards. **Defined here and referenced by `Style.chipSpacing`**: hover ownership
    /// resolution (the gap bridging amount in `StripHoverResolution`) needs it too, and `Style` is private
    /// and unreadable from other files; two separate literal 2s would drift apart.
    ///
    /// 2pt: matches the native Dock's 42pt icon center spacing. **Changing it requires changing
    /// `StripContextMenuZone.defaultMinimumGapWidth` too**: that threshold must fall strictly between an
    /// "ordinary gap" and a "separator gap", or right-click on the taskbar's blank area stops working
    /// entirely.
    static let chipSpacing: CGFloat = 2

    /// Center spacing of icon cards (native measured 42pt). Only tests read it for now: it locks
    /// the identity "card width + spacing = native 42" and fails immediately when width or spacing changes.
    static let iconPitch: CGFloat = cardWidth + chipSpacing

    // MARK: Unread badge (`ChipBadgeView`)
    //
    // Medium tier = the literals below, identical to before 2026-08-17; other tiers multiply everything by
    // `scale`. Before that these numbers were hardcoded, **the same size on all four tiers**: the red dot was
    // too small on a 70pt bar and too large on 46pt. Same kind of miss as the hover bubble (project rule
    // "Taskbar Size Tiers": every render path inside the bar must apply `scale`).
    static let badgeFontSize: CGFloat = 10
    /// Minimum size of the badge capsule (its size with a single digit).
    static let badgeMinimumSize: CGFloat = 16
    static let badgeHorizontalPadding: CGFloat = 5
    /// Offset downward from the card's top-right corner: the native badge mostly sits on the icon and only
    /// slightly pokes past the rounded corner.
    static let badgeTopOffset: CGFloat = 5
    /// Badge scale on a titled window card (relative to the icon card's badge). The icon slot in the pill is
    /// only 22pt, and a full-size 16pt badge would cover most of the icon; 0.8 -> 12.8pt, and the 8pt font is
    /// still readable.
    static let titledCardBadgeScale: CGFloat = 0.8

    /// Distance from the pill box's top edge to the card's top edge: two `Spacer`s split `chipHeight -
    /// boxHeight` evenly.
    static let boxTopInset: CGFloat = (chipHeight - boxHeight) / 2

    static func height(scale: CGFloat) -> CGFloat { boxHeight * scale }

    /// Width of the label box: the title's actual rendered width (capped by `WindowTitleTextMetrics`) rounded
    /// up.
    ///
    /// `ChipView.multiWindowChip` uses it to give the label an **explicit** width instead of letting `Text`
    /// size itself: when the label grows or shrinks this width interpolates with the taskbar layout
    /// animation, while the text swaps by identity and does not reflow at intermediate widths. It also makes
    /// the rendered pill width match `width(title:scale:)` below pt for pt.
    static func labelWidth(title: String, scale: CGFloat) -> CGFloat {
        // fork: upstream's `ceil(min(intrinsic, cap))` unless equal-width cards is on.
        ForkAppearanceModel.current.resolvedLabelWidth(
            intrinsic: WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale),
            cap: WindowTitleTextMetrics.maximumWidth(for: scale)
        )
    }

    /// Whether the title exceeds the cap and needs truncation. If so, `Text` gets the cap width and adds its
    /// own ellipsis; otherwise `Text` draws at its natural width (no fixed width: the text width SwiftUI
    /// measures can be a fraction of a pt more than AppKit's, and a fixed width would turn the last character
    /// into an ellipsis).
    static func labelTruncates(title: String, scale: CGFloat) -> Bool {
        WindowTitleTextMetrics.intrinsicWidth(of: title, scale: scale)
            > WindowTitleTextMetrics.maximumWidth(for: scale)
    }

    /// Pill width = left and right padding + icon slot + spacing + label box width.
    static func width(title: String, scale: CGFloat) -> CGFloat {
        (2 * horizontalPadding + iconSlot + iconSpacing) * scale + labelWidth(title: title, scale: scale)
    }

    /// Derives the pill's screen rect from the stable card screen rect (macOS screen coordinates, y up). The
    /// pill is horizontally centered in the card, so `midX` is the card's; the vertical values all come from
    /// the constants above.
    static func pillRect(
        inCard card: CGRect,
        title: String,
        scale: CGFloat
    ) -> CGRect {
        let pillHeight = height(scale: scale)
        let topY = card.maxY - boxTopInset * scale
        let pillWidth = width(title: title, scale: scale)
        return CGRect(
            x: card.midX - pillWidth / 2,
            y: topY - pillHeight,
            width: pillWidth,
            height: pillHeight
        )
    }
}


/// Chip visuals on hover. **Geometry is constant; only the "I am on this" highlight follows the progress.**
///
/// Before 2026-08-16 three more things were interpolated here: bare icon 40->26, pill box 34->28, icon in the
/// pill 22->18, plus an app-name line growing from zero width. **The only reason for that shrinking was to
/// make room for the name line below the icon.** Once the name became a native-Dock-style "bubble right above
/// the icon" (2026-08-16), the reason was gone: natively the icon neither shrinks nor moves on hover. Keeping
/// it would only make the whole bar jitter as the mouse sweeps across.
///
/// Also retired: the displacement formulas of `ChipSubtitleMetrics` (`pillHoverShift` / `subtitleShift`),
/// obtained by solving against the old `VStack(spacing: 2)` layout. **Do not bring them back.**
struct ChipHoverVisual: Equatable {
    let progress: CGFloat
    let bareIconSize: CGFloat
    let pillHeight: CGFloat
    let pillIconSize: CGFloat
    /// How emphasized the pill fill and stroke are. This is the **only** quantity that still changes on
    /// hover.
    let emphasisProgress: Double

    static func resolve(progress rawProgress: CGFloat, scale: CGFloat) -> ChipHoverVisual {
        let progress = min(max(rawProgress, 0), 1)
        return ChipHoverVisual(
            progress: progress,
            bareIconSize: ChipPillMetrics.bareIconSlot * scale,
            pillHeight: ChipPillMetrics.boxHeight * scale,
            pillIconSize: ChipPillMetrics.iconSlot * scale,
            emphasisProgress: Double(progress)
        )
    }
}

struct ChipHoverProgress<Content: View>: View, Animatable {
    var progress: CGFloat
    let content: (CGFloat) -> Content

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    init(progress: CGFloat, @ViewBuilder content: @escaping (CGFloat) -> Content) {
        self.progress = progress
        self.content = content
    }

    var body: some View {
        content(min(max(progress, 0), 1))
    }
}

enum ChipAnimationTrace {
    private static let enabled = DebugSwitch.chipAnimTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    private static let runtime = Runtime()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "no.thilip.nitiadock",
        category: "ChipAnimation"
    )

    static func record(
        chipID: String,
        kind: String,
        visual: ChipHoverVisual,
        isTapPressed: Bool,
        showsHover: Bool
    ) {
        guard enabled else { return }
        runtime.record(
            chipID: chipID,
            kind: kind,
            uptime: ProcessInfo.processInfo.systemUptime,
            visual: visual,
            state: ChipAnimationTraceState(isTapPressed: isTapPressed, showsHover: showsHover)
        )
    }

    static func event(
        chipID: String,
        kind: String,
        event: String,
        isTapPressed: Bool,
        showsHover: Bool
    ) {
        guard enabled else { return }
        runtime.event(
            chipID: chipID,
            kind: kind,
            uptime: ProcessInfo.processInfo.systemUptime,
            event: event,
            state: ChipAnimationTraceState(isTapPressed: isTapPressed, showsHover: showsHover)
        )
    }

    private final class Runtime: @unchecked Sendable {
        private let queue = DispatchQueue(label: "no.thilip.nitiadock.chip-animation-trace")
        private let fileManager = FileManager.default
        private var buffer = ChipAnimationTraceBuffer(capacity: 4_096)
        private var sessionByChip: [String: UUID] = [:]
        private var lastVisualByChip: [String: ChipHoverVisual] = [:]
        private var quiescenceGeneration: UInt64 = 0

        func record(
            chipID: String,
            kind: String,
            uptime: TimeInterval,
            visual: ChipHoverVisual,
            state: ChipAnimationTraceState
        ) {
            queue.async { [self] in
                let key = "\(kind)\u{0}\(chipID)"
                let isNewSession = sessionByChip[key] == nil
                let sessionID = sessionByChip[key] ?? UUID()
                sessionByChip[key] = sessionID
                lastVisualByChip[key] = visual
                appendSample(
                    sessionID: sessionID,
                    chipID: chipID,
                    kind: kind,
                    uptime: uptime,
                    visual: visual,
                    state: state,
                    event: isNewSession ? "sessionStart" : nil
                )
                scheduleExportAfterQuiescence()
            }
        }

        func event(
            chipID: String,
            kind: String,
            uptime: TimeInterval,
            event: String,
            state: ChipAnimationTraceState
        ) {
            queue.async { [self] in
                let key = "\(kind)\u{0}\(chipID)"
                let sessionID = sessionByChip[key] ?? UUID()
                sessionByChip[key] = sessionID
                appendSample(
                    sessionID: sessionID,
                    chipID: chipID,
                    kind: kind,
                    uptime: uptime,
                    visual: lastVisualByChip[key],
                    state: state,
                    event: event
                )
                scheduleExportAfterQuiescence()
            }
        }

        private func appendSample(
            sessionID: UUID,
            chipID: String,
            kind: String,
            uptime: TimeInterval,
            visual: ChipHoverVisual?,
            state: ChipAnimationTraceState,
            event: String?
        ) {
            buffer.append(ChipAnimationTraceSample(
                sessionID: sessionID,
                chipID: chipID,
                kind: kind,
                uptime: uptime,
                hoverProgress: visual.map { Double($0.progress) },
                bareIconSize: visual.map { Double($0.bareIconSize) },
                pillHeight: visual.map { Double($0.pillHeight) },
                pillIconSize: visual.map { Double($0.pillIconSize) },
                emphasisProgress: visual?.emphasisProgress,
                isTapPressed: state.isTapPressed,
                showsHover: state.showsHover,
                event: event
            ))
        }

        private func scheduleExportAfterQuiescence() {
            quiescenceGeneration &+= 1
            let generation = quiescenceGeneration
            queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.quiescenceGeneration == generation else { return }
                self.exportBufferedSamples()
            }
        }

        private func exportBufferedSamples() {
            let samples = buffer.drain()
            guard !samples.isEmpty else { return }
            sessionByChip.removeAll(keepingCapacity: true)
            lastVisualByChip.removeAll(keepingCapacity: true)

            do {
                let url = try traceFileURL()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                var payload = Data()
                for sample in samples {
                    payload.append(try encoder.encode(sample))
                    payload.append(0x0A)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: payload)
                let sessionCount = Set(samples.map(\.sessionID)).count
                ChipAnimationTrace.logger.info(
                    "exported samples=\(samples.count) sessions=\(sessionCount) path=\(url.path, privacy: .public)"
                )
            } catch {
                ChipAnimationTrace.logger.error("trace export failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        private func traceFileURL() throws -> URL {
            let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
            let directory = library
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("no.thilip.nitiadock", isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = directory.appendingPathComponent("chip-animation-trace.jsonl")
            if !fileManager.fileExists(atPath: url.path) {
                guard fileManager.createFile(
                    atPath: url.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            return url
        }
    }
}

struct ChipAnimationTraceState: Equatable {
    let isTapPressed: Bool
    let showsHover: Bool
}

enum ChipAnimationTraceEvent {
    static func hover(_ hovering: Bool) -> String { hovering ? "hoverEntered" : "hoverExited" }
    static func tap(_ pressed: Bool) -> String { pressed ? "tapPressed" : "tapReleased" }
}

struct ChipAnimationTraceSample: Codable, Equatable {
    let sessionID: UUID
    let chipID: String
    let kind: String
    let uptime: TimeInterval
    let hoverProgress: Double?
    let bareIconSize: Double?
    let pillHeight: Double?
    let pillIconSize: Double?
    let emphasisProgress: Double?
    let isTapPressed: Bool
    let showsHover: Bool
    let event: String?
}

struct ChipAnimationTraceBuffer {
    let capacity: Int
    private(set) var samples: [ChipAnimationTraceSample] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func append(_ sample: ChipAnimationTraceSample) {
        if samples.count == capacity {
            samples.removeFirst()
        }
        samples.append(sample)
    }

    mutating func drain() -> [ChipAnimationTraceSample] {
        defer { samples.removeAll(keepingCapacity: true) }
        return samples
    }
}

/// What the bubble shows and where it sits.
///
/// **There is one sender in the whole app**: the tracking area over the whole taskbar (`StripHoverResolution`
/// -> `bubbleRequest` in `DockStripView`). Each card used to send its own, which needed a whole set of guards
/// for "who may occupy this panel": a card-side `isHovering` could get stuck at true (a missed
/// `.onHover(false)`), and that card would then resend its request on every reorder, flashing the bubble
/// somewhere the pointer was not (reported 2026-08-17). With one sender this kind of preemption is
/// structurally impossible, and the guards were removed together with `Reason`.
struct WindowTitleTooltipRequest: Equatable {
    let chipID: String
    let title: String
    let anchorVisibleRect: CGRect
}

enum WindowTitleTooltipEvent: Equatable {
    case update(WindowTitleTooltipRequest)
    case exit(chipID: String)
}

/// Measured dimensions of the app-name bubble of the native macOS 26 Dock.
///
/// Measured pixel by pixel on 2026-08-17 from a native screenshot (@2x, black background, "ChatGPT"). **Do
/// not change from memory**; to change anything, take a new screenshot and measure again:
///
/// | | Measured |
/// |---|---|
/// | Shape | **Capsule** (not a rounded rectangle). 26pt high -> 13pt corner radius; straight edges between the two end semicircles |
/// | Height | 26pt |
/// | Left/right padding | 14pt each (measured to the glyph ink; written as 13 after subtracting the glyph's own side bearing) |
/// | Text | 57pt wide / 10.5pt ink height -> SF 14pt regular (13pt is only 54.5 wide, clearly narrower) |
/// | Tail | **Pointing down**, base 23pt wide, 6.5pt high, centered; flared base, straight middle, **rounded tip** |
/// | Tip to bar top | 6.5pt |
/// | Fill | reads gray 173 on pure black |
///
/// The tail silhouette is **pixel-identical** in two native screenshots of different widths (half-widths
/// 16.5/14/12.5/10.5/9.5/8.5/7.5/6.5/5.5/4/3 @2x), so it is a fixed-size part that does not vary with the
/// bubble width. The middle slope is about 1.17 (half-width/depth); extrapolated to 0 it would end at 7.1pt,
/// but it closes at 6.5pt. **The missing bit is the rounded tip** (the "rounder" look).
///
/// **The whole bubble scales with the taskbar tier** (2026-08-17): the table above holds the **medium tier**
/// values, other tiers multiply everything by `DockSize.scale`. The existing `DockSize.scale` is the right
/// factor: it is already normalized to medium (`panelHeight / DockSize.medium.panelHeight`) and is exactly
/// 1.0 at medium, so the medium column keeps the measured values verbatim. Do not compute another factor, and
/// never divide the bar height by a literal.
struct WindowTitleTooltipStyle: Equatable {
    /// Tier factor (medium = 1).
    let scale: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let fontSize: CGFloat
    let tailWidth: CGFloat
    let tailHeight: CGFloat
    /// Top end of the straight segment: the base flare ends here.
    let tailShoulderDepth: CGFloat
    let tailShoulderHalfWidth: CGFloat
    /// Start of the rounded tip: the round cap begins here.
    let tailTipDepth: CGFloat
    let tailTipHalfWidth: CGFloat
    /// Distance from the tip to the anchor's top edge.
    let tipGap: CGFloat
    let maximumWidth: CGFloat

    init(scale: CGFloat) {
        self.scale = scale
        height = 26 * scale
        // Capsule: the corner radius is always half the height, so it stays a capsule after scaling.
        cornerRadius = height / 2
        horizontalPadding = 13 * scale
        fontSize = 14 * scale
        tailWidth = 23 * scale
        tailHeight = 6.5 * scale
        tailShoulderDepth = 1.6 * scale
        tailShoulderHalfWidth = 6.6 * scale
        tailTipDepth = 5.6 * scale
        tailTipHalfWidth = 1.9 * scale
        tipGap = 6.5 * scale
        maximumWidth = 360 * scale
    }

    /// The measured table = medium tier. Tests use it to lock "scaling did not change the native pixels along
    /// the way".
    static let native = WindowTitleTooltipStyle(scale: 1)
}

/// Capsule + downward teardrop tail. The tail is drawn **in the shape** rather than as an overlaid triangle:
/// overlaid, the two strokes would cross at the seam and leave a horizontal line; the native one is a single
/// continuous outline.
struct WindowTitleTooltipShape: InsettableShape {
    let style: WindowTitleTooltipStyle
    /// For `strokeBorder`: draws the stroke **entirely inside the shape**.
    ///
    /// It used `stroke`, which centers the line on the outline: half of a 0.5pt line falls outside the shape
    /// and antialiasing eats half of it, so the stroke measured only 197 where native is 209 (converted to
    /// the same background). The stroke is the only source of crispness and cannot be discounted.
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> Self {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in outerRect: CGRect) -> Path {
        let rect = outerRect.insetBy(dx: insetAmount, dy: insetAmount)
        let tail = style.tailHeight
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: max(0, rect.height - tail))
        let radius = min(style.cornerRadius, body.height / 2)
        let halfTail = min(style.tailWidth, body.width) / 2
        let centerX = body.midX

        var path = Path()
        // Capsule body: right semicircle -> top edge -> left semicircle -> bottom edge (up to the left side
        // of the tail base).
        path.move(to: CGPoint(x: body.maxX - radius, y: body.maxY))
        path.addArc(center: CGPoint(x: body.maxX - radius, y: body.midY),
                    radius: radius, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        path.addLine(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addArc(center: CGPoint(x: body.minX + radius, y: body.midY),
                    radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        // The tail's three segments (measured from native): concave shoulder flaring at the base -> straight
        // middle -> rounded tip. **Not a sharp point**: the extrapolated straight edge would close at 7.1pt,
        // but it bottoms out at 6.5pt; the difference is the round cap.
        let base = body.maxY
        let shoulderY = base + style.tailShoulderDepth
        let shoulderX = style.tailShoulderHalfWidth
        let tipY = base + style.tailTipDepth
        let tipX = style.tailTipHalfWidth
        // A quadratic curve reaches (start + 2×control + end)/4 at t=0.5, so the control point's y is solved
        // backwards this way for a peak of base + tail.
        let capControlY = 2 * (base + tail) - tipY

        path.addLine(to: CGPoint(x: centerX - halfTail, y: base))
        path.addQuadCurve(to: CGPoint(x: centerX - shoulderX, y: shoulderY),
                          control: CGPoint(x: centerX - halfTail * 0.83, y: base + tail * 0.05))
        path.addLine(to: CGPoint(x: centerX - tipX, y: tipY))
        path.addQuadCurve(to: CGPoint(x: centerX + tipX, y: tipY),
                          control: CGPoint(x: centerX, y: capControlY))
        path.addLine(to: CGPoint(x: centerX + shoulderX, y: shoulderY))
        path.addQuadCurve(to: CGPoint(x: centerX + halfTail, y: base),
                          control: CGPoint(x: centerX + halfTail * 0.83, y: base + tail * 0.05))
        path.closeSubpath()
        return path
    }
}

struct WindowTitleTooltipView: View {
    let title: String
    /// Tier style. **Deliberately no default value**: omitting it must be a compile error, same as
    /// `ChipView.scale` / `hoverStyle` / `onWindowTitleTooltipEvent` (project rule "Taskbar Size Tiers").
    let style: WindowTitleTooltipStyle
    /// Whether the backing uses real liquid glass. **No default value either**; the value is passed by
    /// `PanelCoordinator` (its `usesLiquidGlass` is the single global source).
    let usesLiquidGlass: Bool

    private let theme = DockThemeTokens.standard

    var body: some View {
        let shape = WindowTitleTooltipShape(style: style)
        return Text(title)
            .font(.system(size: style.fontSize, weight: .regular))
            .foregroundStyle(theme.tooltipText.color)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: style.maximumWidth)
            .padding(.horizontal, style.horizontalPadding)
            // The text box fills the body height and is centered; the tail takes its space through extra
            // bottom padding, so it does not shift the text.
            .frame(height: style.height)
            .padding(.bottom, style.tailHeight)
            .background(plate(shape: shape))
            .overlay(shape.strokeBorder(theme.tooltipRim.color, lineWidth: 0.5))
            .dockShadow(theme.tooltipShadow)
            .padding(PanelGeometry.windowTitleTooltipShadowPadding)
    }

    /// Bubble backing. Real liquid glass (with refraction) when glass is available, otherwise the signed-off
    /// flat plate.
    ///
    /// **The native one is not an ordinary background blur, it is liquid glass refraction** (pointed out
    /// 2026-08-17, and the measurements agree): on the same background luminance (~235) the native fill is
    /// 247 and ours 239, while the two "plate color × opacity" models differ by only 4 levels. The difference
    /// comes from **what is sampled behind**: native samples the refracted neighborhood, which smooths out
    /// scattered dark text on a light window; we sample the real pixels behind, so native is a blur while
    /// ours can be read character by character.
    ///
    /// **Hand-rolling refraction is still impossible** (`.behindWindow` is composited in WindowServer, and
    /// this process cannot see the pixels behind itself), but **using the system glass is a different
    /// matter**, and five panels already do. The `in:` of `.glassEffect(_:in:)` takes any `Shape`, so the
    /// tail renders together with the body instead of as two pieces (splitting leaves a line across the seam,
    /// a mistake already made once).
    ///
    /// Same structure as `DockLiquidGlassPlate`: glass + a whitening layer **below** it. The
    /// `materialActiveAppearance` / `appearsActive` pair cannot be omitted: the bubble panel never becomes
    /// the key window, and unless forced the material renders as "inactive" and turns gray (already hit on
    /// the panel side). **The glass goes under the plate, it does not replace the plate.** The most expensive
    /// lesson of this round; measured numbers (black / light 235 background):
    ///
    /// | Backing | Black bg | Light bg | Native |
    /// |---|---|---|---|
    /// | `Glass.clear` only (the taskbar's) | - | **205** (darker than the background) | - |
    /// | `Glass.regular` only + whitening 0.22 | **45** | 245 | 173 / 247 |
    /// | Near-white plate 0.70 **on top of the glass** (current) | see verification | see verification | 173 / 247 |
    ///
    /// Glass alone can be tuned to 247 on a light background, **but gives only 45 on black**: `.regular`
    /// darkens with the background, while the native one is still light gray 173 on pure black, which is what
    /// keeps black text readable. **One background cannot calibrate two unknowns**; we
    /// nearly fell into the same hole again.
    ///
    /// Native behaves as "near-white translucent plate + blurred backdrop", so the plate's algebra is
    /// unchanged (`0.965 @ 0.70`, calibrated against three measured points and locked by `DockThemeTests`),
    /// and the glass only **blurs the 30% that shows through**. Both paths therefore share the same algebra;
    /// the only difference is whether that 30% is sharp, so the fallback path cannot drift.
    @ViewBuilder
    private func plate(shape: WindowTitleTooltipShape) -> some View {
        // Plate: shared by both paths, **not changed for glass**. `.ultraThinMaterial` cannot go underneath
        // here: measured, it passes only about 54% of the background and adds no white, which pushes the
        // bubble down to 174 on white (native 249), and lowering opacity cannot recover it (it would need
        // plate color 384).
        let plate = shape.fill(theme.tooltipPlate.color.opacity(theme.tooltipPlateOpacity))
        if #available(macOS 26.0, *), usesLiquidGlass {
            plate.background {
                shape
                    .fill(Color.clear)
                    // **`.clear`, not `.regular`: it preserves color clearly better.** Measured on the same
                    // red target (plate on top, glass below, black / white luminance points identical for
                    // both): `.clear` (232,197,194) saturation **0.164**, `.regular` (206,187,186) saturation
                    // 0.097. Solving back for the glass's own output, `.clear` has saturation 0.63: **the
                    // white plate on top dilutes the color**, not the glass. Native is 0.269 and we cannot
                    // reach it: thinning the plate recovers chroma, but the 173 on black collapses with it
                    // (computed 141 at a=0.55), and black text on black backgrounds depends on it. The native
                    // material is self-luminous in the dark **and** preserves color; a linear stack cannot do
                    // that. Accepted limit.
                    .glassEffect(.clear.interactive(false), in: shape)
                    // The bubble panel never becomes the key window, and unless forced the material renders
                    // as "inactive" and turns gray (already hit on the panel side, comment in
                    // `DockLiquidGlassPlate`).
                    .materialActiveAppearance(.active)
                    .environment(\.appearsActive, true)
            }
        } else {
            plate
        }
    }
}
