import CoreGraphics
import Foundation
import QuartzCore

/// Feel diagnostics for taskbar interaction. Off by default, `DOCK_HOVER_TRACE=1` turns it on.
/// (The file name stays `hover-trace.jsonl`: it first measured only hover, was extended on
/// 2026-08-17 to the click / minimize path, and on 2026-08-18 to dragging. All feel
/// diagnostics share this one switch and one file; a second set of I/O would be pointless.)
///
/// The hover part answers two questions:
/// 1. **When the mouse sweeps across a row of icons at constant speed, does
///    every chip get a hover callback?** If some are missing, events were
///    coalesced, and the problem is main-thread load, not the bubble itself.
/// 2. **Once received, how long does it take to put the bubble in place?** If
///    long, rendering/window calls are slow, and that is the bubble's own problem.
///
/// It also records main-thread **stalls**: an 8ms repeating
/// timer that measures how late each firing is against schedule.
/// This is direct evidence of "events being coalesced": the 100ms stickiness covered
/// by the project rule on menus, panels and screens was identified exactly by "the
/// main thread is idle but events arrive late", which CPU usage alone does not show.
///
/// Written to `~/Library/Logs/no.thilip.nitiadock/hover-trace.jsonl`.
enum HoverTrace {
    static let isEnabled = DebugSwitch.hoverTrace.isEnabled(in: ProcessInfo.processInfo.environment)
    /// The width probes (`width` / `relayout` / `action`) can be enabled separately:
    /// `DOCK_LABEL_PROBE=1` runs without the hover trace's 8ms stall sampling and pointer polling, both
    /// of which keep the main loop awake and are themselves a disturbance when measuring animations.
    static let widthProbesEnabled = isEnabled || DebugSwitch.labelProbe.isEnabled(in: ProcessInfo.processInfo.environment)

    /// A chip reports hover enter / exit.
    static func hover(chipID: String, entered: Bool) {
        guard isEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"hover\",\"chip\":\(quote(chipID)),\"in\":\(entered)}")
    }

    /// How long the coordinator actually took to place the bubble (including SwiftUI relayout + setFrame).
    static func present(chipID: String, cold: Bool, elapsed: CFTimeInterval) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"present\",\"chip\":\(quote(chipID))," +
            "\"cold\":\(cold),\"ms\":\(round(elapsed * 10000) / 10)}"
        )
    }

    /// The bar-wide tracking area logs one line per pointer position received, with the computed owner.
    ///
    /// **This is the only on-site evidence of whether hover keeps up.** When the bar became
    /// one tracking area on 2026-08-17, the first version relied on the `.mouseMoved` of
    /// `NSTrackingArea`, and measurements showed only single digits reported per 35 pointer
    /// moves (these panels are never the key window). Without this line it is guesswork.
    static func pointer(x: CGFloat, chip: String?) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"pointer\",\"x\":\(round(x * 10) / 10)," +
            "\"chip\":\(chip.map(quote) ?? "null")}"
        )
    }

    /// Every callback of an external drop (dragged in from Finder). **Temporary diagnostic**: on 2026-09-08
    /// the plus badge on the cursor was reported to flicker while dragging an app onto the bar, and flicker
    /// can only come from the drop operation returned by `dropUpdated` alternating. This line puts "session
    /// enter/exit / pasteboard verdict / the two landings / returned operation / gap index" on one timeline,
    /// making "are we oscillating or is the system badge moving on its own" decidable. Delete once resolved.
    static func externalDrop(phase: String, x: CGFloat, isApp: Bool,
                             target: String, fileTarget: String,
                             operation: String, ghostIndex: Int?,
                             frozenWidth: CGFloat?, stripRect: CGRect) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"extdrop\",\"phase\":\(quote(phase))," +
            "\"x\":\(round(x * 10) / 10),\"isApp\":\(isApp)," +
            "\"target\":\(quote(target)),\"fileTarget\":\(quote(fileTarget))," +
            "\"op\":\(quote(operation)),\"ghost\":\(ghostIndex.map(String.init) ?? "null")," +
            "\"frozen\":\(frozenWidth.map { String(r1($0)) } ?? "null")," +
            "\"rectX\":\(r1(stripRect.minX)),\"rectW\":\(r1(stripRect.width))}"
        )
    }

    /// Main-thread stall: scheduled to fire at 8ms, actually late
    /// by `lateMs`. Only logs above 12ms to avoid flooding itself.
    /// A frame is 16.7ms at 60Hz, so >16.7 basically means at least one dropped frame.
    static func mainLoopStall(lateMs: Double) {
        guard isEnabled, lateMs >= 12 else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"stall\",\"lateMs\":\(round(lateMs * 10) / 10)}")
    }

    // MARK: - Click / minimize path (2026-08-17 report: actions after a click or minimize stutter)

    /// One evaluation of the taskbar body. **Answers "how many times did one
    /// click recompute the whole bar"**: `DockStripView` subscribes to the whole
    /// `AppRuntime`, so any `@Published` change invalidates the whole bar.
    static func stripBody(items: Int) {
        guard isEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"stripBody\",\"items\":\(items)}")
    }

    /// One `relayout`: how long the synchronous measurement of the bar width took,
    /// the result, whether it changed from last time, and whether it is animated.
    ///
    /// **`changed:false` with `animated:true` is pure waste**: the width did not change
    /// yet a window-size animation still runs, and every frame of that animation
    /// redraws the glass backing and the stroke. This is the prime suspect this round.
    static func relayout(measureMs: CFTimeInterval, width: CGFloat, changed: Bool, animated: Bool,
                         timing: String = "standard") {
        guard widthProbesEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"relayout\",\"measureMs\":\(round(measureMs * 10000) / 10)," +
            "\"width\":\(round(width * 10) / 10),\"changed\":\(changed),\"animated\":\(animated)," +
            "\"timing\":\(quote(timing))}"
        )
    }

    /// Per-frame width probe (output only while the trace is on): `who` = "panel" (live width of
    /// the AppKit window frame) or "content" (live layout width of the SwiftUI bar content).
    /// Comparing the two curves shows whether content and backing move on the same curve in sync.
    static func width(_ who: String, _ width: CGFloat) {
        guard widthProbesEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"width\",\"who\":\(quote(who)),\"w\":\(round(width * 10) / 10)}")
    }

    /// Panel frames identical -> the whole animation group is skipped. **This line is
    /// the evidence that the waste above is really plugged**, which the `relayout`
    /// count alone does not show (the short circuit happens downstream in `setFrames`).
    static func framesUnchanged() {
        guard isEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"framesSkipped\"}")
    }

    /// Time-window marker for a user action. Without it there is no
    /// telling which action a pile of stalls in the log belongs to.
    static func action(_ kind: String, phase: String) {
        guard widthProbesEnabled else { return }
        Writer.shared.append("{\"t\":\(stamp()),\"kind\":\"action\",\"what\":\(quote(kind)),\"phase\":\(quote(phase))}")
    }

    // MARK: - Dragging (2026-08-18 report: drawer-to-taskbar drags rarely push icons aside / two shadows appear)

    /// While a drawer icon is dragged toward the taskbar, **every
    /// cursor position update** logs one line of the decision context.
    ///
    /// It exists for the same reason as `pointer`: the conversion decision is a chain of
    /// `guard`s, and any one failing returns silently, which from outside all looks like "no
    /// reaction". Without this line it is guesswork whether it was geometry, mode or landing.
    /// `enter` / `clearlyOut` are the two booleans of the hysteresis box, `mode` is `DrawerDragOutMode`.
    static func drawerToStrip(x: CGFloat, y: CGFloat,
                              strip: CGRect,
                              enter: Bool, clearlyOut: Bool,
                              mode: String, converted: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"d2s\",\"x\":\(r1(x)),\"y\":\(r1(y))," +
            "\"sx\":\(r1(strip.minX)),\"sy\":\(r1(strip.minY))," +
            "\"sw\":\(r1(strip.width)),\"sh\":\(r1(strip.height))," +
            "\"enter\":\(enter),\"out\":\(clearlyOut),\"mode\":\(quote(mode)),\"conv\":\(converted)}"
        )
    }

    /// The landing stash at the moment of conversion / rollback. **`target` null = the whole block
    /// lands at the end of the live zone**, and since the taskbar width is frozen during conversion,
    /// the end is often clipped outside the visible area and looks like "nothing happened".
    static func drawerToStripStage(bundleID: String, target: String?, after: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"d2sStage\",\"bid\":\(quote(bundleID))," +
            "\"target\":\(target.map(quote) ?? "null"),\"after\":\(after)}"
        )
    }

    /// In the converted state, which card the carrier draws and which card the bar hides.
    /// Both **must have a value at the same time**, otherwise the card on
    /// the bar is drawn opaque while another is held in hand = two shadows.
    static func carrierRepresentative(rep: String?, hidden: String?) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"carrierRep\"," +
            "\"rep\":\(rep.map(quote) ?? "null"),\"hidden\":\(hidden.map(quote) ?? "null")}"
        )
    }

    /// Continuous whole-block reorder after conversion: whether a landing target was found
    /// this time. `target` null = the cursor is not over any live card (off the bar, in the
    /// messaging/folder zone, or between cards), so **the whole block stays where it is**.
    static func stripBlockReorder(target: String?, after: Bool, why: String) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"blockReorder\",\"target\":\(target.map(quote) ?? "null")," +
            "\"after\":\(after),\"why\":\(quote(why))}"
        )
    }

    /// How long each step took in the drag-start frame (2026-08-18
    /// report: the first frame of dragging a selected icon stutters).
    /// `carrierCreated` = whether the carrier panel was created this time. Creating the
    /// panel brings up a SwiftUI host tree, a cost only the first drag of the session pays,
    /// and this is what tells "stutters every time" from "stutters only the first time".
    /// `prepared` = the candidate was prepared at press time (texture uploaded, drag
    /// let through in the same turn); false = it took the "cover the card and wait
    /// two display frames" way out, which should almost never appear in normal drags.
    static func dragStart(totalMs: Double, carrierMs: Double, carrierCreated: Bool, prepared: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"dragStart\",\"ms\":\(round(totalMs * 10) / 10)," +
            "\"carrierMs\":\(round(carrierMs * 10) / 10),\"created\":\(carrierCreated)," +
            "\"prepared\":\(prepared)}"
        )
    }

    /// How long capturing one carrier bitmap took, and its size.
    ///
    /// At drag start it is captured synchronously on the main thread, so it counts directly
    /// toward "does the first frame stutter". The spike measured a median of 0.59ms and a
    /// P95 of 0.87ms (budget 8ms); if a real machine exceeds that, move the snapshot to the
    /// mouse-down of `chipPressGesture` and capture ahead. `w`/`h` are the logical size
    /// including the outset; `ok:false` = render failed, and that drag is rejected outright.
    static func carrierSnapshot(ms: Double, width: CGFloat, height: CGFloat, ok: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"snapshot\",\"ms\":\(round(ms * 10) / 10)," +
            "\"w\":\(r1(width)),\"h\":\(r1(height)),\"ok\":\(ok)}"
        )
    }

    /// Abnormal moments on the drag-start path.
    ///
    /// Since the carrier became a bitmap, "when the card on the bar is hidden" is no
    /// longer a race (`beginDrag` synchronously places the bitmap at the slot), so the
    /// old `slotHidden` / `carrierDrawn` moments are gone. Only one value remains:
    /// `noSnapshot`: the bitmap could not be captured and that drag
    /// is rejected outright (better no drag than carrying thin air).
    static func dragHandoff(_ what: String, msSinceBegin: Double) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"handoff\",\"what\":\(quote(what))," +
            "\"ms\":\(round(msSinceBegin * 10) / 10)}"
        )
    }

    /// Landing accuracy: how far the carrier's final position
    /// is from the slot anchor (carrier panel coordinates, pt).
    ///
    /// **This is the only quantitative basis for whether the "landing ghost" is really cured.**
    /// In the previous version the eye could not tell "5pt off" from "motion blur" and it was
    /// repeated guessing; this turns it into a countable fact in the log. Only logs > 0.5pt.
    static func landingDelta(dx: CGFloat, dy: CGFloat) {
        guard isEnabled, hypot(dx, dy) > 0.5 else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"landingDelta\",\"dx\":\(r1(dx)),\"dy\":\(r1(dy))}"
        )
    }

    /// A landing anchor was written (`DragController.setLandingAnchor`). **After release the pointer has
    /// no more events, so this is the only thing that shows "is the anchor still moving, and where to"**,
    /// and it does move: after the bar width unfreezes the whole bar recenters and the drawer panel
    /// slides left along with it for 0.22s. `owner` tells whether the taskbar or the drawer wrote it.
    static func landingAnchor(owner: String, rect: CGRect?) {
        guard isEnabled else { return }
        let r = rect.map { "[\(r1($0.minX)),\(r1($0.minY)),\(r1($0.width)),\(r1($0.height))]" } ?? "null"
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"landingAnchor\",\"owner\":\"\(owner)\",\"rect\":\(r)}"
        )
    }

    /// A messaging app in the drawer dragged toward the messaging
    /// zone: **one line per tick**, to compare with `d2s`.
    /// `stop` is the guard it got stuck on (`ok` = this tick really released), `zone` is
    /// the computed messaging zone range (`fallback` means the messaging zone was empty
    /// at the time and it fell back to the 56pt fallback box at the head of the bar).
    /// `inSnapshot` / `running` **must be logged together**: granting the release looks at the
    /// window list (`runtime.snapshot`), while messaging zone visibility and the running dot
    /// under the icon look at `RunningApplicationStore` (the NSWorkspace process projection).
    /// They are not the same source of truth, and that divergence is the suspect for "the
    /// icon clearly has a running dot but cannot be dragged into the messaging zone".
    static func drawerToMessaging(bid: String, x: CGFloat, y: CGFloat, zone: CGRect?, fallback: Bool,
                                  mode: String, inSnapshot: Bool, running: Bool,
                                  inZone: Bool, released: Bool, stop: String) {
        guard isEnabled else { return }
        let z = zone.map { "[\(r1($0.minX)),\(r1($0.minY)),\(r1($0.width)),\(r1($0.height))]" } ?? "null"
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"d2m\",\"bid\":\(quote(bid)),\"x\":\(r1(x)),\"y\":\(r1(y)),\"zone\":\(z),"
            + "\"fallback\":\(fallback),\"mode\":\(quote(mode)),\"snap\":\(inSnapshot),\"run\":\(running),"
            + "\"inZone\":\(inZone),\"released\":\(released),\"stop\":\(quote(stop))}"
        )
    }

    /// **End point change** mid-flight. The landing anchor keeps updating during the flight (the
    /// slot/grid make-way animation has not finished), and `retargetLandingIfNeeded` follows by
    /// changing the end point and resending the animation. If it changes too far, the user sees a
    /// bent path (2026-08-20: "drifts to the right of the target first, then goes to the target").
    /// Only this line turns "how many flights, how far off each time" into
    /// countable facts in the log; `landing` is logged once at takeoff.
    static func landingRetarget(from: CGPoint, to: CGPoint, previous: CGPoint) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"landingRetarget\",\"from\":[\(r1(from.x)),\(r1(from.y))],"
            + "\"to\":[\(r1(to.x)),\(r1(to.y))],\"prev\":[\(r1(previous.x)),\(r1(previous.y))],"
            + "\"shift\":\(r1(hypot(to.x - previous.x, to.y - previous.y)))}"
        )
    }

    /// **Invariant self-check**: the cell on the bar is already empty but the copy is
    /// not on screen. At that moment the user sees "the icon vanished into thin air".
    /// Turns "happens occasionally" into a record that can be
    /// counted afterwards, with no more guessing from screenshots.
    static func carrierGap(reason: String, alpha: Double, hostX: CGFloat, hostY: CGFloat) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"GAP\",\"why\":\(quote(reason))," +
            "\"alpha\":\(round(alpha * 100) / 100),\"hx\":\(r1(hostX)),\"hy\":\(r1(hostY))}"
        )
    }

    /// Whether the side-effect path `reconcileLiveOrder` got a **fresh** projection this round.
    ///
    /// This is direct evidence of the 2026-08-18 pitfall and worth keeping permanently: when the old-style
    /// `onChange(of:perform:)` fires it runs the closure captured in the previous frame, so the projection is
    /// one generation behind. Rendering already has the card but `sync` does not yet, so the landing stash of
    /// the drawer conversion was never consumed. `carried=true` with `has=false` means it has recurred.
    static func orderSync(count: Int, carriedID: String?, hasCarried: Bool) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"orderSync\",\"n\":\(count)," +
            "\"carried\":\(carriedID.map(quote) ?? "null"),\"has\":\(hasCarried)}"
        )
    }

    /// Visible order after the ordering layer actually places the item (logged only while
    /// drag diagnostics are on). The final basis for "which cell did the gap open at".
    static func liveOrder(_ ids: [String]) {
        guard isEnabled else { return }
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"liveOrder\",\"ids\":[\(ids.map(quote).joined(separator: ","))]}"
        )
    }

    /// Return flight after release: start point, end point, whether an anchor was available.
    /// `to` null = no landing anchor, take the instant finish (old behavior).
    static func landing(from: CGPoint, to: CGPoint?, source: String) {
        guard isEnabled else { return }
        let target = to.map { "[\(r1($0.x)),\(r1($0.y))]" } ?? "null"
        Writer.shared.append(
            "{\"t\":\(stamp()),\"kind\":\"landing\",\"from\":[\(r1(from.x)),\(r1(from.y))]," +
            "\"to\":\(target),\"src\":\(quote(source))}"
        )
    }

    private static func r1(_ value: CGFloat) -> Double { (Double(value) * 10).rounded() / 10 }

    private static func stamp() -> Double { round(CACurrentMediaTime() * 10000) / 10 }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private final class Writer {
        static let shared = Writer()
        private let queue = DispatchQueue(label: "no.thilip.nitiadock.hovertrace")

        func append(_ line: String) {
            queue.async { [self] in
                guard let fileURL else { return }
                TraceFile.append(line, to: fileURL)
            }
        }

        private lazy var fileURL: URL? = {
            let fm = FileManager.default
            guard let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
            let dir = base.appendingPathComponent("Logs/no.thilip.nitiadock", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("hover-trace.jsonl")
        }()
    }
}

/// Appends one line to a diagnostic trace file. The file is private to the user and bounded: past
/// `maxBytes` it is renamed to `<name>.1` (replacing the previous one) and a new file starts, so a
/// switch left on cannot fill the disk.
enum TraceFile {
    static let maxBytes: UInt64 = 32 * 1024 * 1024

    static func append(_ line: String, to fileURL: URL) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        let manager = FileManager.default
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            let end = (try? handle.seekToEnd()) ?? 0
            if end < maxBytes {
                try? handle.write(contentsOf: data)
                try? handle.close()
                return
            }
            try? handle.close()
            let rotated = fileURL.appendingPathExtension("1")
            try? manager.removeItem(at: rotated)
            try? manager.moveItem(at: fileURL, to: rotated)
        }
        manager.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
    }
}
