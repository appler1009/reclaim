import AppKit
import Foundation

/// Puts back the windows and tabs that were open when the app last quit.
///
/// Two halves that have to agree. Reopening the *windows* is AppKit work —
/// a window standing alone, then tabs joined onto it — and it is done one at a
/// time, because each new scene produces exactly one `AppModel` and the order
/// they arrive in is how each one learns which target it is for.
///
/// Scanning them is the other half, and it is deliberately not done all at
/// once. Three restored tabs would otherwise mean three concurrent walks of the
/// filesystem every time the app opens, competing for the same disk and making
/// launch the slowest thing the app ever does. They queue, and the one in front
/// gets the disk to itself.
@MainActor
final class SessionRestore: ObservableObject {
    static let shared = SessionRestore()

    /// How long to wait for a window that was asked for. Past this the restore
    /// gives up rather than leaving the queue half-applied — the same patience
    /// `NewTab` allows, for the same reason.
    static let patience: TimeInterval = 2

    private let store: SessionStore
    /// Targets still to be handed out, in the order windows will be made.
    private var unclaimed: [String] = []
    /// The plan being applied, kept so tabs are joined to the right windows.
    private var plan: SessionState = SessionState()
    private(set) var isRestoring = false

    /// A scan waiting its turn.
    ///
    /// The model is held weakly: a tab closed while it waits should drop out of
    /// the queue, not be kept alive by it and then scanned for a window nobody
    /// is looking at.
    private struct Waiting {
        weak var model: AppModel?
        let url: URL
    }

    private var queue: [Waiting] = []
    private var scanning = false

    init(store: SessionStore = SessionStore()) {
        self.store = store
    }

    // MARK: - Reading the plan

    /// Reads what was open. Called before any scene exists, so the very first
    /// window's model can claim its target as it is built.
    func loadPlan() {
        plan = store.load()
        unclaimed = plan.targets
        isRestoring = !unclaimed.isEmpty
        if isRestoring {
            Log.info("session restore planned", ["windows": "\(plan.windows.count)",
                                                 "tabs": "\(unclaimed.count)"])
        }
    }

    /// The target a newly made window should show, if one is still owed.
    ///
    /// First come, first served, which is only correct because windows are
    /// opened one at a time — see `openWindows`.
    func claimTarget() -> URL? {
        guard !unclaimed.isEmpty else { return nil }
        return URL(fileURLWithPath: unclaimed.removeFirst())
    }

    // MARK: - Opening the windows

    /// Opens everything the plan asks for beyond the window the app already has.
    ///
    /// Every collaborator is a parameter so the whole sequence can be exercised
    /// without a scene: `openWindow` makes a window, `openTab` joins one to the
    /// window in front, and `settled` says when the last one arrived.
    func openWindows(openWindow: @escaping (@escaping () -> Void) -> Void,
                     openTab: @escaping (@escaping () -> Void) -> Void,
                     whenDone: @escaping () -> Void = {}) {
        // The first tab of the first window is the window the app opened by
        // itself; everything after it has to be asked for.
        var steps: [Bool] = []          // true = a new window, false = a tab
        for (index, window) in plan.windows.enumerated() {
            for (tab, _) in window.targets.enumerated() {
                if index == 0 && tab == 0 { continue }
                steps.append(tab == 0)
            }
        }
        guard !steps.isEmpty else {
            whenDone()
            return
        }

        func step(_ remaining: ArraySlice<Bool>) {
            guard let wantsWindow = remaining.first else {
                Log.info("session restored", ["windows": "\(self.plan.windows.count)"])
                whenDone()
                return
            }
            let next = remaining.dropFirst()
            let open = wantsWindow ? openWindow : openTab
            open { step(next) }
        }
        step(steps[...])
    }

    /// The live wiring: AppKit makes the windows, and the app's own New Tab
    /// action is what joins one to the window in front — the same path the menu
    /// takes, rather than a second way of making a tab that could disagree.
    func openWindows(whenDone: @escaping () -> Void = {}) {
        openWindows(openWindow: { done in
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
            // A new window has no completion; it is waited for the same way a
            // tab is, and the next step goes ahead regardless once it arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + NewTab.pollInterval) { done() }
        }, openTab: { done in
            NewTab.open(front: NSApp.keyWindow) { _ in done() }
        }, whenDone: whenDone)
    }

    /// Nothing more is owed. Called when the plan is spent, so a window opened
    /// afterwards is an ordinary new window and not handed somebody's target.
    func finish() {
        isRestoring = false
        unclaimed = []
    }

    // MARK: - Scanning, one at a time

    /// Takes a restored tab's scan, to run when the disk is free.
    func enqueue(_ model: AppModel, target: URL) {
        model.queuedTarget = target
        queue.append(Waiting(model: model, url: target))
        startNext()
    }

    private func startNext() {
        guard !scanning else { return }
        // A tab closed while it waited has nothing left to scan for.
        while let next = queue.first, next.model == nil {
            queue.removeFirst()
        }
        guard let next = queue.first, let model = next.model else { return }
        queue.removeFirst()
        scanning = true
        // Called straight through rather than hopped onto a Task: every place
        // a scan ends is already on the main actor, and the hop only delayed
        // the next scan by a turn of the loop.
        model.onScanEnded = { [weak self] in
            MainActor.assumeIsolated { self?.scanEnded() }
        }
        // Clears `queuedTarget` itself, which is what takes the window off the
        // waiting screen.
        model.scan(next.url)
    }

    private func scanEnded() {
        scanning = false
        startNext()
    }

    // MARK: - Writing it down

    /// Records what is open now. Cheap enough to call whenever it changes.
    func capture(_ tabs: [SessionState.OpenTab]) {
        store.save(SessionState.of(tabs))
    }

    /// Writes the arrangement down again, unless it is still being put back —
    /// half-restored is not a state worth remembering.
    func captureIfSettled() {
        guard !isRestoring else { return }
        captureOpenWindows()
    }

    /// What is open, read off the windows themselves.
    ///
    /// A scan with no window is not a tab anybody can see — it is a model whose
    /// window has gone and whose scan is still finishing — and a window with no
    /// target has nothing worth reopening.
    ///
    /// Nil, not empty, when there is no application to ask: the CLI runs this
    /// code with no `NSApp` at all, and "I cannot see any windows" must not be
    /// written down as "no windows were open".
    static func openTabs() -> [SessionState.OpenTab]? {
        guard let app = NSApp else { return nil }
        var groups: [ObjectIdentifier: Int] = [:]
        var tabs: [SessionState.OpenTab] = []
        // In window order rather than model order, so the tab bar's arrangement
        // is what gets written down.
        for window in app.windows where window.isVisible {
            // `isVisible` decides the awkward case: closing the last window is
            // itself a way to quit, and the window is on its way out while this
            // runs. Without it, whether that tab came back would depend on how
            // far AppKit had got.
            guard let model = LiveTabs.models.first(where: { $0.window === window }),
                  let target = model.scannedURL ?? model.queuedTarget else { continue }
            var group: Int?
            if let tabGroup = window.tabGroup {
                let key = ObjectIdentifier(tabGroup)
                if let existing = groups[key] {
                    group = existing
                } else {
                    group = groups.count
                    groups[key] = group
                }
            }
            tabs.append(SessionState.OpenTab(group: group, target: target.path))
        }
        return tabs
    }

    func captureOpenWindows() {
        guard let tabs = Self.openTabs() else { return }
        capture(tabs)
    }
}
