import CoreGraphics
import XCTest

final class FullscreenIntentDecisionTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testGreenButtonAcceptsExactHitAndIgnoresNonModifierFlags() {
        let snapshot = makeSnapshot()
        let request = FullscreenIntentDecision.greenButtonRequest(
            location: CGPoint(x: 120, y: 110),
            flags: [.maskAlphaShift, .maskNonCoalesced],
            snapshot: snapshot
        )
        XCTAssertEqual(request?.source, .greenButton)
        XCTAssertEqual(request?.focusedWindowID, snapshot.focusedWindowID)
    }

    func testGreenButtonRejectsModifiersCapabilityAndContextMismatches() {
        let point = CGPoint(x: 120, y: 110)
        for modifier: CGEventFlags in [
            .maskControl, .maskCommand, .maskAlternate, .maskShift,
            .maskSecondaryFn, .maskHelp, .maskNumericPad
        ] {
            XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
                location: point, flags: modifier, snapshot: makeSnapshot()
            ))
        }
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: CGPoint(x: 200, y: 200), flags: [], snapshot: makeSnapshot()
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: makeSnapshot(buttonEnabled: false)
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: makeSnapshot(isFullscreen: true)
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: makeSnapshot(panelScreens: [])
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point,
            flags: [],
            snapshot: makeSnapshot(panelScreens: [CGRect(x: 1512, y: 0, width: 1920, height: 1080)])
        ))
        XCTAssertNil(FullscreenIntentDecision.greenButtonRequest(
            location: point, flags: [], snapshot: nil
        ))
    }

    func testShortcutAcceptsExactControlCommandAndCapsLock() {
        let request = FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand, .maskAlphaShift, .maskNonCoalesced],
            isRepeat: false,
            snapshot: makeSnapshot()
        )
        XCTAssertEqual(request?.source, .keyboardShortcut)
    }

    func testShortcutRejectsExtraModifiersRepeatWrongKeyAndMissingCapability() {
        for flags: CGEventFlags in [
            [.maskControl, .maskCommand, .maskAlternate],
            [.maskControl, .maskCommand, .maskShift],
            [.maskControl, .maskCommand, .maskSecondaryFn],
            [.maskControl, .maskCommand, .maskHelp],
            [.maskControl, .maskCommand, .maskNumericPad],
            [.maskCommand]
        ] {
            XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
                keyCode: FullscreenIntentDecision.ansiFKeyCode,
                flags: flags,
                isRepeat: false,
                snapshot: makeSnapshot()
            ))
        }
        XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand],
            isRepeat: true,
            snapshot: makeSnapshot()
        ))
        XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
            keyCode: 4,
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            snapshot: makeSnapshot()
        ))
        XCTAssertNil(FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            snapshot: makeSnapshot(buttonEnabled: false)
        ))
    }

    func testSettingAndEnvironmentMustBothEnableMonitor() {
        XCTAssertTrue(FullscreenIntentDecision.isEnabled(settingEnabled: true, environment: [:]))
        XCTAssertFalse(FullscreenIntentDecision.isEnabled(
            settingEnabled: true,
            environment: ["DOCK_FULLSCREEN_INTENT": "0"]
        ))
        XCTAssertFalse(FullscreenIntentDecision.isEnabled(settingEnabled: false, environment: [:]))
    }

    func testStaleAXRefreshAndForegroundPIDSwitchCannotReplaceCache() {
        XCTAssertTrue(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 4,
            expectedCache: 7,
            currentCache: 7,
            requestedPID: 123,
            activePID: 123
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 5,
            expectedCache: 7,
            currentCache: 7,
            requestedPID: 123,
            activePID: 123
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 4,
            expectedCache: 7,
            currentCache: 8,
            requestedPID: 123,
            activePID: 123
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.shouldApplyRefresh(
            started: true,
            expectedObservation: 4,
            currentObservation: 4,
            expectedCache: 7,
            currentCache: 7,
            requestedPID: 123,
            activePID: 124
        ))
    }

    func testRequestMustMatchCurrentPIDWindowScreenAndCacheGeneration() {
        let snapshot = makeSnapshot()
        let request = FullscreenIntentDecision.shortcutRequest(
            keyCode: FullscreenIntentDecision.ansiFKeyCode,
            flags: [.maskControl, .maskCommand],
            isRepeat: false,
            snapshot: snapshot
        )!
        XCTAssertTrue(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: snapshot,
            activePID: snapshot.pid,
            started: true
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: makeSnapshot(generation: 10),
            activePID: snapshot.pid,
            started: true
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: makeSnapshot(focusedWindowID: 999),
            activePID: snapshot.pid,
            started: true
        ))
        XCTAssertFalse(FullscreenIntentCacheDecision.isCurrentRequest(
            request,
            snapshot: snapshot,
            activePID: 124,
            started: true
        ))
    }

    func testRefreshCoalescerCollapsesBurstIntoOneTrailingRefresh() {
        var coalescer = FullscreenIntentRefreshCoalescer()
        let first = coalescer.request()!
        XCTAssertNil(coalescer.request())
        XCTAssertNil(coalescer.request())
        XCTAssertTrue(coalescer.needsTrailingRefresh)

        guard case let .start(second) = coalescer.complete(token: first) else {
            return XCTFail("burst must schedule exactly one trailing refresh")
        }
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(coalescer.needsTrailingRefresh)
        XCTAssertEqual(coalescer.complete(token: first), .ignored)
        XCTAssertEqual(coalescer.complete(token: second), .idle)
        XCTAssertNil(coalescer.activeToken)
    }

    func testRefreshCoalescerResetInvalidatesOldCompletion() {
        var coalescer = FullscreenIntentRefreshCoalescer()
        let old = coalescer.request()!
        coalescer.reset()
        let current = coalescer.request()!

        XCTAssertEqual(coalescer.complete(token: old), .ignored)
        XCTAssertEqual(coalescer.activeToken, current)
        XCTAssertEqual(coalescer.complete(token: current), .idle)
    }

    func testTapRecoveryFusesOnFourthDisableWithinWindow() {
        var policy = FullscreenEventTapRecoveryPolicy()
        XCTAssertTrue(policy.recordDisable(at: 0))
        XCTAssertTrue(policy.recordDisable(at: 1))
        XCTAssertTrue(policy.recordDisable(at: 2))
        XCTAssertFalse(policy.recordDisable(at: 3))
        XCTAssertTrue(policy.isFused)
        XCTAssertFalse(policy.recordDisable(at: 64))
    }

    func testFusedTapIsRearmedAfterCoolDown() {
        var policy = FullscreenEventTapRecoveryPolicy()
        XCTAssertFalse(policy.rearmAfterCoolDown(), "nothing to re-arm while the tap is healthy")
        for second in 0..<4 { _ = policy.recordDisable(at: TimeInterval(second)) }
        XCTAssertTrue(policy.isFused)
        XCTAssertTrue(policy.rearmAfterCoolDown())
        XCTAssertFalse(policy.isFused)
        // A fresh budget: three more disables are tolerated again.
        XCTAssertTrue(policy.recordDisable(at: 400))
    }

    func testTapRecoveryDropsOldEpisodesOutsideWindow() {
        var policy = FullscreenEventTapRecoveryPolicy()
        XCTAssertTrue(policy.recordDisable(at: 0))
        XCTAssertTrue(policy.recordDisable(at: 1))
        XCTAssertTrue(policy.recordDisable(at: 61))
        XCTAssertTrue(policy.recordDisable(at: 62))
        XCTAssertFalse(policy.isFused)
    }

    func testLateHandoffCannotBeginAfterCancellation() {
        let gate = FullscreenIntentHandoffGate()
        XCTAssertTrue(gate.cancelIfPending())
        XCTAssertFalse(gate.beginExecution())
        XCTAssertEqual(gate.currentState, .cancelled)
    }

    func testExecutingHandoffCompletesAndCannotBeCancelled() {
        let gate = FullscreenIntentHandoffGate()
        XCTAssertTrue(gate.beginExecution())
        XCTAssertFalse(gate.cancelIfPending())
        gate.complete()
        XCTAssertEqual(gate.currentState, .completed)
    }

    // MARK: - Control+←/→ Space switching experiment

    /// This is where the whole experiment most easily goes wrong: **physical arrow keys always carry Fn +
    /// numeric pad + nonCoalesced**, even when the user holds no extra key. Comparing the way
    /// `FullscreenIntentDecision.normalizedModifiers` does would never match, giving a false negative that
    /// triggers nothing and is very easily misread as "548ms of lead time is not enough, this approach is
    /// dead".
    func testPhysicalArrowIntrinsicFlagsDoNotBlockTheMatch() {
        let physicalControlLeft: CGEventFlags = [
            .maskControl, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced
        ]
        XCTAssertTrue(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
            flags: physicalControlLeft,
            isRepeat: false
        ))
        XCTAssertTrue(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.rightArrowKeyCode,
            flags: physicalControlLeft,
            isRepeat: false
        ))
    }

    func testSpaceSwitchArrowRejectsEveryOtherShape() {
        let intrinsic: CGEventFlags = [.maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        // Control not pressed
        XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
            flags: intrinsic,
            isRepeat: false
        ))
        // Extra modifier keys held
        for extra: CGEventFlags in [.maskCommand, .maskAlternate, .maskShift, .maskHelp] {
            XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
                keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
                flags: intrinsic.union([.maskControl]).union(extra),
                isRepeat: false
            ), "\(extra) should not pass")
        }
        // Up/down arrows do not switch Spaces
        for keyCode in [CGKeyCode(125), CGKeyCode(126)] {
            XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
                keyCode: keyCode,
                flags: intrinsic.union([.maskControl]),
                isRepeat: false
            ))
        }
        // Key repeat from holding does not trigger again
        XCTAssertFalse(FullscreenSpaceSwitchDecision.isSpaceSwitchArrow(
            keyCode: FullscreenSpaceSwitchDecision.rightArrowKeyCode,
            flags: intrinsic.union([.maskControl]),
            isRepeat: true
        ))
    }

    func testArrowDirectionMapsKeyCodes() {
        let physical: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced]
        XCTAssertEqual(
            FullscreenSpaceSwitchDecision.arrowDirection(
                keyCode: FullscreenSpaceSwitchDecision.leftArrowKeyCode,
                flags: physical, isRepeat: false
            ),
            .left
        )
        XCTAssertEqual(
            FullscreenSpaceSwitchDecision.arrowDirection(
                keyCode: FullscreenSpaceSwitchDecision.rightArrowKeyCode,
                flags: physical, isRepeat: false
            ),
            .right
        )
    }

    // MARK: - Adjacent Space gate

    private func layout(current: Int, fullscreen: Set<Int> = [3]) -> SpaceLayoutSnapshot {
        SpaceLayoutSnapshot(
            orderedSpaceIDs: [1, 2, 3, 4],
            fullscreenSpaceIDs: fullscreen,
            currentSpaceID: current
        )
    }

    func testNeighborGateOnlyOpensTowardAFullscreenSpace() {
        // Space 3 is fullscreen; only going right from 2 or left from 4 should open it
        XCTAssertTrue(layout(current: 2).neighborIsFullscreen(.right))
        XCTAssertFalse(layout(current: 2).neighborIsFullscreen(.left))
        XCTAssertTrue(layout(current: 4).neighborIsFullscreen(.left))
        XCTAssertFalse(layout(current: 4).neighborIsFullscreen(.right))
        // Between two ordinary desktops: closed on both sides, or the bar would hide where nothing was wrong
        XCTAssertFalse(layout(current: 1, fullscreen: []).hasAnyFullscreenNeighbor)
    }

    func testNeighborGateHandlesEdgesAndUnknownCurrentSpace() {
        XCTAssertFalse(layout(current: 1).neighborIsFullscreen(.left))   // leftmost has no left neighbor
        XCTAssertFalse(layout(current: 4).neighborIsFullscreen(.right))  // rightmost has no right neighbor
        XCTAssertFalse(layout(current: 99).hasAnyFullscreenNeighbor)     // current Space is not in the list
    }

    // Added 2026-08-31: the gate applies only when standing on a desktop. Already on a fullscreen Space, do
    // not predict: the bar is hidden anyway and there is nothing to hide; fullscreen→fullscreen is left to
    // the existing hold mechanism. (The reverse prediction, showing the bar early on fullscreen→desktop, was
    // built and reverted; see the SpaceLayoutSnapshot comment. Stability comes first; do not add it back by
    // just deleting this test.)
    func testGateNeverOpensWhileStandingInAFullscreenSpace() {
        // On fullscreen Space 3: desktops on both sides, the gate stays closed
        XCTAssertFalse(layout(current: 3).neighborIsFullscreen(.left))
        XCTAssertFalse(layout(current: 3).neighborIsFullscreen(.right))
        XCTAssertFalse(layout(current: 3).hasAnyFullscreenNeighbor)
        // Fullscreen next to fullscreen (3 and 4 both fullscreen): going right from 3 stays closed too
        XCTAssertFalse(layout(current: 3, fullscreen: [3, 4]).neighborIsFullscreen(.right))
        // Going right from desktop 2 opens as before (existing behavior unaffected)
        XCTAssertTrue(layout(current: 2).neighborIsFullscreen(.right))
    }

    // MARK: - Three-finger horizontal swipe

    /// Measured mapping (14/14 consistent): under natural scrolling, **a left swipe goes to the Space on the
    /// right**.
    func testSwipeDirectionFollowsNaturalScrollingSetting() {
        var tracker = SpaceSwipeTracker()
        XCTAssertNil(tracker.consume(touches: 3, x: 0.5, y: 0.5, at: 0, naturalScrolling: true))
        XCTAssertEqual(
            tracker.consume(touches: 3, x: 0.3, y: 0.5, at: 0, naturalScrolling: true), .right
        )
        tracker.reset()
        XCTAssertNil(tracker.consume(touches: 3, x: 0.5, y: 0.5, at: 0, naturalScrolling: false))
        XCTAssertEqual(
            tracker.consume(touches: 3, x: 0.3, y: 0.5, at: 0, naturalScrolling: false), .left
        )
    }

    /// Three-finger **vertical** swipes (Mission Control): in 1 of 10 measured, horizontal drift crossed the
    /// threshold; the rule "horizontal travel must exceed vertical travel" excludes all 10/10. Remove it and
    /// the taskbar hides by mistake.
    func testVerticalThreeFingerSwipeNeverFires() {
        var tracker = SpaceSwipeTracker()
        _ = tracker.consume(touches: 3, x: 0.50, y: 0.50, at: 0, naturalScrolling: true)
        // Worst measured sample: horizontal 0.055, vertical 0.267
        XCTAssertNil(tracker.consume(touches: 3, x: 0.555, y: 0.767, at: 0, naturalScrolling: true))
    }

    func testSwipeNeedsThreeFingersAndResetsWhenFingersLift() {
        var tracker = SpaceSwipeTracker()
        // Two-finger scroll: no horizontal travel, however large, triggers
        _ = tracker.consume(touches: 2, x: 0.5, y: 0.5, at: 0, naturalScrolling: true)
        XCTAssertNil(tracker.consume(touches: 2, x: 0.1, y: 0.5, at: 0, naturalScrolling: true))
        // Lifting fingers (fewer than three touches) re-anchors; travel does not accumulate across sequences
        _ = tracker.consume(touches: 3, x: 0.5, y: 0.5, at: 0, naturalScrolling: true)
        _ = tracker.consume(touches: 0, x: 0.0, y: 0.0, at: 0, naturalScrolling: true)
        XCTAssertNil(tracker.consume(touches: 3, x: 0.1, y: 0.5, at: 0, naturalScrolling: true))
    }

    func testSwipeFiresOnlyOncePerBurst() {
        var tracker = SpaceSwipeTracker()
        _ = tracker.consume(touches: 3, x: 0.6, y: 0.5, at: 0, naturalScrolling: true)
        XCTAssertEqual(tracker.consume(touches: 3, x: 0.4, y: 0.5, at: 0, naturalScrolling: true), .right)
        XCTAssertNil(tracker.consume(touches: 3, x: 0.2, y: 0.5, at: 0, naturalScrolling: true))
        XCTAssertNil(tracker.consume(touches: 3, x: 0.9, y: 0.5, at: 0, naturalScrolling: true))
    }

    private func makeSnapshot(
        generation: UInt64 = 9,
        focusedWindowID: CGWindowID = 456,
        buttonEnabled: Bool = true,
        isFullscreen: Bool = false,
        panelScreens: [CGRect] = [CGRect(x: 0, y: 0, width: 1512, height: 982)]
    ) -> FullscreenIntentSnapshot {
        FullscreenIntentSnapshot(
            generation: generation,
            pid: 123,
            focusedWindowID: focusedWindowID,
            buttonFrame: CGRect(x: 100, y: 100, width: 40, height: 20),
            windowFrame: CGRect(x: 80, y: 80, width: 900, height: 700),
            screenCGFrame: screen,
            panelScreenCGFrames: panelScreens,
            isFullscreen: isFullscreen,
            buttonEnabled: buttonEnabled
        )
    }


    // MARK: - Multi-display (2026-09-02)

    /// Under ③ several screens have a bar: send the request whenever the focused window's screen is in the
    /// set.
    func testGreenButtonRequestFiresWhenScreenIsAnyPanelScreen() {
        let other = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let request = FullscreenIntentDecision.greenButtonRequest(
            location: CGPoint(x: 110, y: 110),
            flags: [],
            snapshot: makeSnapshot(panelScreens: [other, screen])
        )
        XCTAssertNotNil(request)
    }

    private func layout(current: Int, ordered: [Int], fullscreen: Set<Int>) -> SpaceLayoutSnapshot {
        SpaceLayoutSnapshot(orderedSpaceIDs: ordered, fullscreenSpaceIDs: fullscreen, currentSpaceID: current)
    }

    func testSpaceLayoutDirectoryLocatesDisplayUnderPointAndArrowTarget() {
        let a = SpaceLayoutDirectory.Entry(
            displayUUID: "A",
            appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            layout: layout(current: 1, ordered: [1, 2], fullscreen: [])
        )
        let b = SpaceLayoutDirectory.Entry(
            displayUUID: "B",
            appKitFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            layout: layout(current: 3, ordered: [3, 4], fullscreen: [4])
        )
        let directory = SpaceLayoutDirectory(entries: [a, b])
        XCTAssertTrue(directory.hasAnyFullscreenNeighbor)
        XCTAssertEqual(directory.entry(containing: CGPoint(x: 100, y: 100))?.displayUUID, "A")
        XCTAssertEqual(directory.entry(containing: CGPoint(x: 2000, y: 100))?.displayUUID, "B")
        XCTAssertNil(directory.entry(containing: CGPoint(x: -5, y: 5)))
        XCTAssertEqual(directory.displays(withFullscreenNeighbor: .right).map(\.displayUUID), ["B"])
        // Single candidate: lands on B even with the mouse on A.
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: 100, y: 100))?.displayUUID, "B")
        XCTAssertNil(directory.arrowTarget(.left, mouseLocation: CGPoint(x: 100, y: 100)))
    }

    func testSpaceLayoutDirectoryArrowTargetPrefersMouseDisplayAmongCandidates() {
        let a = SpaceLayoutDirectory.Entry(
            displayUUID: "A",
            appKitFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            layout: layout(current: 1, ordered: [1, 2], fullscreen: [2])
        )
        let b = SpaceLayoutDirectory.Entry(
            displayUUID: "B",
            appKitFrame: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            layout: layout(current: 3, ordered: [3, 4], fullscreen: [4])
        )
        let directory = SpaceLayoutDirectory(entries: [a, b])
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: 2000, y: 50))?.displayUUID, "B")
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: 10, y: 50))?.displayUUID, "A")
        // Mouse on no candidate → the first one.
        XCTAssertEqual(directory.arrowTarget(.right, mouseLocation: CGPoint(x: -100, y: -100))?.displayUUID, "A")
    }
}
