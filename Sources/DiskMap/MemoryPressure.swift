import Foundation

/// Whether the system has asked processes to use less memory.
///
/// Unattended scans — nightly, the watchlist, `scan_now` — sit the night out
/// while this is raised. A scan somebody started still runs. The source also
/// drops trees on tabs that are not in front, which is the memory a person is
/// not looking at.
enum MemoryPressure {
    private static let lock = NSLock()
    private static var elevated = false
    private static var override: Bool?
    private static var source: DispatchSourceMemoryPressure?

    static var isElevated: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let override { return override }
        return elevated
    }

    /// Tests pose as a Mac under pressure without needing the real condition.
    static func setOverrideForTesting(_ value: Bool?) {
        lock.lock()
        override = value
        lock.unlock()
    }

    static func start() {
        lock.lock()
        if source != nil {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .all,
                                                             queue: .global(qos: .utility))
        self.source = source
        lock.unlock()
        source.setEventHandler {
            let event = source.data
            let on = event.contains(.warning) || event.contains(.critical)
            lock.lock()
            elevated = on
            lock.unlock()
            if on {
                DispatchQueue.main.async { LiveTabs.dropIdleTrees() }
            }
        }
        source.resume()
    }
}
