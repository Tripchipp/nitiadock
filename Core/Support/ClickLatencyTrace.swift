import Foundation

/// Where the time goes between a click and the window actually moving. Off by default, enabled with
/// `DOCK_CLICK_TRACE=1`.
///
/// **Why it exists**: the repo has been burned several times by "estimate latency from constants in the code,
/// then decide from the estimate". The
/// 2026-08-11 round changes handle capture for minimize restore, and before and after must be measured with
/// the same ruler. It was timestamping the moment slps landed that made it obvious
/// "flashing cases land at +400~900ms, clean cases within +220ms". Verifying only the end state does not show
/// that.
///
/// Paired by `windowID`, without changing any existing function signature (execution is on another thread, so
/// task-locals cannot carry it). Two quick clicks on the same card overlap, acceptable for diagnostics: `end`
/// is flushed in pairs in order of occurrence.
enum ClickLatencyTrace {
    static let isEnabled = DebugSwitch.clickTrace.isEnabled(in: ProcessInfo.processInfo.environment)

    /// Start of a click. `kind` = the planned action, `status` = the window state in the snapshot (for
    /// classification).
    static func begin(windowID: String, kind: String, status: String, bundleID: String?) {
        guard isEnabled else { return }
        runtime.begin(windowID: windowID, kind: kind, status: status, bundleID: bundleID,
                      at: ProcessInfo.processInfo.systemUptime)
    }

    /// Intermediate milestone. `detail` records branch information such as "which tier the handle hit".
    static func mark(windowID: String?, _ stage: String, detail: String? = nil) {
        guard isEnabled, let windowID else { return }
        runtime.mark(windowID: windowID, stage: stage, detail: detail,
                     at: ProcessInfo.processInfo.systemUptime)
    }

    static func end(windowID: String?, success: Bool) {
        guard isEnabled, let windowID else { return }
        runtime.end(windowID: windowID, success: success,
                    at: ProcessInfo.processInfo.systemUptime)
    }

    private static let runtime = Runtime()

    private final class Runtime: @unchecked Sendable {
        private let queue = DispatchQueue(label: "no.thilip.nitiadock.click-latency-trace")
        private var sessions: [String: Session] = [:]

        private struct Session {
            let windowID: String
            let kind: String
            let status: String
            let bundleID: String?
            let startedAt: TimeInterval
            var stages: [(String, TimeInterval, String?)] = []
        }

        func begin(windowID: String, kind: String, status: String, bundleID: String?, at: TimeInterval) {
            queue.async { [self] in
                sessions[windowID] = Session(windowID: windowID, kind: kind, status: status,
                                             bundleID: bundleID, startedAt: at)
            }
        }

        func mark(windowID: String, stage: String, detail: String?, at: TimeInterval) {
            queue.async { [self] in
                sessions[windowID]?.stages.append((stage, at, detail))
            }
        }

        func end(windowID: String, success: Bool, at: TimeInterval) {
            queue.async { [self] in
                guard let session = sessions.removeValue(forKey: windowID) else { return }
                append(line: line(for: session, success: success, endedAt: at))
            }
        }

        /// Milliseconds, relative to `t_tap`. Written as flat JSON, one line per click, so `jq` gives
        /// percentiles directly.
        private func line(for session: Session, success: Bool, endedAt: TimeInterval) -> String {
            func ms(_ t: TimeInterval) -> Double { ((t - session.startedAt) * 1000 * 100).rounded() / 100 }
            var fields: [String] = [
                "\"kind\":\(quote(session.kind))",
                "\"status\":\(quote(session.status))",
                "\"bundleID\":\(session.bundleID.map(quote) ?? "null")",
                "\"success\":\(success)",
                "\"totalMs\":\(ms(endedAt))"
            ]
            for (stage, at, detail) in session.stages {
                fields.append("\"\(stage)Ms\":\(ms(at))")
                if let detail { fields.append("\"\(stage)Detail\":\(quote(detail))") }
            }
            return "{\(fields.joined(separator: ","))}"
        }

        private func quote(_ value: String) -> String {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }

        private lazy var fileURL: URL? = {
            let fm = FileManager.default
            guard let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
            let dir = base.appendingPathComponent("Logs/no.thilip.nitiadock", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("click-latency.jsonl")
        }()

        private func append(line: String) {
            guard let fileURL else { return }
            TraceFile.append(line, to: fileURL)
        }
    }
}
