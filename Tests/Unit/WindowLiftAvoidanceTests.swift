import CoreGraphics
import XCTest

final class WindowLiftAvoidanceTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 949)
    private let geometry = WindowLiftAvoidance.Geometry(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949),
        taskbarTop: 60
    )

    // MARK: - Geometry

    func testFillsVisibleFrameUsesTwelvePointToleranceOnAllFourEdges() {
        XCTAssertTrue(geometry.fillsVisibleFrame(visibleFrame.insetBy(dx: 12, dy: 12)))
        XCTAssertFalse(geometry.fillsVisibleFrame(visibleFrame.insetBy(dx: 12.1, dy: 12)))
        XCTAssertFalse(geometry.fillsVisibleFrame(
            CGRect(x: 0, y: 0, width: visibleFrame.width, height: visibleFrame.height - 12.1)
        ))
    }

    func testAdjustedFrameRaisesOnlyBottomAndKeepsTopLeftAndWidth() throws {
        let adjusted = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))

        XCTAssertEqual(adjusted.minY, 62)
        XCTAssertEqual(adjusted.maxY, visibleFrame.maxY)
        XCTAssertEqual(adjusted.minX, visibleFrame.minX)
        XCTAssertEqual(adjusted.width, visibleFrame.width)
    }

    func testSideSystemDockReservationIsPreserved() throws {
        let sideDockGeometry = WindowLiftAvoidance.Geometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 90, y: 0, width: 1422, height: 949),
            taskbarTop: 60
        )
        let adjusted = try XCTUnwrap(sideDockGeometry.adjustedFrame(for: sideDockGeometry.visibleFrame))

        XCTAssertEqual(adjusted.minX, 90)
        XCTAssertEqual(adjusted.width, 1422)
        XCTAssertEqual(adjusted.minY, 62)
    }

    func testExistingBottomSystemDockReservationWinsOverTaskbarClearance() {
        let bottomDockGeometry = WindowLiftAvoidance.Geometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 90, width: 1512, height: 859),
            taskbarTop: 60
        )

        XCTAssertNil(bottomDockGeometry.adjustedFrame(for: bottomDockGeometry.visibleFrame))
    }

    func testNegativeAndVerticallyStackedScreenGeometry() throws {
        let lowerScreenGeometry = WindowLiftAvoidance.Geometry(
            screenFrame: CGRect(x: -2408, y: -640, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -2408, y: -640, width: 1920, height: 1055),
            taskbarTop: -580
        )
        let adjusted = try XCTUnwrap(
            lowerScreenGeometry.adjustedFrame(for: lowerScreenGeometry.visibleFrame)
        )

        XCTAssertEqual(adjusted.minY, -578)
        XCTAssertEqual(adjusted.maxY, lowerScreenGeometry.visibleFrame.maxY)

        let upperAppKit = CGRect(x: -488, y: 982, width: 2560, height: 1440)
        let upperQuartz = WindowLiftAvoidance.quartzFrame(
            fromAppKit: upperAppKit,
            primaryScreenHeight: 982
        )
        XCTAssertEqual(upperQuartz, CGRect(x: -488, y: -1440, width: 2560, height: 1440))
        XCTAssertEqual(
            WindowLiftAvoidance.appKitFrame(fromQuartz: upperQuartz, primaryScreenHeight: 982),
            upperAppKit
        )
    }

    func testGeometryRejectsWindowOnAnotherScreen() {
        let otherScreenWindow = CGRect(x: 1600, y: 0, width: 1512, height: 949)
        XCTAssertFalse(geometry.fillsVisibleFrame(otherScreenWindow))
        XCTAssertNil(geometry.adjustedFrame(for: otherScreenWindow))
    }

    // MARK: - Retry and animation

    func testPollScheduleHasOnlyImmediateHundredAndTwoHundredFiftyMillisecondAttempts() {
        let schedule = WindowLiftAvoidance.PollSchedule.standard

        XCTAssertEqual(schedule.deadlines, [0, 0.1, 0.25])
        XCTAssertEqual(schedule.incrementalDelays[0], 0, accuracy: 0.0001)
        XCTAssertEqual(schedule.incrementalDelays[1], 0.1, accuracy: 0.0001)
        XCTAssertEqual(schedule.incrementalDelays[2], 0.15, accuracy: 0.0001)
        XCTAssertEqual(schedule.remainingDelay(for: 2, elapsed: 0.2) ?? -1, 0.05, accuracy: 0.0001)
        XCTAssertNil(schedule.remainingDelay(for: 3, elapsed: 0))
    }

    func testGlobalAndTrackedSessionCGCadencesStaySeparate() {
        XCTAssertEqual(WindowLiftAvoidance.globalDetectionInterval, 0.2, accuracy: 0.0001)
        XCTAssertEqual(WindowLiftAvoidance.trackedSessionProbeInterval, 0.05, accuracy: 0.0001)
        XCTAssertLessThan(
            WindowLiftAvoidance.trackedSessionProbeInterval,
            WindowLiftAvoidance.globalDetectionInterval
        )
    }

    func testEaseInOutCubicIsClampedMonotonicAndSymmetric() {
        let samples = stride(from: -0.2, through: 1.2, by: 0.05).map {
            WindowLiftAvoidance.easeInOutCubic($0)
        }

        XCTAssertEqual(samples.first, 0)
        XCTAssertEqual(samples.last, 1)
        for pair in zip(samples, samples.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0, pair.1)
        }
        XCTAssertEqual(WindowLiftAvoidance.easeInOutCubic(0.5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            WindowLiftAvoidance.easeInOutCubic(0.25),
            1 - WindowLiftAvoidance.easeInOutCubic(0.75),
            accuracy: 0.0001
        )
    }

    func testInterpolatedFrameKeepsTopStableForLiftGeometry() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))

        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let sample = WindowLiftAvoidance.interpolatedFrame(
                from: visibleFrame,
                to: target,
                progress: progress
            )
            XCTAssertEqual(sample.maxY, visibleFrame.maxY, accuracy: 0.0001)
            XCTAssertEqual(sample.minX, visibleFrame.minX, accuracy: 0.0001)
            XCTAssertEqual(sample.width, visibleFrame.width, accuracy: 0.0001)
        }
    }

    func testRebasedAnimationProgressUsesRemainingHardDeadline() {
        XCTAssertEqual(
            WindowLiftAvoidance.rebasedAnimationProgress(0.5, startingAt: 0),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rebasedAnimationProgress(0.4, startingAt: 0.4),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rebasedAnimationProgress(0.7, startingAt: 0.4),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rebasedAnimationProgress(1, startingAt: 0.4),
            1,
            accuracy: 0.0001
        )
    }

    func testFrameClassificationUsesTargetNativeTrajectoryExternalPriority() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )

        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: target,
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .target
        )
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: visibleFrame,
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .native
        )
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: midpoint,
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .managedTrajectory
        )
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: midpoint.offsetBy(dx: 2.1, dy: 0),
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .external
        )
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: CGRect(
                    x: midpoint.minX,
                    y: target.minY + 2.1,
                    width: midpoint.width,
                    height: midpoint.maxY - target.minY - 2.1
                ),
                nativeFrame: visibleFrame,
                targetFrame: target
            ),
            .external
        )
    }

    func testFrameClassificationPrefersTargetWhenEndpointTolerancesOverlap() {
        let native = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 0, y: 3, width: 100, height: 97)
        let matchesBothEndpoints = CGRect(x: 0, y: 1.5, width: 100, height: 98.5)

        XCTAssertTrue(WindowLiftAvoidance.framesMatch(matchesBothEndpoints, native))
        XCTAssertTrue(WindowLiftAvoidance.framesMatch(matchesBothEndpoints, target))
        XCTAssertEqual(
            WindowLiftAvoidance.frameClassification(
                of: matchesBothEndpoints,
                nativeFrame: native,
                targetFrame: target
            ),
            .target
        )
    }

    func testStableSamplesUseVerificationTolerance() {
        XCTAssertTrue(WindowLiftAvoidance.samplesAreStable(
            visibleFrame.offsetBy(dx: 2, dy: -2),
            comparedTo: visibleFrame
        ))
        XCTAssertFalse(WindowLiftAvoidance.samplesAreStable(
            visibleFrame.offsetBy(dx: 2.1, dy: 0),
            comparedTo: visibleFrame
        ))
        XCTAssertFalse(WindowLiftAvoidance.samplesAreStable(
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100),
            comparedTo: visibleFrame
        ))
    }

    func testThreeWayStableSamplesRejectAccumulatedPairwiseDrift() {
        XCTAssertTrue(WindowLiftAvoidance.samplesAreStable(
            initialCGFrame: visibleFrame,
            confirmedCGFrame: visibleFrame.offsetBy(dx: 1, dy: 0),
            confirmedAXFrame: visibleFrame.offsetBy(dx: -1, dy: 0)
        ))

        XCTAssertFalse(WindowLiftAvoidance.samplesAreStable(
            initialCGFrame: visibleFrame,
            confirmedCGFrame: visibleFrame.offsetBy(dx: 2, dy: 0),
            confirmedAXFrame: visibleFrame.offsetBy(dx: 4, dy: 0)
        ))
    }

    func testMovedCandidateCanBecomeFreshStableCandidateOnNextScan() {
        let settledFrame = visibleFrame.offsetBy(dx: 0, dy: 5)

        XCTAssertFalse(WindowLiftAvoidance.samplesAreStable(
            settledFrame,
            comparedTo: visibleFrame
        ))
        XCTAssertTrue(WindowLiftAvoidance.samplesAreStable(
            settledFrame,
            comparedTo: settledFrame
        ))
    }

    // MARK: - Session reducer

    func testInitialDetectionWritesThenRecordsLift() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        var transition = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )

        XCTAssertEqual(
            transition.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 1, isRelift: false)
        )
        transition = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .writeFinished(generation: 1, at: 1000.6, actualFrame: target, reliftCount: 0)
        )

        guard case let .lifted(session) = transition.state else {
            return XCTFail("Expected lifted state")
        }
        XCTAssertEqual(session.reliftCount, 0)
        XCTAssertEqual(session.adjustedFrame, target)
        XCTAssertEqual(session.settledAt, 1000.6)
        XCTAssertEqual(session.standoffRounds, 0)
    }

    func testOneReliftIsAllowedThenThirdMaximizeDetectionAbandons() throws {
        // Entirely within appReassertWindow(1.0s): a maximized frame reappearing is handled as an app
        // reassert.
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        var transition = completedLift(generation: 1, target: target)

        transition = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .maximizedDetected(
                generation: 2,
                at: 1000.9,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(
            transition.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 2, isRelift: true)
        )
        transition = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .writeFinished(generation: 2, at: 1001.2, actualFrame: target, reliftCount: 1)
        )

        transition = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .maximizedDetected(
                generation: 3,
                at: 1001.6,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(transition.action, .abandon(.reliftLimitReached))
        guard case let .abandoned(session) = transition.state else {
            return XCTFail("Expected abandoned state")
        }
        XCTAssertEqual(session.reliftCount, 1)
        XCTAssertEqual(session.abandonedAt, 1001.6)

        let repeated = WindowLiftAvoidance.reduce(
            state: transition.state,
            event: .maximizedDetected(
                generation: 4,
                at: 1002.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(repeated.action, .none)
        guard case let .abandoned(repeatedSession) = repeated.state else {
            return XCTFail("Abandoned session must persist while the window remains maximized")
        }
        XCTAssertEqual(repeatedSession.abandonedAt, 1001.6, "later observations must not refresh abandonedAt")
    }

    func testLeavingMaximizedClearsLiftedAndAbandonedSessions() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let manualFrame = CGRect(x: 180, y: 140, width: 1000, height: 700)
        let lifted = completedLift(generation: 1, target: target).state

        let clearedLifted = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .nonMaximizedObserved(generation: 2, at: 1000.8, frame: manualFrame)
        )
        XCTAssertEqual(clearedLifted, .init(state: .idle, action: .clear))

        let abandoned = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .maximizedDetected(
                generation: 2,
                at: 1000.9,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        let failed = WindowLiftAvoidance.reduce(
            state: abandoned.state,
            event: .writeFailed(generation: 2, at: 1001.0, reliftCount: 1)
        )
        guard case .abandoned = failed.state else { return XCTFail("Expected failed write to abandon") }

        let clearedAbandoned = WindowLiftAvoidance.reduce(
            state: failed.state,
            event: .nonMaximizedObserved(generation: 3, at: 1001.2, frame: manualFrame)
        )
        XCTAssertEqual(clearedAbandoned, .init(state: .idle, action: .clear))
    }

    func testObservingOurAdjustedFrameDoesNotClearSession() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let lifted = completedLift(generation: 1, target: target).state

        let transition = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .nonMaximizedObserved(
                generation: 2,
                at: 1000.8,
                frame: target.offsetBy(dx: 1, dy: -1)
            )
        )

        XCTAssertEqual(transition.action, .none)
        guard case let .lifted(session) = transition.state else {
            return XCTFail("Expected lifted session to remain active")
        }
        XCTAssertEqual(session.generation, 2)
        XCTAssertEqual(session.settledAt, 1000.6, "a target observation only refreshes generation, not settledAt")
    }

    func testStaleWriteCompletionAndObservationCannotChangeNewerSession() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 10,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state

        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: writing,
                event: .writeFinished(generation: 9, at: 1000.3, actualFrame: target, reliftCount: 0)
            ),
            .init(state: writing, action: .none)
        )

        let lifted = WindowLiftAvoidance.reduce(
            state: writing,
            event: .writeFinished(generation: 10, at: 1000.6, actualFrame: target, reliftCount: 0)
        ).state
        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: lifted,
                event: .nonMaximizedObserved(
                    generation: 9,
                    at: 1000.7,
                    frame: CGRect(x: 10, y: 10, width: 500, height: 500)
                )
            ),
            .init(state: lifted, action: .none)
        )
    }

    func testWritingManagedTrajectoryContinuesButExternalFrameClearsAndLateCompletionIsIgnored() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )

        let managed = WindowLiftAvoidance.reduce(
            state: writing,
            event: .nonMaximizedObserved(generation: 2, at: 1000.2, frame: midpoint)
        )
        XCTAssertEqual(managed.action, .none)
        guard case let .writing(managedAttempt) = managed.state else {
            return XCTFail("Expected the managed trajectory to keep the write active")
        }
        XCTAssertEqual(managedAttempt.generation, 1)
        XCTAssertEqual(managedAttempt.latestObservationGeneration, 2)

        let manualFrame = CGRect(x: 140, y: 120, width: 900, height: 700)
        let cleared = WindowLiftAvoidance.reduce(
            state: managed.state,
            event: .nonMaximizedObserved(generation: 3, at: 1000.3, frame: manualFrame)
        )
        XCTAssertEqual(cleared, .init(state: .idle, action: .clear))

        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: cleared.state,
                event: .writeFinished(generation: 1, at: 1000.6, actualFrame: target, reliftCount: 0)
            ),
            .init(state: .idle, action: .none)
        )

        let restarted = WindowLiftAvoidance.reduce(
            state: cleared.state,
            event: .maximizedDetected(
                generation: 4,
                at: 1001.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(
            restarted.action,
            .write(
                targetFrame: target,
                rollbackFrame: visibleFrame,
                generation: 4,
                isRelift: false
            )
        )
        guard case let .writing(restartedAttempt) = restarted.state else {
            return XCTFail("Expected a fresh writing session")
        }
        XCTAssertEqual(restartedAttempt.reliftCount, 0)
    }

    func testWritingIgnoresOlderFrameFromTheOtherCGProbeCadence() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )
        let manualFrame = CGRect(x: 140, y: 120, width: 900, height: 700)
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let newerManagedObservation = WindowLiftAvoidance.reduce(
            state: writing,
            event: .nonMaximizedObserved(generation: 3, at: 1000.2, frame: midpoint)
        )

        let lateExternalObservation = WindowLiftAvoidance.reduce(
            state: newerManagedObservation.state,
            event: .nonMaximizedObserved(generation: 2, at: 1000.25, frame: manualFrame)
        )
        XCTAssertEqual(lateExternalObservation, .init(
            state: newerManagedObservation.state,
            action: .none
        ))

        let completed = WindowLiftAvoidance.reduce(
            state: newerManagedObservation.state,
            event: .writeFinished(generation: 1, at: 1000.6, actualFrame: target, reliftCount: 0)
        )
        guard case let .lifted(session) = completed.state else {
            return XCTFail("Expected the original serial writer to complete")
        }
        XCTAssertEqual(session.generation, 3)
        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: completed.state,
                event: .nonMaximizedObserved(generation: 2, at: 1000.7, frame: manualFrame)
            ),
            .init(state: completed.state, action: .none)
        )

        XCTAssertEqual(
            WindowLiftAvoidance.reduce(
                state: completed.state,
                event: .nonMaximizedObserved(generation: 4, at: 1000.8, frame: manualFrame)
            ),
            .init(state: .idle, action: .clear)
        )
    }

    func testWriterCanReportOneInternalReliftAndSecondSnapSeparately() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 10,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state

        let completed = WindowLiftAvoidance.reduce(
            state: writing,
            event: .writeFinished(generation: 10, at: 1000.6, actualFrame: target, reliftCount: 1)
        )
        guard case let .lifted(lifted) = completed.state else {
            return XCTFail("Expected internally relifted write to complete")
        }
        XCTAssertEqual(lifted.reliftCount, 1)

        let secondWriting = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 20,
                at: 1002,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let abandoned = WindowLiftAvoidance.reduce(
            state: secondWriting,
            event: .reliftLimitReached(generation: 20, at: 1002.5, reliftCount: 1)
        )
        XCTAssertEqual(abandoned.action, .abandon(.reliftLimitReached))
        guard case let .abandoned(session) = abandoned.state else {
            return XCTFail("Expected second native snap to abandon")
        }
        XCTAssertEqual(session.reliftCount, 1)
        XCTAssertEqual(session.reason, .reliftLimitReached)
        XCTAssertEqual(session.abandonedAt, 1002.5)
    }

    func testTrueWriteFailureHasDedicatedEvent() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 4,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state

        let failed = WindowLiftAvoidance.reduce(
            state: writing,
            event: .writeFailed(generation: 4, at: 1000.4, reliftCount: 0)
        )
        XCTAssertEqual(failed.action, .abandon(.writeFailed))
        guard case let .abandoned(session) = failed.state else {
            return XCTFail("Expected true AX failure to abandon")
        }
        XCTAssertEqual(session.reason, .writeFailed)
        XCTAssertEqual(session.reliftCount, 0)
    }

    func testWriteFinishedEnforcesFinalTwoPointVerificationTolerance() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let withinTolerance = CGRect(
            x: target.minX,
            y: target.minY - 2,
            width: target.width,
            height: target.height + 2
        )
        let acceptedWriting = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let accepted = WindowLiftAvoidance.reduce(
            state: acceptedWriting,
            event: .writeFinished(generation: 1, at: 1000.6, actualFrame: withinTolerance, reliftCount: 0)
        )
        guard case .lifted = accepted.state else {
            return XCTFail("Expected a final frame at the 2pt boundary to be accepted")
        }

        let outsideTolerance = CGRect(
            x: target.minX,
            y: target.minY - 2.1,
            width: target.width,
            height: target.height + 2.1
        )
        let rejectedWriting = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 2,
                at: 1002,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let rejected = WindowLiftAvoidance.reduce(
            state: rejectedWriting,
            event: .writeFinished(generation: 2, at: 1002.6, actualFrame: outsideTolerance, reliftCount: 0)
        )
        XCTAssertEqual(rejected.action, .abandon(.writeFailed))
        guard case let .abandoned(session) = rejected.state else {
            return XCTFail("Expected a final frame outside 2pt to abandon")
        }
        XCTAssertEqual(session.reason, .writeFailed)
    }

    func testAnimationMismatchDecisionPreservesEveryRecoveryPath() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )
        let manualFrame = CGRect(x: 140, y: 120, width: 900, height: 700)

        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: target),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .complete(actualFrame: target)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: midpoint),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .continueFromActual(actualFrame: midpoint)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: manualFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .clearSession(preservingFrame: manualFrame)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: visibleFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .restartFromNative(nativeFrame: visibleFrame, nextReliftCount: 1)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: visibleFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 1
            ),
            .reliftLimitReached(actualFrame: visibleFrame, reliftCount: 1)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .terminalWriteFailure,
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0
            ),
            .abandonWriteFailed
        )
    }

    func testTwentyObservedRestoresEachStartANewNonReliftSession() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let manualFrame = CGRect(x: 160, y: 120, width: 920, height: 720)
        var state: WindowLiftAvoidance.SessionState = .idle
        var generation: UInt64 = 0
        var now: TimeInterval = 1000

        for _ in 0..<20 {
            generation += 1
            now += 0.2
            let writeGeneration = generation
            var transition = WindowLiftAvoidance.reduce(
                state: state,
                event: .maximizedDetected(
                    generation: writeGeneration,
                    at: now,
                    nativeFrame: visibleFrame,
                    targetFrame: target
                )
            )
            XCTAssertEqual(
                transition.action,
                .write(
                    targetFrame: target,
                    rollbackFrame: visibleFrame,
                    generation: writeGeneration,
                    isRelift: false
                )
            )
            now += 0.6
            transition = WindowLiftAvoidance.reduce(
                state: transition.state,
                event: .writeFinished(
                    generation: writeGeneration,
                    at: now,
                    actualFrame: target,
                    reliftCount: 0
                )
            )

            generation += 1
            now += 0.1
            transition = WindowLiftAvoidance.reduce(
                state: transition.state,
                event: .nonMaximizedObserved(generation: generation, at: now, frame: manualFrame)
            )
            XCTAssertEqual(transition, .init(state: .idle, action: .clear))
            state = transition.state
        }
    }

    // MARK: - Time-scale discrimination (app reassert vs user action)

    func testMaximizeReappearingAfterReassertWindowStartsFreshSession() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let lifted = completedLift(generation: 1, target: target).state  // settledAt 1000.6

        // maximizedDetected path: maximized again 1.6s after the write = user action, brand-new session.
        let viaDetection = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .maximizedDetected(
                generation: 2,
                at: 1002.2,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(
            viaDetection.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 2, isRelift: false)
        )
        guard case let .writing(freshAttempt) = viaDetection.state else {
            return XCTFail("Expected a fresh writing session")
        }
        XCTAssertEqual(freshAttempt.reliftCount, 0)
        XCTAssertEqual(freshAttempt.standoffRounds, 0)

        // native observation path (with polluted zoom memory, L↔M toggling yields no external, so this is the
        // only way): brand-new session too.
        let viaObservation = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .nonMaximizedObserved(generation: 2, at: 1002.2, frame: visibleFrame)
        )
        XCTAssertEqual(
            viaObservation.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 2, isRelift: false)
        )
    }

    func testNativeSnapWithinWindowStillConsumesReliftBudget() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let lifted = completedLift(generation: 1, target: target).state  // settledAt 1000.6

        // Reclaimed to maximized within 0.4s of the write = app reassert, takes the re-lift.
        let transition = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .nonMaximizedObserved(generation: 2, at: 1001.0, frame: visibleFrame)
        )
        XCTAssertEqual(
            transition.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 2, isRelift: true)
        )
    }

    func testAbandonedExpiresAfterWindowAndCountsStandoffRound() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: 1,
                at: 1000,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        ).state
        let abandoned = WindowLiftAvoidance.reduce(
            state: writing,
            event: .writeFailed(generation: 1, at: 1000.5, reliftCount: 0)
        ).state  // abandonedAt 1000.5

        // Maximized again inside the window: stays abandoned, abandonedAt is not refreshed.
        let held = WindowLiftAvoidance.reduce(
            state: abandoned,
            event: .maximizedDetected(
                generation: 2,
                at: 1001.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(held.action, .none)
        guard case let .abandoned(heldSession) = held.state else {
            return XCTFail("Expected abandoned to hold within the reassert window")
        }
        XCTAssertEqual(heldSession.abandonedAt, 1000.5)

        // Key: the baseline is the original abandonedAt (1000.5), not the previous observation (1001.0).
        // 1002.1 is only 1.1s after the last observation but 1.6s after abandonedAt → timeout reopen, count
        // one standoff round.
        let reopened = WindowLiftAvoidance.reduce(
            state: held.state,
            event: .maximizedDetected(
                generation: 3,
                at: 1002.1,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(
            reopened.action,
            .write(targetFrame: target, rollbackFrame: visibleFrame, generation: 3, isRelift: false)
        )
        guard case let .writing(reopenedAttempt) = reopened.state else {
            return XCTFail("Expected an expired abandoned session to reopen")
        }
        XCTAssertEqual(reopenedAttempt.reliftCount, 0)
        XCTAssertEqual(reopenedAttempt.standoffRounds, 1)

        // The native observation path can trigger the timeout reopen too.
        let reopenedViaObservation = WindowLiftAvoidance.reduce(
            state: held.state,
            event: .nonMaximizedObserved(generation: 3, at: 1002.1, frame: visibleFrame)
        )
        guard case let .writing(observedAttempt) = reopenedViaObservation.state else {
            return XCTFail("Expected native observation to reopen an expired abandoned session")
        }
        XCTAssertEqual(observedAttempt.standoffRounds, 1)
    }

    func testStandoffRoundsCapLocksUntilExternalFrameResets() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let manualFrame = CGRect(x: 160, y: 120, width: 920, height: 720)

        func abandonedState(
            from state: WindowLiftAvoidance.SessionState,
            generation: UInt64,
            detectedAt: TimeInterval,
            failedAt: TimeInterval,
            expectedRounds: Int
        ) throws -> WindowLiftAvoidance.SessionState {
            let writing = WindowLiftAvoidance.reduce(
                state: state,
                event: .maximizedDetected(
                    generation: generation,
                    at: detectedAt,
                    nativeFrame: visibleFrame,
                    targetFrame: target
                )
            )
            guard case let .writing(attempt) = writing.state else {
                throw XCTSkip("precondition failed: expected writing state")
            }
            XCTAssertEqual(attempt.standoffRounds, expectedRounds)
            return WindowLiftAvoidance.reduce(
                state: writing.state,
                event: .writeFailed(generation: generation, at: failedAt, reliftCount: 0)
            ).state
        }

        // Round 0 → abandoned(rounds 0); after two timeout reopens (rounds 1, 2) the third does not reopen.
        var state = try abandonedState(
            from: .idle, generation: 1, detectedAt: 1000, failedAt: 1000.5, expectedRounds: 0
        )
        state = try abandonedState(
            from: state, generation: 2, detectedAt: 1002.5, failedAt: 1003.0, expectedRounds: 1
        )
        state = try abandonedState(
            from: state, generation: 3, detectedAt: 1005.0, failedAt: 1005.5, expectedRounds: 2
        )

        let locked = WindowLiftAvoidance.reduce(
            state: state,
            event: .maximizedDetected(
                generation: 4,
                at: 1008.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(locked.action, .none)
        guard case let .abandoned(lockedSession) = locked.state else {
            return XCTFail("Expected the standoff cap to lock the session")
        }
        XCTAssertEqual(lockedSession.standoffRounds, 2)

        // An external frame is still the universal exit: after the session clears, the next maximize starts
        // from zero.
        let cleared = WindowLiftAvoidance.reduce(
            state: locked.state,
            event: .nonMaximizedObserved(generation: 5, at: 1008.5, frame: manualFrame)
        )
        XCTAssertEqual(cleared, .init(state: .idle, action: .clear))
        let fresh = WindowLiftAvoidance.reduce(
            state: cleared.state,
            event: .maximizedDetected(
                generation: 6,
                at: 1009.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        guard case let .writing(freshAttempt) = fresh.state else {
            return XCTFail("Expected a fresh session after external reset")
        }
        XCTAssertEqual(freshAttempt.standoffRounds, 0)
        XCTAssertEqual(freshAttempt.reliftCount, 0)
    }

    func testAnimationStallIsContinueNotRestart() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        let midpoint = WindowLiftAvoidance.interpolatedFrame(
            from: visibleFrame,
            to: target,
            progress: 0.5
        )

        // First frame stalled: readback == last confirmed position (== native). Typical of a
        // late-applying app on a 1x screen; treat as continue, must not burn re-lift budget or abandon.
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: visibleFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0,
                lastAcknowledgedFrame: visibleFrame
            ),
            .continueFromActual(actualFrame: visibleFrame)
        )
        // Really reclaimed by the app mid-animation: the confirmed position is already on the trajectory but
        // the readback is native → re-lift.
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: visibleFrame),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0,
                lastAcknowledgedFrame: midpoint
            ),
            .restartFromNative(nativeFrame: visibleFrame, nextReliftCount: 1)
        )
        // Stalled mid-trajectory: readback == confirmed position → continue.
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: midpoint),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0,
                lastAcknowledgedFrame: midpoint
            ),
            .continueFromActual(actualFrame: midpoint)
        )
        // Reaching the target is judged complete first, even if it equals the confirmed position.
        XCTAssertEqual(
            WindowLiftAvoidance.animationWriteFailureDecision(
                .initialFrameMismatch(actualFrame: target),
                nativeFrame: visibleFrame,
                targetFrame: target,
                reliftCount: 0,
                lastAcknowledgedFrame: target
            ),
            .complete(actualFrame: target)
        )
    }

    func testLockedStandoffDecaysToSlowRetryAndHealsAfterStableLift() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))

        func failedSession(
            from state: WindowLiftAvoidance.SessionState,
            generation: UInt64,
            detectedAt: TimeInterval,
            failedAt: TimeInterval
        ) -> WindowLiftAvoidance.SessionState {
            let writing = WindowLiftAvoidance.reduce(
                state: state,
                event: .maximizedDetected(
                    generation: generation,
                    at: detectedAt,
                    nativeFrame: visibleFrame,
                    targetFrame: target
                )
            ).state
            return WindowLiftAvoidance.reduce(
                state: writing,
                event: .writeFailed(generation: generation, at: failedAt, reliftCount: 0)
            ).state
        }

        var state = failedSession(from: .idle, generation: 1, detectedAt: 1000, failedAt: 1000.5)
        state = failedSession(from: state, generation: 2, detectedAt: 1002.5, failedAt: 1003.0)
        state = failedSession(from: state, generation: 3, detectedAt: 1005.0, failedAt: 1005.5)
        // rounds already at the cap, abandonedAt 1005.5.

        // After the cap, between appReassertWindow and standoffLockBackoff(3s): no reopen.
        let held = WindowLiftAvoidance.reduce(
            state: state,
            event: .maximizedDetected(
                generation: 4,
                at: 1008.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        XCTAssertEqual(held.action, .none)

        // Past standoffLockBackoff(3s): slow-rate reopen, rounds stay at the cap, no permanent lock.
        let reopened = WindowLiftAvoidance.reduce(
            state: held.state,
            event: .maximizedDetected(
                generation: 5,
                at: 1012.0,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        guard case let .writing(attempt) = reopened.state else {
            return XCTFail("Expected slow-cadence reopen after lock backoff")
        }
        XCTAssertEqual(attempt.standoffRounds, WindowLiftAvoidance.maximumStandoffRounds)

        // Write succeeded and stayed settled beyond the standoff window → healed, rounds reset to zero.
        let lifted = WindowLiftAvoidance.reduce(
            state: reopened.state,
            event: .writeFinished(generation: 5, at: 1012.6, actualFrame: target, reliftCount: 0)
        ).state
        let healed = WindowLiftAvoidance.reduce(
            state: lifted,
            event: .nonMaximizedObserved(generation: 6, at: 1014.5, frame: target)
        )
        guard case let .lifted(session) = healed.state else {
            return XCTFail("Expected lifted session to persist through target observation")
        }
        XCTAssertEqual(session.standoffRounds, 0)
    }

    func testUserPacedZoomToggleBetweenLiftedAndMaximizedAlwaysRelifts() throws {
        // L↔M deadlock regression test: once zoom memory is polluted, the user's zoom button only toggles
        // between target(L) and native(M) and never produces an external frame. At user pace (beyond
        // appReassertWindow) every landing on M must open a new session.
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))
        var state = completedLift(generation: 1, target: target).state
        var generation: UInt64 = 1
        var settledAt: TimeInterval = 1000.6

        for round in 0..<5 {
            // The user first sees the window resting at L (target observation, a few seconds).
            generation += 1
            var transition = WindowLiftAvoidance.reduce(
                state: state,
                event: .nonMaximizedObserved(generation: generation, at: settledAt + 1.0, frame: target)
            )
            XCTAssertEqual(transition.action, .none, "round \(round): a target observation should not clear the session")

            // The user clicks zoom → the window returns to M (native), more than appReassertWindow after the
            // last write.
            generation += 1
            let reMaximizedAt = settledAt + 2.0
            transition = WindowLiftAvoidance.reduce(
                state: transition.state,
                event: .nonMaximizedObserved(generation: generation, at: reMaximizedAt, frame: visibleFrame)
            )
            XCTAssertEqual(
                transition.action,
                .write(
                    targetFrame: target,
                    rollbackFrame: visibleFrame,
                    generation: generation,
                    isRelift: false
                ),
                "round \(round): landing on M at user pace must open a brand-new session"
            )

            // Write done → back to lifted, on to the next round.
            settledAt = reMaximizedAt + 0.6
            transition = WindowLiftAvoidance.reduce(
                state: transition.state,
                event: .writeFinished(
                    generation: generation,
                    at: settledAt,
                    actualFrame: target,
                    reliftCount: 0
                )
            )
            guard case let .lifted(session) = transition.state else {
                return XCTFail("round \(round): expected lifted state")
            }
            XCTAssertEqual(session.reliftCount, 0)
            XCTAssertEqual(session.standoffRounds, 0)
            state = transition.state
        }
    }

    // MARK: - Rollback and pruning

    func testRollbackOnlyRestoresFrameStillOwnedByOurFailedWrite() throws {
        let target = try XCTUnwrap(geometry.adjustedFrame(for: visibleFrame))

        XCTAssertEqual(
            WindowLiftAvoidance.rollbackDecision(
                originalFrame: visibleFrame,
                attemptedFrame: target,
                currentFrame: target
            ),
            .restore(visibleFrame)
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rollbackDecision(
                originalFrame: visibleFrame,
                attemptedFrame: target,
                currentFrame: visibleFrame
            ),
            .notNeeded
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rollbackDecision(
                originalFrame: visibleFrame,
                attemptedFrame: target,
                currentFrame: CGRect(x: 200, y: 120, width: 900, height: 700)
            ),
            .preserveCurrent
        )
        XCTAssertEqual(
            WindowLiftAvoidance.rollbackDecision(
                originalFrame: visibleFrame,
                attemptedFrame: target,
                currentFrame: nil
            ),
            .preserveCurrent
        )
    }

    func testDeadWindowPruningUsesPidAndWindowIDTogether() {
        let live = WindowLiftAvoidance.WindowKey(pid: 100, cgWindowID: 7)
        let dead = WindowLiftAvoidance.WindowKey(pid: 100, cgWindowID: 8)
        let reusedByOtherProcess = WindowLiftAvoidance.WindowKey(pid: 200, cgWindowID: 8)
        let states = [live: "live", dead: "dead"]

        XCTAssertEqual(
            WindowLiftAvoidance.deadWindowKeys(
                tracked: Set(states.keys),
                live: [live, reusedByOtherProcess]
            ),
            [dead]
        )
        XCTAssertEqual(
            WindowLiftAvoidance.prunedStates(
                states,
                liveWindowKeys: [live, reusedByOtherProcess]
            ),
            [live: "live"]
        )
    }

    func testOlderGlobalDeadSnapshotCannotOverrideNewerTrackedObservation() {
        let tracked = WindowLiftAvoidance.WindowKey(pid: 100, cgWindowID: 7)
        let watermarks: [WindowLiftAvoidance.WindowKey: UInt64] = [tracked: 5]

        XCTAssertEqual(
            WindowLiftAvoidance.prunableDeadWindowKeys(
                tracked: [tracked],
                live: [],
                observationGeneration: 4,
                observationWatermarks: watermarks
            ),
            []
        )
        XCTAssertEqual(
            WindowLiftAvoidance.prunableDeadWindowKeys(
                tracked: [tracked],
                live: [],
                observationGeneration: 6,
                observationWatermarks: watermarks
            ),
            [tracked]
        )
    }

    func testPollCadenceUsesSlowIdleAndPreservesFastTrackedIntervals() {
        XCTAssertEqual(
            WindowLiftAvoidance.PollCadence.interval(
                hasSessions: false,
                hasSuppressedFrames: false,
                isRestoring: false
            ),
            1.0,
            accuracy: 0.0001
        )

        for input in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertEqual(
                WindowLiftAvoidance.PollCadence.interval(
                    hasSessions: input.0,
                    hasSuppressedFrames: input.1,
                    isRestoring: input.2
                ),
                WindowLiftAvoidance.globalDetectionInterval,
                accuracy: 0.0001
            )
        }
    }

    func testEventPollCoalescerStartsLeadingAndOneTrailingPoll() {
        var coalescer = WindowLiftAvoidance.EventPollCoalescer()

        XCTAssertEqual(coalescer.request(at: 10, scanInFlight: false), .start)
        XCTAssertEqual(coalescer.request(at: 10.05, scanInFlight: true), .none)
        XCTAssertTrue(coalescer.pending)

        guard case let .schedule(delay) = coalescer.scanCompleted(at: 10.08) else {
            return XCTFail("an event during the active scan must schedule a trailing poll")
        }
        XCTAssertEqual(delay, 0.12, accuracy: 0.0001)
        XCTAssertEqual(coalescer.cooldownFired(at: 10.2, scanInFlight: false), .start)
        XCTAssertFalse(coalescer.pending)
    }

    func testEventPollCoalescerRetainsEventWhilePeriodicScanIsInFlight() {
        var coalescer = WindowLiftAvoidance.EventPollCoalescer()

        XCTAssertEqual(coalescer.request(at: 20, scanInFlight: true), .none)
        XCTAssertTrue(coalescer.pending)
        XCTAssertEqual(coalescer.scanCompleted(at: 20.05), .start)
        XCTAssertFalse(coalescer.pending)
    }

    func testEventPollCoalescerCollapsesCooldownBurstAndResetClearsIt() {
        var coalescer = WindowLiftAvoidance.EventPollCoalescer()

        XCTAssertEqual(coalescer.request(at: 30, scanInFlight: false), .start)
        guard case let .schedule(firstDelay) = coalescer.request(at: 30.04, scanInFlight: false) else {
            return XCTFail("cooldown event must schedule a trailing poll")
        }
        XCTAssertEqual(firstDelay, 0.16, accuracy: 0.0001)
        guard case let .schedule(secondDelay) = coalescer.request(at: 30.1, scanInFlight: false) else {
            return XCTFail("burst must remain coalesced behind the same cooldown")
        }
        XCTAssertEqual(secondDelay, 0.1, accuracy: 0.0001)

        coalescer.reset()
        XCTAssertFalse(coalescer.pending)
        XCTAssertNil(coalescer.lastStartedAt)
        XCTAssertEqual(coalescer.cooldownFired(at: 30.2, scanInFlight: false), .none)
    }

    /// Default timeline: detect at t=1000, write done at t=1000.6 (settledAt). Reassert detection is based on
    /// settledAt.
    private func completedLift(
        generation: UInt64,
        target: CGRect,
        detectedAt: TimeInterval = 1000,
        settledAt: TimeInterval = 1000.6
    ) -> WindowLiftAvoidance.Transition {
        let writing = WindowLiftAvoidance.reduce(
            state: .idle,
            event: .maximizedDetected(
                generation: generation,
                at: detectedAt,
                nativeFrame: visibleFrame,
                targetFrame: target
            )
        )
        return WindowLiftAvoidance.reduce(
            state: writing.state,
            event: .writeFinished(
                generation: generation,
                at: settledAt,
                actualFrame: target,
                reliftCount: 0
            )
        )
    }

    // MARK: - Multi-display attribution (③④)

    func testOwningContextIndexPrefersMajorityThenLargestOverlap() {
        let left = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            WindowLiftAvoidance.owningContextIndex(for: CGRect(x: 100, y: 100, width: 1200, height: 800), screenCGFrames: [left, right]),
            0
        )
        XCTAssertEqual(
            WindowLiftAvoidance.owningContextIndex(for: CGRect(x: 1600, y: 0, width: 1800, height: 1000), screenCGFrames: [left, right]),
            1
        )
        // Spanning screens, neither over half: the one with the larger overlap.
        XCTAssertEqual(
            WindowLiftAvoidance.owningContextIndex(for: CGRect(x: 1000, y: 0, width: 1200, height: 900), screenCGFrames: [left, right]),
            1
        )
        XCTAssertNil(
            WindowLiftAvoidance.owningContextIndex(for: CGRect(x: 5000, y: 0, width: 100, height: 100), screenCGFrames: [left, right])
        )
        XCTAssertNil(WindowLiftAvoidance.owningContextIndex(for: .zero, screenCGFrames: [left]))
    }
}
