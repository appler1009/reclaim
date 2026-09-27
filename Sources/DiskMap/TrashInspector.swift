import AppKit
import Foundation

/// Measures what is sitting in the Trash — space that is spoken for but not yet
/// given back, which is exactly the number to watch after moving things there.
enum TrashInspector {
    struct Contents {
        var bytes: UInt64 = 0
        var items: Int = 0
        var isEmpty: Bool { items == 0 }
    }

    /// Where the Trash lives for a given volume. The startup volume uses the
    /// home folder's `.Trash`; every other volume keeps a per-user directory
    /// under `.Trashes` at its root.
    static func trashURLs(forVolumeAt volume: URL) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if volume.path == "/" {
            return [home.appendingPathComponent(".Trash")]
        }
        return [volume.appendingPathComponent(".Trashes")
                      .appendingPathComponent(String(getuid()))]
    }

    /// Sums the Trash directories for the volume holding `url`.
    ///
    /// Totals only: the Trash is never drawn, so there is no tree to keep.
    /// Waits for whatever walk is already running rather than starting a
    /// second one beside it.
    static func contents(forVolumeContaining url: URL,
                         session: ScanSession = ScanSession()) -> Contents? {
        let volume = volumeRoot(containing: url)
        session.stopsWhenLarge = true
        let permit = ScanGate.shared.acquire(unattended: true) { session.cancel() }
        defer { permit.release() }
        guard !session.isCancelled else { return nil }
        var contents = Contents()
        for trash in trashURLs(forVolumeAt: volume) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: trash.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let summary = Scanner.summarize(url: trash,
                                                  options: ScanOptions(),
                                                  session: session) else {
                if session.isCancelled { return nil }
                continue
            }
            contents.bytes += summary.physicalSize
            contents.items += summary.topLevelCount
            if session.isCancelled { return nil }
        }
        return session.isCancelled ? nil : contents
    }

    /// The mount point of the volume `url` sits on.
    static func volumeRoot(containing url: URL) -> URL {
        if let values = try? url.resourceValues(forKeys: [.volumeURLKey]),
           let volume = values.volume {
            return volume
        }
        return URL(fileURLWithPath: "/")
    }

    /// Opens the Trash in Finder, which is where emptying it belongs.
    static func revealInFinder(forVolumeContaining url: URL) {
        let volume = volumeRoot(containing: url)
        guard let trash = trashURLs(forVolumeAt: volume).first,
              FileManager.default.fileExists(atPath: trash.path) else { return }
        NSWorkspace.shared.open(trash)
    }
}
