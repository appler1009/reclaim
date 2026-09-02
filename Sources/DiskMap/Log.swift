import Foundation
import LogShip

/// Logging facade over LogShip (see ../logdock). Fire-and-forget: every call
/// returns immediately and failures are swallowed by LogShip itself, so logging
/// can never change how the app behaves.
///
/// No collector URL or token is compiled in. On this machine the collector's own
/// preferences supply the token, so a dev build needs no configuration; an
/// explicit override is available through the environment for anyone else.
enum Log {
    static let source = "reclaim-mac"

    private static let defaultIntakeURL = URL(string: "http://127.0.0.1:8737")!

    static func start() {
        let environment = ProcessInfo.processInfo.environment
        let url = environment["RECLAIM_LOGDOCK_URL"].flatMap(URL.init(string:)) ?? defaultIntakeURL
        guard let token = environment["RECLAIM_LOGDOCK_TOKEN"] ?? collectorToken() else { return }
        Task {
            await LogShip.shared.configure(collectorURL: url, token: token, source: source)
            await LogShip.shared.info("launched", metadata: [
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "cores": "\(ProcessInfo.processInfo.activeProcessorCount)",
            ])
        }
    }

    /// The locally running LogDock keeps its intake token in plain preferences.
    private static func collectorToken() -> String? {
        CFPreferencesCopyAppValue("LogDock.token" as CFString,
                                  "com.logdock.app" as CFString) as? String
    }

    static func debug(_ message: String, _ metadata: [String: String]? = nil) {
        Task { await LogShip.shared.debug(message, metadata: metadata) }
    }

    static func info(_ message: String, _ metadata: [String: String]? = nil) {
        Task { await LogShip.shared.info(message, metadata: metadata) }
    }

    static func warning(_ message: String, _ metadata: [String: String]? = nil) {
        Task { await LogShip.shared.warning(message, metadata: metadata) }
    }

    static func error(_ message: String, _ metadata: [String: String]? = nil) {
        Task { await LogShip.shared.error(message, metadata: metadata) }
    }
}
