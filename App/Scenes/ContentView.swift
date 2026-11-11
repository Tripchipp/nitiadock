import AppKit
import SwiftUI

struct ContentView: View {
    let snapshot: DockSnapshot
    let hasRequiredPermissions: Bool
    let observationStatusText: String
    let feedbackEntriesByWindowID: [String: IntentFeedbackState.Entry]
    let onToggle: (String) -> Void
    let onActivate: (String) -> Void
    let onMinimize: (String) -> Void
    let onHide: (String) -> Void
    let onClose: (String) -> Void

    private var stripItems: [StripItem] {
        StripItem.items(from: snapshot)
    }

    private var visibleStatusCount: Int {
        stripItems.filter { $0.status != WindowStatus.disappeared.rawValue }.count
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.12, blue: 0.16),
                    Color(red: 0.14, green: 0.17, blue: 0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                Text("Taskbar Debug Console")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Text("The bottom taskbar is now driven by the real window observation pipeline. When Feishu's window-level information is unreliable, it falls back to one stable app-level entry.")
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 18) {
                    summaryPill(label: "Tracked", value: "\(stripItems.count)")
                    summaryPill(label: "Visible", value: "\(visibleStatusCount)")
                    summaryPill(label: "Permissions", value: hasRequiredPermissions ? "Accessibility ready" : "Window list only")
                    summaryPill(label: "Startup", value: observationStatusText)
                }

                if hasRequiredPermissions == false {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accessibility permission has not been granted.")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("The taskbar can still show some windows from the system window list, but until the permission is enabled, window titles, minimized state and position evidence are incomplete.")
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
                }

                Spacer(minLength: 0)

                if stripItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No windows tracked yet")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Keep the app open, then switch or move a few windows. Entries appear in the bottom taskbar once the observation pipeline writes a snapshot.")
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Taskbar")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(stripItems, id: \.id) { item in
                                taskStripChip(item)
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.black.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }
            .padding(24)
        }
    }

    private func summaryPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: Capsule())
    }

    // Interruptible (2026-06-13): the debug console matches the main taskbar: pending no longer locks clicks
    // / greys out /
    // spins; the feedback text row stays (pending/success/failure is diagnostic information).
    @ViewBuilder
    private func taskStripChip(_ item: StripItem) -> some View {
        let feedback = feedbackEntriesByWindowID[item.id]

        Group {
            if item.showsTitle {
                expandedTaskStripChip(item, feedback: feedback)
            } else {
                compactTaskStripChip(item, feedback: feedback)
            }
        }
        .help(localizedTitle(item))
        .contextMenu {
            taskStripContextMenu(item)
        }
        .animation(.easeInOut(duration: 0.18), value: item.showsTitle)
    }

    private func expandedTaskStripChip(
        _ item: StripItem,
        feedback: IntentFeedbackState.Entry?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                appIcon(for: item)
                Text(localizedTitle(item))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            HStack(spacing: 8) {
                Text(localizedStatus(item.status))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                if item.isAppLevelFallback {
                    Text("App")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.17, green: 0.22, blue: 0.18))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(red: 0.77, green: 0.91, blue: 0.68), in: Capsule())
                }
            }

            if let feedback {
                HStack(spacing: 6) {
                    Circle()
                        .fill(feedbackColor(feedback))
                        .frame(width: 7, height: 7)
                    Text(feedbackText(feedback))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(feedbackColor(feedback))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(feedbackColor(feedback).opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack(spacing: 8) {
                actionButton(label: "Activate") {
                    onActivate(item.id)
                }

                if item.canHide {
                    actionButton(label: "Hide") {
                        onHide(item.id)
                    }
                }

                if item.canMinimize {
                    actionButton(label: "Minimize") {
                        onMinimize(item.id)
                    }
                }

                if item.canClose {
                    actionButton(label: "Close") {
                        onClose(item.id)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {
            onToggle(item.id)
        }
    }

    private func compactTaskStripChip(
        _ item: StripItem,
        feedback: IntentFeedbackState.Entry?
    ) -> some View {
        let borderColor = feedback.map { feedbackColor($0).opacity(0.36) } ?? Color.white.opacity(0.08)

        return appIcon(for: item)
            .padding(12)
            .frame(width: 58, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .onTapGesture {
                onToggle(item.id)
            }
    }

    @ViewBuilder
    private func taskStripContextMenu(_ item: StripItem) -> some View {
        Button("Activate") {
            onActivate(item.id)
        }

        if item.canHide {
            Button("Hide") {
                onHide(item.id)
            }
        }

        if item.canMinimize {
            Button("Minimize") {
                onMinimize(item.id)
            }
        }

        if item.canClose {
            Divider()
            Button("Close") {
                onClose(item.id)
            }
        }
    }

    private func appIcon(for item: StripItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: AppIconResolver.icon(for: item.bundleIdentifier ?? item.appID))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)

            Circle()
                .fill(statusColor(item.status))
                .frame(width: 9, height: 9)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.46), lineWidth: 1)
                )
                .offset(x: 2, y: 2)
        }
        .frame(width: 32, height: 32)
        .accessibilityLabel("\(localizedTitle(item)) app icon")
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case WindowStatus.minimized.rawValue:
            return Color(red: 0.95, green: 0.74, blue: 0.21)
        case WindowStatus.hidden.rawValue:
            return Color(red: 0.85, green: 0.48, blue: 0.24)
        case WindowStatus.disappeared.rawValue:
            return Color(red: 0.64, green: 0.66, blue: 0.70)
        case WindowStatus.active.rawValue:
            return Color(red: 0.35, green: 0.82, blue: 0.56)
        default:
            return Color(red: 0.43, green: 0.66, blue: 1.0)
        }
    }

    private func actionButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.82))
    }

    private func feedbackText(_ feedback: IntentFeedbackState.Entry) -> String {
        switch feedback.phase {
        case .pending:
            switch feedback.action {
            case .toggle:
                return "Trying to toggle this window"
            case .activate:
                return "Trying to bring this window to the front"
            case .minimize:
                return "Trying to minimize this window"
            case .hide:
                return "Trying to hide this app"
            case .close:
                return "Trying to close this window"
            case .quit:
                return "Trying to quit this app"
            case .newWindow:
                return "Trying to open a new window"
            }
        case .success:
            switch feedback.action {
            case .toggle:
                return "This window was toggled"
            case .activate:
                return "This window was brought to the front"
            case .minimize:
                return "This window was minimized"
            case .hide:
                return "This app was hidden"
            case .close:
                return "This window was closed"
            case .quit:
                return "This app was quit"
            case .newWindow:
                return "New window requested"
            }
        case .failure:
            switch feedback.action {
            case .toggle:
                return "Could not toggle this window"
            case .activate:
                return "Could not bring this window to the front"
            case .minimize:
                return "Could not minimize this window"
            case .hide:
                return "Could not hide this app"
            case .close:
                return "Could not close this window"
            case .quit:
                return "Could not quit this app"
            case .newWindow:
                return "Could not open a new window"
            }
        }
    }

    private func localizedTitle(_ item: StripItem) -> String {
        item.title
    }

    private func localizedStatus(_ status: String) -> String {
        switch status {
        case WindowStatus.active.rawValue:
            return "Active"
        case WindowStatus.inactive.rawValue:
            return "Inactive"
        case WindowStatus.minimized.rawValue:
            return "Minimized"
        case WindowStatus.hidden.rawValue:
            return "Hidden"
        case WindowStatus.closedPending.rawValue:
            return "Confirming close"
        case WindowStatus.disappeared.rawValue:
            return "Temporarily gone"
        default:
            return status
        }
    }

    private func feedbackColor(_ feedback: IntentFeedbackState.Entry) -> Color {
        switch feedback.phase {
        case .pending:
            return Color(red: 0.95, green: 0.74, blue: 0.21)
        case .success:
            return Color(red: 0.35, green: 0.82, blue: 0.56)
        case .failure:
            return Color(red: 0.95, green: 0.43, blue: 0.40)
        }
    }
}

struct DebugConsoleView: View {
    @EnvironmentObject var runtime: AppRuntime
    @EnvironmentObject var debugState: DebugRuntimeState

    var body: some View {
        ContentView(
            snapshot: runtime.snapshot,
            hasRequiredPermissions: runtime.hasRequiredPermissions,
            observationStatusText: debugState.observationStatusText,
            feedbackEntriesByWindowID: debugState.feedbackEntriesByWindowID,
            onToggle: runtime.toggle(windowID:),
            onActivate: runtime.activate(windowID:),
            onMinimize: runtime.minimize(windowID:),
            onHide: runtime.hide(windowID:),
            onClose: runtime.close(windowID:)
        )
    }
}

enum AppIconResolver {
    /// **A plain dictionary, not `NSCache`.** Main-thread sampling on 2026-09-04 (120s): the `NSCache`
    /// version was measured to be evicting constantly.
    /// `iconForFile:` took about 1 second of main thread (LaunchServices binding + IconServices resolution,
    /// about 1ms each), and every
    /// card body looks it up on each recompute: opening the drawer recomputes all cards, a drag start/end
    /// recomputes the whole bar a dozen times, the once-per-second snapshot heartbeat
    /// recomputes the bars on both displays, all paying this cost. It is the largest measurable single item
    /// in the "panel animation frame-rate feel" card.
    /// Entry count = number of bundle ids ever seen (a few dozen), always fits; called on the main thread
    /// only (SwiftUI body / bitmap snapshot).
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleIdentifier: String) -> NSImage {
        if let cached = cache[bundleIdentifier] {
            return cached
        }

        let icon: NSImage
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            icon = NSWorkspace.shared.icon(for: .applicationBundle)
        }

        icon.size = NSSize(width: 32, height: 32)
        if cache.count >= 512 { cache.removeAll() }   // only guards unbounded growth; never reached in normal use
        cache[bundleIdentifier] = icon
        return icon
    }
}
