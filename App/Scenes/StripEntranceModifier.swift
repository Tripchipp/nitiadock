import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Strip Entrance Modifier

struct StripEntranceModifier: ViewModifier {
    /// `nil` = no entrance animation this time. **The carrier snapshot takes this path**: the entrance
    /// `@State` starts from `opacity 0 / offset 8` and only flips to final in `onAppear`, while the snapshot
    /// is captured synchronously, so without turning it off the capture would be a half-transparent image
    /// offset 8pt upward.
    let id: String?
    let delay: Double
    @Binding var animatedEntryIDs: Set<String>

    @State private var isAppeared = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if let id {
            animated(content, id: id)
        } else {
            content
        }
    }

    private func animated(_ content: Content, id: String) -> some View {
        content
            .offset(y: isAppeared ? 0 : 8)
            .opacity(isAppeared ? 1 : 0)
            .onAppear {
                if animatedEntryIDs.contains(id) {
                    isAppeared = true
                } else {
                    // Stagger past the first-frame layout to avoid flying in from the coordinate origin
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8).delay(delay)) {
                            isAppeared = true
                        }
                        animatedEntryIDs.insert(id)
                    }
                }
            }
    }
}

extension View {
    func stripEntrance(id: String?, delay: Double, animatedEntryIDs: Binding<Set<String>>) -> some View {
        self.modifier(StripEntranceModifier(id: id, delay: delay, animatedEntryIDs: animatedEntryIDs))
    }
}
