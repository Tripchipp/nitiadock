# Changelog

What changed in each NitiaDock release, written for people who use the app.

## 1.0.1

Fixes from a review of the whole app.

- The taskbar no longer freezes for seconds when an app that is starting up or not responding
  becomes active.
- Dragging the Settings card to another display, and other work on NitiaDock's own windows, no
  longer risks a crash.
- Dropping a file on a pinned folder on the same disk moves it, and the pointer now says so: the
  green plus only shows when the file is really copied (a folder on another disk).
- Apps and other packages inside a pinned folder open when clicked instead of showing their
  insides.
- Windows that NitiaDock had made room for go back to their own size at the next launch if
  NitiaDock quit unexpectedly.
- Fullscreen detection recovers by itself after a busy spell instead of staying off until restart.
- The macOS question about controlling Finder no longer blocks the taskbar while it is open.
- Two windows of one app with the same position no longer make a card jump to the end.
- No crash when every display is disconnected for a moment.
- Privacy: folder paths and window titles are no longer readable in the system log, the list of
  recently opened documents is readable by your user account only, and the README now says that
  this list exists.
- Updates: Sparkle 2.10.1, and the update address can no longer be redirected through the app's
  preferences.

## 1.0.0

The first release you can download. It is signed with a Developer ID and notarized by Apple, so it
opens without warnings.

- One card per window along the bottom of the screen. Click a card to bring its window forward;
  click again to minimize it.
- An Appearance page for the taskbar and the window cards: light, dark or follow-the-system tint,
  opacity, corner radius, card width, title size and spacing.
- Unread badges for any app, not just chat apps.
- Middle-click a Finder or browser card to open a new window.
- Works with several displays: one taskbar that follows the pointer, or one on each display.
- Optional: reserve screen space so windows do not end up under the taskbar.
- No telemetry and no account.
