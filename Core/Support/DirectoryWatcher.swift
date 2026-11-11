import Foundation

/// Directory change watcher: `open(path, O_EVTONLY)` + `DispatchSourceFileSystemObject`, calls back on the
/// main thread after a ~0.3s debounce. Shared by cover refresh, Trash empty/full and live popover refresh.
///
/// fd lifecycle: the fd is closed only in the source's cancel handler (never close before cancel, or the fd
/// may be reused and someone else's closed by mistake); `stop()` is idempotent, deinit is the fallback.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private let debounceInterval: TimeInterval
    private let onChange: () -> Void

    /// Returns nil when the path cannot be opened (missing / no permission); the caller degrades on its own.
    /// The callback is guaranteed on the main thread.
    init?(path: String, debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.debounceInterval = debounce
        self.onChange = onChange

        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.resume()
        self.source = source
    }

    /// Debounced on the main queue: an event storm (bulk copy) triggers a single callback.
    private func scheduleChange() {
        debounceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.source != nil else { return }
            self.onChange()
        }
        debounceWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    func stop() {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        source?.cancel()
        source = nil
    }

    deinit {
        debounceWorkItem?.cancel()
        source?.cancel()
    }
}
