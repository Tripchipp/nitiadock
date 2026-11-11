import XCTest

final class ScheduledUpdatePresentationTests: XCTestCase {

    /// First encounter with a version: the user must be told directly. For an `.accessory` app, not coming to
    /// the front equals no prompt.
    func testFirstSightingOfAVersionAnnounces() {
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.2", userInitiated: false, announcedVersion: nil),
            .announce
        )
    }

    /// The second scheduled check for the same version no longer takes the foreground; the status bar dot
    /// reminds instead. This is the only thing that prevents nagging after the interval went from one day to
    /// 6 hours.
    func testSameVersionRemindsQuietly() {
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.2", userInitiated: false, announcedVersion: "0.9.2"),
            .remindQuietly
        )
    }

    /// Another version came out: that is news, worth taking the foreground once more.
    func testNewerVersionAnnouncesAgain() {
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.3", userInitiated: false, announcedVersion: "0.9.2"),
            .announce
        )
    }

    /// A check the user started: Sparkle guarantees it comes to the front and we stay out of it. It also must
    /// not mark "already prompted", otherwise one manual check would eat the later prompt that really needs
    /// the foreground.
    func testUserInitiatedDefersToSparkle() {
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.2", userInitiated: true, announcedVersion: nil),
            .deferToSparkle
        )
        XCTAssertEqual(
            ScheduledUpdatePresentation.decide(version: "0.9.2", userInitiated: true, announcedVersion: "0.9.2"),
            .deferToSparkle
        )
    }
}
