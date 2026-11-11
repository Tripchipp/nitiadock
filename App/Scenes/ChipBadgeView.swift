import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Chip Badge

/// Classic Dock-style unread badge: red capsule, white text, top-right of the chip.
/// Renders whatever string the app put on its Dock tile ("3", "99+", "•") as-is.
/// Not a hit target: taps fall through to the chip underneath.
///
/// **It is drawn by the chip itself (the overlay of `ChipView.bareIconChip` / `LauncherChip`), not stacked on
/// by the caller
/// through a wrapping ZStack.** Before 2026-08-17 it was the latter, so it sat **outside**
/// `chipQuietHoverScale`:
/// on quiet-mode hover the icon grew 10% while the red dot did not move (measured: 16×15pt in both frames),
/// which looked like the icon bulging out from under the dot. Inside the chip it follows hover scale-up,
/// press shrink and tier scaling.
///
/// Size constants live in `ChipPillMetrics.badge*`; the medium tier is identical to the historical literals.
struct ChipBadgeView: View {
    let text: String
    /// Tier factor. **Deliberately no default value**, same hard rule as `scale` / `hoverStyle`.
    let scale: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: ChipPillMetrics.badgeFontSize * scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, ChipPillMetrics.badgeHorizontalPadding * scale)
            .frame(minWidth: ChipPillMetrics.badgeMinimumSize * scale,
                   minHeight: ChipPillMetrics.badgeMinimumSize * scale)
            .background(
                Capsule().fill(Color(red: 1.0, green: 0.23, blue: 0.19))   // Apple badge red
            )
            .overlay(
                // 0.5pt is a hairline; like the dividers it does not scale with the tier.
                Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
            )
            // The native badge mostly sits on the icon and only slightly pokes past the rounded corner: card
            // 40×54, visible icon square 32.5,
            // and this downward offset puts the badge center just inside the icon's top-right corner.
            .offset(x: 0, y: ChipPillMetrics.badgeTopOffset * scale)
            .allowsHitTesting(false)
    }
}
