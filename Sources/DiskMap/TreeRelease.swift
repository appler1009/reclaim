import Darwin
import Foundation

/// Drops a tree off the main thread, then asks the allocator to return the pages.
///
/// Freeing a few million small objects on the main thread is a hitch, and the
/// allocator keeps the pages for the next small allocation unless it is told
/// the process is done with them. The caller has already cleared every
/// reference it still needs; this holds the last one until a background queue
/// can let go.
enum TreeRelease {
    static func later(_ node: FileItem?) {
        guard let node else { return }
        DispatchQueue.global(qos: .utility).async {
            withExtendedLifetime(node) {}
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}
