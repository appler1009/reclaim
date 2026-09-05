import SwiftUI
import ReclaimKit

@main
struct DiskMapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        CLI.runIfRequested()
        // Before any scene is created, so the model's first logs are not dropped.
        Log.start()
        WindowSizeGuard.discardOversizedSavedFrames()
    }

    var body: some Scene {
        // Untitled on purpose: a fixed scene title becomes the first window's
        // tab label and then never changes.
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1320, height: 860)
        // Without this the greedy content makes SwiftUI open the window at
        // full screen size; the content only dictates the minimum.
        .windowResizability(.contentMinSize)
        // Unified: the app's controls live in the title bar itself, which the
        // window styling below makes translucent.
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            // Kept after .newItem rather than replacing it, so New Window (⌘N)
            // survives: a window is a scan, and opening another is the point.
            CommandGroup(after: .newItem) {
                NewTabCommand()
                Divider()
                ScanCommands()
            }
            CommandGroup(after: .sidebar) {
                NavigationCommands()
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// Opens another scan in a tab of the window in front.
///
/// The tab bar already offers this through its "+", and a window can be torn
/// into its own; the File menu was the one place that only offered a whole new
/// window.
///
/// Asking AppKit for the new window is the easy half. Whether it *joins* the
/// front one is decided by that window's `tabbingMode`, which by default defers
/// to the system's "Prefer tabs when opening documents" — set to "full screen
/// only" on a stock Mac, so the action alone opens a window and leaves it
/// standing beside the one it came from. A menu item called New Tab has to make
/// a tab whatever that setting says, so the window it produces is put into the
/// front window's tab group by hand.
private struct NewTabCommand: View {
    /// Only to know whether a scan window is in front. Read the same way the
    /// other File-menu items read it, so it tracks focus rather than being
    /// decided once when the menu is built.
    @FocusedValue(\.scan) private var model

    var body: some View {
        // The scan's own window, not whatever is key when the item is picked:
        // focus and key window can disagree — Settings in front is the case —
        // and then the tab would join the wrong window, or none. Key window is
        // the fallback for the moment before a new window has reported itself.
        Button("New Tab") { NewTab.open(front: model?.window ?? NSApp.keyWindow) }
            .keyboardShortcut("t", modifiers: .command)
            // Enablement stays on the focused scan rather than on its window:
            // `window` is not a published property — publishing an `NSWindow`
            // from a model that the window itself owns invites a cycle — so a
            // menu built before it was reported would never enable.
            .disabled(model == nil)
    }
}

@MainActor
enum NewTab {
    /// How long to keep asking for the window the action was supposed to make.
    /// A scene is built after `newWindowForTab:` returns, and not always by the
    /// next turn of the run loop, so the window is watched for rather than
    /// assumed to be there.
    static let patience: TimeInterval = 1
    static let pollInterval: TimeInterval = 0.05

    /// Opens a scan window and makes it a tab of `front`.
    ///
    /// Every collaborator is a parameter so the whole sequence — including the
    /// window arriving late — can be exercised without a menu or a scene.
    /// Returns whether it had a window to tab onto at all.
    @discardableResult
    static func open(front: NSWindow?,
                     openWindow: (() -> Void)? = nil,
                     windows: (() -> [NSWindow])? = nil,
                     now: @escaping () -> Date = Date.init,
                     schedule: ((@escaping () -> Void) -> Void)? = nil,
                     then: @escaping (NSWindow?) -> Void = { _ in }) -> Bool {
        guard let front else { return false }
        let windows = windows ?? { NSApp.windows }
        let openWindow = openWindow ?? {
            NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil)
        }
        // Every look is scheduled, the first one included, so a test can drive
        // the whole sequence itself rather than race the clock.
        // Named apart from the parameter it defaults, and typed rather than
        // inferred: left to itself the compiler takes the shape of
        // `asyncAfter`'s argument, which is not the shape a caller passes.
        let scheduleLook: (@escaping () -> Void) -> Void = schedule ?? { work in
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: work)
        }

        let before = Set(windows().map(ObjectIdentifier.init))
        // Asking for a tab rather than a window, and held that way until the
        // window turns up: put back early, AppKit would fall back to the
        // system's "Prefer tabs" setting for a scene that arrives late, which
        // on a stock Mac means a window standing beside this one.
        let mode = front.tabbingMode
        front.tabbingMode = .preferred
        openWindow()

        let deadline = now().addingTimeInterval(patience)
        func settle(_ created: NSWindow?) {
            front.tabbingMode = mode
            then(created)
        }
        func look() {
            // Same tabbing identifier: a window of the same scene, rather than
            // the settings pane or a panel that happened to appear.
            let created = windows().first {
                !before.contains(ObjectIdentifier($0))
                    && $0.tabbingIdentifier == front.tabbingIdentifier
            }
            if let created {
                // Already tabbed where the system prefers tabs; AppKit got
                // there first and there is nothing to join.
                if front.tabGroup?.windows.contains(created) != true {
                    front.addTabbedWindow(created, ordered: .above)
                }
                created.makeKeyAndOrderFront(nil)
                settle(created)
                return
            }
            guard now() < deadline else {
                Log.warning("new tab: no window arrived", ["waited": "\(patience)s"])
                settle(nil)
                return
            }
            scheduleLook { look() }
        }
        scheduleLook { look() }
        return true
    }
}

/// File-menu entries, acting on whichever scan window is in front.
private struct ScanCommands: View {
    @FocusedValue(\.scan) private var model
    /// Observed, not read once: the menu item's wording flips with the list.
    @ObservedObject private var watchlist = Watchlist.shared

    /// The front window's target, when it has one to watch.
    private var target: String? { model?.scannedURL.map { TargetPath.normalise($0).path } }

    var body: some View {
        Group {
            Menu("Scan Volume") {
                ForEach(model?.volumes ?? []) { volume in
                    Button {
                        model?.scan(volume: volume)
                    } label: {
                        Text("\(volume.name) — \(ByteFormat.string(volume.available)) free")
                    }
                }
            }
            .disabled(model == nil)

            Button("Scan Home Folder") {
                model?.scan(FileManager.default.homeDirectoryForCurrentUser)
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(model == nil)

            Button("Scan Folder…") { model?.chooseFolder() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model == nil)

            Divider()

            Button("Rescan") { model?.rescan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model?.scanRoot == nil || model?.isScanning == true)

            Button("Stop Scanning") { model?.cancelScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model?.isScanning != true)

            Button(watchTitle) {
                if let target { watchlist.toggle(target) }
            }
            .disabled(target == nil)

            Divider()

            Button("Reveal in Finder") {
                if let item = model?.selectedItem ?? model?.zoomRoot {
                    model?.revealInFinder(item)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model?.scanRoot == nil)

            Button("Open Trash") { model?.revealTrashInFinder() }
                .disabled((model?.trash.items ?? 0) == 0)
        }
    }
}

private extension ScanCommands {
    /// Says what the item will do, and to what: a menu that reads "Watch
    /// Overnight" with three windows open is asking which one.
    var watchTitle: String {
        guard let target else { return "Watch Overnight" }
        let name = URL(fileURLWithPath: target).lastPathComponent
        let subject = name.isEmpty ? "Startup Disk" : name
        return watchlist.contains(target) ? "Stop Watching \(subject)" : "Watch \(subject) Overnight"
    }
}

/// View-menu entries for moving around the scan in front.
private struct NavigationCommands: View {
    @FocusedValue(\.scan) private var model

    var body: some View {
        Button("Enclosing Folder") { model?.zoomOut() }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(model?.zoomRoot == nil || model?.zoomRoot === model?.scanRoot)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sizeGuard: WindowSizeGuard?
    /// Lets local agents ask what is on the disk. See MCPServer.
    private let mcp = MCPServer()
    /// Rescans the watchlist overnight. Owned by the app rather than a window,
    /// which is the whole point: it runs with nothing open.
    private var watchlist: WatchlistRescan?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Log.debug("app delegate launched")
        do {
            try mcp.start()
        } catch {
            Log.error("could not start mcp server", ["error": error.localizedDescription])
        }
        // Only if the user left it on. This is the one server that leaves the
        // machine, so it never starts on its own.
        CompanionService.shared.startIfEnabled()
        watchlist = WatchlistRescan()
        styleWindows()
        sizeGuard = WindowSizeGuard(defaultSize: NSSize(width: 1320, height: 860))
    }

    /// Translucent title bar blended into the app's own dark chrome.
    private func styleWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for window in NSApp.windows where window.styleMask.contains(.titled) {
                window.titlebarAppearsTransparent = true
                window.backgroundColor = Theme.panel
                window.isMovableByWindowBackground = true
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mcp.stop()
        CompanionService.shared.stop()
    }

    var mcpURL: String { mcp.url }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Keeps app windows at a usable size.
///
/// On a large external display AppKit repeatedly re-fits windows to the screen
/// (`_displayChangedSoAdjustWindows:`, confirmed from a stack trace) — at launch
/// and again whenever the display configuration settles — leaving the UI
/// stretched across 5120x2880. This watches for resizes the user did not ask for
/// and puts the window back, while leaving dragging and fullscreen alone.
///
/// It deliberately observes *every* window rather than one captured instance:
/// the window SwiftUI ends up resizing is not always the one that exists when
/// the app finishes launching.
final class WindowSizeGuard {
    private let defaultSize: NSSize
    private var preferred: [ObjectIdentifier: NSSize] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?

    /// A frame saved while the window was screen-sized is restored *at creation*,
    /// so no resize is ever posted and the guard below never gets a chance. The
    /// stored frame has to go before the scene is built.
    static func discardOversizedSavedFrames() {
        let defaults = UserDefaults.standard
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return }
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix("NSWindow Frame ") {
            // Format: "x y w h screenX screenY screenW screenH".
            guard let string = value as? String else { continue }
            let numbers = string.split(separator: " ").compactMap { Double($0) }
            guard numbers.count >= 4 else { continue }
            let size = CGSize(width: numbers[2], height: numbers[3])
            let oversized = screens.contains { size.width >= $0.width * 0.9 || size.height >= $0.height * 0.9 }
            if oversized {
                defaults.removeObject(forKey: key)
                Log.debug("discarded oversized saved window frame",
                          ["key": key, "size": "\(Int(size.width))x\(Int(size.height))"])
            }
        }
    }

    /// Whether the *user* put the window in fullscreen, as opposed to macOS
    /// restoring it there. Without this distinction a window that ended up
    /// fullscreen once comes back fullscreen forever.
    private static let fullScreenPreferenceKey = "userPrefersFullScreen"
    private let launchGraceEnds = Date().addingTimeInterval(3)

    init(defaultSize: NSSize) {
        self.defaultSize = defaultSize
        // The window can also be *created* oversized, restored from a saved frame,
        // in which case no resize is ever posted — so check it a few times while
        // the scene comes up, not only on notifications.
        // AppKit re-fits the window at moments that do not reliably post a
        // notification we can observe, so poll while the app settles.
        var ticks = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            ticks += 1
            self.checkMainWindow()
            if ticks >= 25 { timer.invalidate() }   // ten seconds
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            // Menus, popovers and panels post resizes too. Reacting to those is
            // what made right-clicking a tile move the window.
            guard let window = note.object as? NSWindow,
                  window.styleMask.contains(.titled), window.contentView != nil else { return }
            self?.check(window)
        })
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.checkMainWindow()
        })
        // Entering fullscreen after launch is a deliberate act; during the launch
        // grace period it is just macOS restoring the previous session.
        observers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self, Date() > self.launchGraceEnds else { return }
            UserDefaults.standard.set(true, forKey: Self.fullScreenPreferenceKey)
        })
        observers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            guard let self, Date() > self.launchGraceEnds else { return }
            UserDefaults.standard.set(false, forKey: Self.fullScreenPreferenceKey)
        })
        observers.append(center.addObserver(forName: NSWindow.didEndLiveResizeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            // An explicit drag is the new intent.
            self?.preferred[ObjectIdentifier(window)] = window.frame.size
        })
    }

    deinit {
        pollTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Any resize anywhere in the app, plus display-configuration changes, are
    /// treated as "check our window" — the notification often comes from another
    /// window (the menu bar's, for one) in the same layout pass that resized ours.
    private func checkMainWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.styleMask.contains(.titled) && $0.contentView != nil
        }) else { return }
        check(window)
    }

    private func check(_ window: NSWindow) {
        if window.styleMask.contains(.fullScreen) {
            // Restored into fullscreen without the user ever asking: leave it.
            if Date() < launchGraceEnds,
               !UserDefaults.standard.bool(forKey: Self.fullScreenPreferenceKey) {
                Log.debug("leaving restored fullscreen")
                window.toggleFullScreen(nil)
            }
            return
        }
        guard !window.inLiveResize else { return }
        // Measured against the screen the window is actually on. Falling back to
        // NSScreen.main was wrong: that follows the key window, so while a menu
        // is open it can name a different display, and a window judged against
        // the wrong screen gets "corrected" for no reason.
        guard let visible = window.screen?.visibleFrame else { return }

        let key = ObjectIdentifier(window)
        let preferredSize = preferred[key] ?? defaultSize
        if let corrected = WindowFit.correction(for: window.frame, in: visible,
                                                preferred: preferredSize) {
            Log.debug("restored self-resized window", [
                "was": "\(Int(window.frame.width))x\(Int(window.frame.height))",
                "to": "\(Int(corrected.width))x\(Int(corrected.height))",
            ])
            window.setFrame(corrected, display: true, animate: false)
        } else if !WindowFit.isOversized(window.frame.size, on: visible) {
            preferred[key] = window.frame.size
        }
    }
}

