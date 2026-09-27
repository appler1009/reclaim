import Foundation

/// Why a path was turned away. Open, the watchlist and `scan_now` all ask
/// before they start a walk.
struct ScanRefusal: Equatable {
    /// What to show a person.
    let message: String
    /// What to write in a log line.
    let code: String
}

/// Network volumes and Time Machine backups are not scanned unless a caller
/// has already decided otherwise. A scan of `/` stays on one disk by its own
/// rule; this is the door for paths that are a different disk entirely.
enum ScanPaths {
    static func refusal(of url: URL, volumeIsLocal probe: ((URL) -> Bool?)? = nil) -> ScanRefusal? {
        let path = TargetPath.normalise(url).path
        if isTimeMachine(path) {
            return ScanRefusal(message: "Time Machine backups aren't scanned.",
                               code: "timeMachine")
        }
        let local = probe?(url) ?? Self.volumeIsLocal(url)
        if local == false {
            return ScanRefusal(message: "Network volumes aren't scanned.",
                               code: "network")
        }
        return nil
    }

    private static func isTimeMachine(_ path: String) -> Bool {
        if path.contains("com.apple.TimeMachine") { return true }
        let parts = path.split(separator: "/")
        return parts.contains("Backups.backupdb") || parts.contains(".MobileBackups")
    }

    private static func volumeIsLocal(_ url: URL) -> Bool? {
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey])
        return values?.volumeIsLocal
    }
}
