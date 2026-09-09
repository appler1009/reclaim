import Foundation

/// Watches a volume's Trash and says when something has happened to it.
///
/// The header strip reports what is sitting in the Trash — space that is spoken
/// for but not yet given back. It was measured when a scan finished and when
/// this app put something there, which left out the one moment the figure most
/// needs to change: somebody emptying the Trash in Finder. Until the next scan
/// the strip went on describing gigabytes that had already come back, which is
/// worse than not showing the figure at all.
///
/// Directory events rather than a poll. Emptying the Trash happens at a moment;
/// a timer either misses it for a while or asks, over and over, a question
/// whose answer almost never changes — and the answer costs a walk of a
/// directory that may hold a great many files.
@MainActor
final class TrashWatcher {
    /// How long to let events settle before believing them.
    ///
    /// Emptying the Trash is not one event but hundreds, one per item removed.
    /// Measuring on the first would count a Trash that is still emptying, and
    /// measuring on each would be a walk of the directory per file deleted.
    static let settle: TimeInterval = 0.4

    /// Called on the main actor once the Trash has settled after changing.
    var onChange: () -> Void

    private var sources: [DispatchSourceFileSystemObject] = []
    /// Which run of the debounce is current. A note that arrives while another
    /// is pending supersedes it, and the superseded one does nothing when its
    /// turn comes.
    private var generation = 0
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(onChange: @escaping () -> Void = {},
         schedule: ((TimeInterval, @escaping () -> Void) -> Void)? = nil) {
        self.onChange = onChange
        self.schedule = schedule ?? { after, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
        }
    }

    deinit {
        for source in sources { source.cancel() }
    }

    /// Watches the Trash of the volume `url` sits on, in place of whatever was
    /// being watched before. Watching nothing is a legitimate state: a volume
    /// with no Trash directory yet has nothing to report until it has one.
    func watch(volumeContaining url: URL) {
        stop()
        let volume = TrashInspector.volumeRoot(containing: url)
        for trash in TrashInspector.trashURLs(forVolumeAt: volume) {
            guard let source = Self.source(for: trash) else { continue }
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.noteChange() }
            }
            source.resume()
            sources.append(source)
        }
        Log.debug("watching trash", ["volume": volume.path, "sources": "\(sources.count)"])
    }

    func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
    }

    /// An event arrived. Exposed so the debounce can be exercised without a
    /// filesystem underneath it.
    func noteChange() {
        generation += 1
        let mine = generation
        schedule(Self.settle) { [weak self] in
            guard let self, mine == self.generation else { return }
            self.onChange()
        }
    }

    /// A descriptor opened only to be watched, and closed when the source that
    /// holds it is cancelled.
    private static func source(for directory: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // What emptying looks like from outside: children going, the
            // directory being rewritten, and — if the Trash itself is replaced
            // — the descriptor going stale under us.
            eventMask: [.write, .delete, .rename, .revoke, .extend],
            queue: .main)
        source.setCancelHandler { close(descriptor) }
        return source
    }
}
