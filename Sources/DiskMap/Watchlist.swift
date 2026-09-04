import Foundation

/// One spelling of a path, for everything that has to agree on what a target is.
///
/// The watchlist, the overnight claim and a snapshot's `target` are matched as
/// strings, so they must be produced the same way: `/tmp/../tmp` and `/tmp/`
/// are the same folder, and two of the three deciding otherwise means a night
/// scanned twice or a claim that never matches.
enum TargetPath {
    static func normalise(_ url: URL) -> URL { url.standardizedFileURL }
    static func normalise(_ path: String) -> String { normalise(URL(fileURLWithPath: path)).path }
}

/// The targets Reclaim rescans on its own, whether or not a window is showing them.
///
/// A window's overnight rescan can only refresh what somebody happened to leave
/// open, which is why history so often holds a single scan of a folder and
/// cannot say what changed. The watchlist is the other half: a short list of
/// things worth a point a night, kept in defaults so it survives quitting.
///
/// Paths, not bookmarks: this app is not sandboxed, a path is what every other
/// part of it already speaks, and a target that has gone away is better shown
/// as missing than silently resolved to somewhere else.
@MainActor
final class Watchlist: ObservableObject {
    static let key = "WatchedTargets"

    /// Shared because two places show the same list — Settings edits it, the
    /// schedule reads it — and they must not drift apart.
    static let shared = Watchlist()

    @Published private(set) var targets: [String] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        targets = Self.read(from: defaults)
    }

    private static func read(from defaults: UserDefaults) -> [String] {
        let stored = defaults.array(forKey: key) as? [String] ?? []
        // Normalised on the way in, so "/Users/x/" and "/Users/x" are one entry.
        var seen = Set<String>()
        return stored.map(Self.normalise).filter { seen.insert($0).inserted }
    }

    /// The same spelling every other part of the app uses. See `TargetPath`.
    static func normalise(_ path: String) -> String { TargetPath.normalise(path) }

    func contains(_ path: String) -> Bool { targets.contains(Self.normalise(path)) }

    func add(_ path: String) {
        let path = Self.normalise(path)
        guard !targets.contains(path) else { return }
        targets.append(path)
        save()
        Log.info("watchlist added", ["target": path, "count": "\(targets.count)"])
    }

    func remove(_ path: String) {
        let path = Self.normalise(path)
        guard targets.contains(path) else { return }
        targets.removeAll { $0 == path }
        save()
        Log.info("watchlist removed", ["target": path, "count": "\(targets.count)"])
    }

    func toggle(_ path: String) {
        contains(path) ? remove(path) : add(path)
    }

    private func save() {
        defaults.set(targets, forKey: Self.key)
    }
}

/// Posted after an unattended scan files a snapshot, so windows that are open
/// can pick up the new history without the user asking.
extension Notification.Name {
    static let reclaimHistoryChanged = Notification.Name("reclaim.historyChanged")
}
