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
    /// Reuses the ordinary scanner: the Trash is just another directory tree, and
    /// it is usually small enough that this costs nothing worth optimising.
    static func contents(forVolumeContaining url: URL) -> Contents {
        let volume = volumeRoot(containing: url)
        var contents = Contents()
        for trash in trashURLs(forVolumeAt: volume) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: trash.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let root = Scanner.scan(url: trash,
                                          options: ScanOptions(),
                                          session: ScanSession()) else { continue }
            contents.bytes += root.physicalSize
            contents.items += root.children.count
        }
        return contents
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
