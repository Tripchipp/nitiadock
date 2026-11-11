import Foundation

/// How loudly to tell the user this time, after a scheduled check found a new version.
///
/// Pure decision, touches neither Sparkle nor AppKit, unit-testable. The caller
/// (`SparkleUpdateService`) translates the verdict into "let Sparkle open its window
/// or not", "bring the app to the front or not", "keep a status bar hint or not".
///
/// ## Why it is needed
///
/// NitiaDock is an `.accessory` app, so the update window from a scheduled check appears **behind all
/// windows** by default where the user cannot see it, which is why we always brought the app to the
/// front unconditionally. That was fine at "one check a day", but at every 6 hours it became a nuisance:
/// the user closes the window and gets the foreground stolen again
/// a few hours later, long after they know about the new version.
///
/// Sparkle leaves an opening for this (`standardUserDriverShouldHandleShowingScheduledUpdate:`:
/// returning `NO` means "I will show my own UI this round, do not open a window"). So the split becomes:
///
/// - **First time for a given version**: open the window + take
///   the foreground as before, so the user is sure to see it;
/// - **Second time and later**: no window, no foreground, and
///   the small dot on the menu bar icon keeps reminding instead.
///
/// The hint itself is not managed here: the status bar dot stays from "new version found"
/// until the user installs it, skips it, or a later check finds no update anymore.
enum ScheduledUpdatePresentation {
    enum Outcome: Equatable {
        /// Let Sparkle open the update window, and we bring the
        /// app to the front. **Each version gets this only once.**
        case announce
        /// No window, no foreground, only the status bar hint.
        case remindQuietly
        /// The user clicked "Check for Updates" themselves. Sparkle
        /// guarantees this path comes to the front; we stay out of it.
        case deferToSparkle
    }

    /// - Parameters:
    ///   - version: Version string of this appcast item (`SUAppcastItem.displayVersionString`)
    ///   - userInitiated: `SPUUserUpdateState.userInitiated`
    ///   - announcedVersion: The version that already took the foreground once; `nil` = not yet in this run
    static func decide(
        version: String,
        userInitiated: Bool,
        announcedVersion: String?
    ) -> Outcome {
        // A check the user triggered is unaffected: a repeated activate
        // is pointless, Sparkle already brought it to the front.
        guard !userInitiated else { return .deferToSparkle }

        // This version was already shown to the user directly. Taking the
        // foreground again is a nuisance; leave it to the status bar dot.
        if announcedVersion == version { return .remindQuietly }

        return .announce
    }
}
