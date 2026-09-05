import Foundation

/// What was open last time, so a restart can put it back.
///
/// Targets only — not the folder that was drilled into, not what was picked for
/// the Trash. A path is the one piece of state that still means the same thing
/// after the disk has been used for a week; a tree is not, and a staged
/// deletion least of all, which is why neither is written down here.
struct SessionState: Codable, Equatable {
    /// One window, and the tabs it held in the order the tab bar had them.
    struct Window: Codable, Equatable {
        var targets: [String]
    }

    var windows: [Window] = []

    var isEmpty: Bool { windows.allSatisfy(\.targets.isEmpty) }
    /// Every target, in the order they should be reopened.
    var targets: [String] { windows.flatMap(\.targets) }

    /// One open tab as the app can see it, before AppKit is involved.
    ///
    /// `group` is whatever identifies the tab group a window sits in — windows
    /// sharing one are tabs of each other, and a window standing alone has
    /// none. Kept as a plain number so the grouping can be worked out in a test
    /// without conjuring `NSWindow`s.
    struct OpenTab: Equatable {
        let group: Int?
        let target: String
    }

    /// Groups tabs into windows, keeping the order they arrived in.
    ///
    /// A window with no tab group is its own entry: on a stock Mac that is what
    /// most windows are, and putting them all in one group on restore would
    /// gather up windows the user deliberately kept apart.
    static func of(_ tabs: [OpenTab]) -> SessionState {
        var windows: [Window] = []
        /// Where each group's entry landed, so the second tab of a group joins
        /// the first rather than starting another window.
        var seen: [Int: Int] = [:]

        for tab in tabs {
            let target = TargetPath.normalise(tab.target)
            guard let group = tab.group else {
                windows.append(Window(targets: [target]))
                continue
            }
            if let index = seen[group] {
                windows[index].targets.append(target)
            } else {
                seen[group] = windows.count
                windows.append(Window(targets: [target]))
            }
        }
        return SessionState(windows: windows)
    }
}

/// Where the session is kept between runs.
///
/// Defaults rather than a file beside the snapshots: this is a handful of
/// paths describing an arrangement of windows, which is preference-shaped, and
/// it should be as easy to throw away as a preference.
struct SessionStore {
    static let key = "OpenSession"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SessionState {
        guard let data = defaults.data(forKey: Self.key),
              let state = try? JSONDecoder().decode(SessionState.self, from: data) else {
            return SessionState()
        }
        // A target that has since gone — an unplugged disk, a deleted folder —
        // is dropped rather than reopened into a failed scan.
        var windows = state.windows.map { window in
            SessionState.Window(targets: window.targets.filter {
                FileManager.default.fileExists(atPath: $0)
            })
        }
        windows.removeAll { $0.targets.isEmpty }
        return SessionState(windows: windows)
    }

    func save(_ state: SessionState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
