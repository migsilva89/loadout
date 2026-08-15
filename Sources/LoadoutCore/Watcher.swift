import Foundation
import CoreServices

/// Watches the config directories and asks for a rescan when they change.
///
/// Edits arrive in bursts — a save is several filesystem events, a `git checkout` is hundreds —
/// so callbacks are coalesced into one call per quiet period (AC8.3).
public final class Watcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "loadout.watcher")
    private let coalescing: TimeInterval
    private var pending: DispatchWorkItem?
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()

    /// Counts how many times the callback actually fired. Used by the tests to prove the
    /// coalescing works rather than just assuming it does.
    public private(set) var firedCount = 0

    public init(coalescing: TimeInterval = 0.4, onChange: @escaping @Sendable () -> Void) {
        self.coalescing = coalescing
        self.onChange = onChange
    }

    deinit { stop() }

    public func start(watching directories: [URL]) {
        stop()
        let existing = directories.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            watcher.schedule()
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            existing.map(\.path) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
            )
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        lock.lock()
        pending?.cancel()
        pending = nil
        lock.unlock()
    }

    /// Debounces: each event pushes the callback further out, so a burst produces one call.
    public func schedule() {
        lock.lock()
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.firedCount += 1
            self.lock.unlock()
            self.onChange()
        }
        pending = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + coalescing, execute: work)
    }
}
