import Darwin
import Foundation

/// The single contract for process liveness (POSIX `kill(pid, 0)`).
///
/// The batch-delete path of `AppTracker.reconcile()` used to declare death via
/// `NSRunningApplication(processIdentifier:) == nil`. That API resolves through LaunchServices and can
/// transiently return `nil` for a **live** process (observed with Feishu, Obsidian and others), so the whole
/// `AppEntry` and all its seats were deleted by the batch path of `reconcile()`, bypassing the per-seat grace
/// period and phantom protection. `scanNonAdmittedApps()` then readmitted the same pid with a brand-new seat
/// token, and combined with `StripOrderStore`'s 5s absence grace, one window got two cards.
///
/// POSIX only here: `kill` returning 0 means alive; -1 with `errno == ESRCH` is the only dead verdict;
/// `EPERM` (process exists but we may not signal it) and every other errno conservatively count as alive.
/// **Never** fall back to `NSRunningApplication` / `NSWorkspace` / other LaunchServices state. The same-named
/// file in the old dirty worktree fell back to LaunchServices on unknown errno; that implementation is wrong
/// and must not be ported wholesale.
///
/// Depends only on Darwin, no AppKit / ApplicationServices, so the errno matrix is easy to unit test.
enum ProcessLiveness {
    /// Checks whether a process is alive with POSIX `kill(pid, 0)`.
    static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        return interpret(result: kill(pid, 0), errorCode: errno)
    }

    /// Pure decision function, so the errno matrix tests can feed synthetic values without a syscall:
    /// - `result == 0`: alive
    /// - `result != 0` and `errorCode == ESRCH`: dead (no such process)
    /// - `EPERM` and every other errno such as `EINTR` / `EINVAL` / `EAGAIN`: alive (conservative)
    static func interpret(result: Int32, errorCode: Int32) -> Bool {
        if result == 0 { return true }
        return errorCode != ESRCH
    }

    /// Process **start time** (`KERN_PROC_PID` sysctl reading `kinfo_proc.kp_proc.p_starttime`).
    ///
    /// Purpose: pids are reused. During an async probe process A may exit and B take over its pid, and
    /// neither `isTerminated` nor `activationPolicy` can detect that the instance changed. `pid + start time`
    /// is the stable process generation identity. **Do not use `NSRunningApplication.launchDate`**: it can be
    /// nil, and when it is missing you either let it through (preloading the old process's AX elements into
    /// the new one) or reject it (some apps never get into the rescan), both are traps; sysctl always has a
    /// value for a live process.
    ///
    /// Returns nil when the process no longer exists (for a missing pid sysctl returns 0 but sets size to 0,
    /// so size must be checked).
    static func startTime(pid: pid_t) -> timeval? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info.kp_proc.p_starttime
    }
}

/// Values valid for one process generation (`pid` + start time), remembered across LaunchServices
/// hiccups: a pid lookup such as `GetProcessForPID` fails transiently for a live process (the same
/// instant `NSRunningApplication(processIdentifier:)` returns nil), and a value seen earlier stays
/// correct as long as the pid still belongs to the same process. Thread-safe; readers sit on the
/// concurrent action queue. `startTime` is injectable for tests only.
final class ProcessGenerationCache<Value> {
    private struct Entry {
        let startTime: timeval
        let value: Value
    }

    private var entries: [pid_t: Entry] = [:]
    private let lock = NSLock()
    private let startTime: (pid_t) -> timeval?

    init(startTime: @escaping (pid_t) -> timeval? = ProcessLiveness.startTime(pid:)) {
        self.startTime = startTime
    }

    func remember(_ value: Value, for pid: pid_t) {
        guard let start = startTime(pid) else { return }
        lock.lock(); defer { lock.unlock() }
        entries[pid] = Entry(startTime: start, value: value)
    }

    /// nil when nothing was remembered, the process is gone, or the pid now belongs to a new process.
    func value(for pid: pid_t) -> Value? {
        guard let start = startTime(pid) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[pid],
              entry.startTime.tv_sec == start.tv_sec, entry.startTime.tv_usec == start.tv_usec else {
            entries[pid] = nil
            return nil
        }
        return entry.value
    }
}
