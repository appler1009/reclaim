import SwiftUI

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
        WindowGroup("Reclaim") {
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
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                Button("Enclosing Folder") {
                    NotificationCenter.default.post(name: .reclaimNavigateUp, object: nil)
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sizeGuard: WindowSizeGuard?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Log.debug("app delegate launched")
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
                                            object: nil, queue: .main) { [weak self] _ in
            self?.checkMainWindow()
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
        }) else {
            Log.debug("size guard: no titled window yet")
            return
        }
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

        let key = ObjectIdentifier(window)
        if isOversized(window.frame.size, on: window) {
            let target = preferred[key] ?? defaultSize
            Log.debug("restored self-resized window", [
                "was": "\(Int(window.frame.width))x\(Int(window.frame.height))",
                "to": "\(Int(target.width))x\(Int(target.height))",
            ])
            apply(target, to: window)
        } else {
            preferred[key] = window.frame.size
        }
    }

    private func isOversized(_ size: NSSize, on window: NSWindow) -> Bool {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return false }
        return size.width >= visible.width * 0.9 || size.height >= visible.height * 0.9
    }

    private func apply(_ size: NSSize, to window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let clamped = NSSize(width: min(size.width, visible.width * 0.9),
                             height: min(size.height, visible.height * 0.9))
        let origin = NSPoint(x: visible.midX - clamped.width / 2,
                             y: visible.midY - clamped.height / 2)
        window.setFrame(NSRect(origin: origin, size: clamped), display: true, animate: false)
    }
}

extension Notification.Name {
    /// Posted by the ⌘↑ menu command; handled by the map pane.
    static let reclaimNavigateUp = Notification.Name("reclaim.navigateUp")
}
