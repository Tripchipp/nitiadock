import AppKit
import XCTest

/// fork: the shortcut field resolves its colours against its own window's appearance
/// (it used to freeze them in `init`, near-black in a light window when the system was dark).
@MainActor
final class ForkHotKeyRecorderAppearanceTests: XCTestCase {
    private func fillBrightness(windowAppearance: NSAppearance.Name, currentAppearance: NSAppearance.Name) throws -> CGFloat {
        let saved = NSAppearance.current
        defer { NSAppearance.current = saved }
        // The state that broke it: the thread's current appearance differs from the window's.
        NSAppearance.current = NSAppearance(named: currentAppearance)

        let view = HotKeyRecorderNSView(frame: NSRect(x: 0, y: 0, width: 132, height: 24))
        view.idleGlyphs = "⌥⇧⌘D"
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: windowAppearance)
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // A pixel inside the border, left of the centred label.
        let color = try XCTUnwrap(bitmap.colorAt(x: 6, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        return color.brightnessComponent
    }

    func testFillFollowsTheWindowAppearanceNotTheThreadsCurrentOne() throws {
        XCTAssertGreaterThan(try fillBrightness(windowAppearance: .aqua, currentAppearance: .darkAqua), 0.8)
        XCTAssertLessThan(try fillBrightness(windowAppearance: .darkAqua, currentAppearance: .aqua), 0.4)
    }
}
