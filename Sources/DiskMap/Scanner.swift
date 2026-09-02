import Foundation

struct ScanProgress {
    var filesScanned: Int
    var bytesScanned: UInt64
    var currentPath: String
}

struct ScanOptions {
    /// Do not descend into other mounted volumes.
    var stayOnVolume = true
    /// Count a hard-linked file only the first time it is seen.
    var countHardLinksOnce = true
    var includeHidden = true
    /// Directory readers running in parallel. Scanning is dominated by I/O
    /// latency, so oversubscribing the cores is what actually makes it fast.
    var workers = max(8, ProcessInfo.processInfo.activeProcessorCount * 4)
}

/// Thread-safe cancellation + progress accounting shared by the scan workers.
final class ScanSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var files = 0
    private var bytes: UInt64 = 0
    private var current = ""
    private var lastReport = DispatchTime.now()

    var onProgress: ((ScanProgress) -> Void)?

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func note(files delta: Int, bytes deltaBytes: UInt64, path: String) {
        lock.lock()
        files += delta
        bytes += deltaBytes
        current = path
        let now = DispatchTime.now()
        let due = now.uptimeNanoseconds &- lastReport.uptimeNanoseconds > 120_000_000
        if due { lastReport = now }
        let snapshot = ScanProgress(filesScanned: files, bytesScanned: bytes, currentPath: current)
        lock.unlock()
        if due { onProgress?(snapshot) }
    }

    func snapshot() -> ScanProgress {
        lock.lock(); defer { lock.unlock() }
        return ScanProgress(filesScanned: files, bytesScanned: bytes, currentPath: current)
    }
}

/// A LIFO pool of directories waiting to be read. Depth-first order keeps the
/// pending set small even on huge trees.
private final class DirectoryQueue: @unchecked Sendable {
    struct Job { let node: FileItem; let path: String }

    private let lock = NSCondition()
    private var stack: [Job] = []
    private var busy = 0
    private var finished = false

    func push(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        lock.lock()
        stack.append(contentsOf: jobs)
        lock.broadcast()
        lock.unlock()
    }

    /// Blocks until a job is available, or nil when the whole traversal is done.
    func take() -> Job? {
        lock.lock()
        defer { lock.unlock() }
        while true {
            if finished { return nil }
            if let job = stack.popLast() {
                busy += 1
                return job
            }
            if busy == 0 {
                finished = true
                lock.broadcast()
                return nil
            }
            lock.wait()
        }
    }

    func complete() {
        lock.lock()
        busy -= 1
        if busy == 0 && stack.isEmpty {
            finished = true
            lock.broadcast()
        }
        lock.unlock()
    }

    func abort() {
        lock.lock(); finished = true; lock.broadcast(); lock.unlock()
    }
}

enum Scanner {
    /// Builds the tree for `url`. Structure is discovered by a pool of worker
    /// threads; sizes are summed afterwards in a single post-order pass, which
    /// keeps the parallel phase lock-free per directory.
    static func scan(url: URL, options: ScanOptions, session: ScanSession) -> FileItem? {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }

        if (st.st_mode & S_IFMT) != S_IFDIR {
            return leaf(name: path, st: st)
        }

        let root = FileItem(name: path,
                            isDirectory: true,
                            modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                            fileCount: 0)
        let queue = DirectoryQueue()
        queue.push([.init(node: root, path: path)])

        let group = DispatchGroup()
        for _ in 0 ..< options.workers {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                while let job = queue.take() {
                    if session.isCancelled { queue.abort(); queue.complete(); return }
                    let subdirectories = read(job: job,
                                              rootDev: st.st_dev,
                                              options: options,
                                              session: session)
                    queue.push(subdirectories)
                    queue.complete()
                }
            }
        }
        group.wait()
        if session.isCancelled { return nil }

        aggregate(root: root, options: options)
        return root
    }

    /// Reads one directory, attaching its children, and returns the
    /// subdirectories that still need visiting.
    private static func read(job: DirectoryQueue.Job,
                             rootDev: dev_t,
                             options: ScanOptions,
                             session: ScanSession) -> [DirectoryQueue.Job] {
        guard let dir = opendir(job.path) else {
            job.node.unreadableCount = 1
            return []
        }
        defer { closedir(dir) }

        var subdirectories: [DirectoryQueue.Job] = []
        var children: [FileItem] = []
        var localFiles = 0
        var localBytes: UInt64 = 0
        let prefix = job.path == "/" ? "/" : job.path + "/"

        while let raw = readdir(dir) {
            let entry = raw.pointee
            var nameBuffer = entry.d_name
            let name = withUnsafePointer(to: &nameBuffer) { pointer -> String in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            if !options.includeHidden && name.hasPrefix(".") { continue }

            let fullPath = prefix + name
            var st = stat()
            guard lstat(fullPath, &st) == 0 else { continue }
            let mode = st.st_mode & S_IFMT

            if mode == S_IFDIR {
                if options.stayOnVolume && st.st_dev != rootDev { continue }
                let node = FileItem(name: name,
                                    isDirectory: true,
                                    modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                                    fileCount: 0)
                node.parent = job.node
                children.append(node)
                subdirectories.append(.init(node: node, path: fullPath))
            } else {
                // Symlinks and special files are counted at their own size, never followed.
                let node = leaf(name: name, st: st)
                if mode == S_IFREG && st.st_nlink > 1 {
                    node.linkKey = UInt64(bitPattern: Int64(st.st_dev)) &* 1_000_003 &+ UInt64(st.st_ino)
                }
                node.parent = job.node
                children.append(node)
                localFiles += 1
                localBytes += node.physicalSize
            }
        }

        // Only this worker touches `job.node.children`, so no lock is needed.
        job.node.children = children
        session.note(files: localFiles, bytes: localBytes, path: job.path)
        return subdirectories
    }

    /// Iterative post-order sum of sizes, file counts and unreadable directories.
    private static func aggregate(root: FileItem, options: ScanOptions) {
        var seenLinks = Set<UInt64>()
        var stack: [(node: FileItem, visited: Bool)] = [(root, false)]

        while let frame = stack.popLast() {
            let node = frame.node
            if !node.isDirectory {
                if options.countHardLinksOnce, let key = node.linkKey, !seenLinks.insert(key).inserted {
                    // Already counted through another link: keep the node, drop its weight.
                    node.logicalSize = 0
                    node.physicalSize = 0
                    node.fileCount = 0
                }
                continue
            }
            if frame.visited {
                var logical: UInt64 = 0
                var physical: UInt64 = 0
                var files = 0
                var unreadable = node.unreadableCount
                for child in node.children {
                    logical += child.logicalSize
                    physical += child.physicalSize
                    files += child.fileCount
                    if child.isDirectory { unreadable += child.unreadableCount }
                }
                node.logicalSize = logical
                node.physicalSize = physical
                node.fileCount = files
                node.unreadableCount = unreadable
                // Sorted once here so the treemap layout never has to sort:
                // it runs on every resize frame, this runs once per scan.
                node.children.sort { $0.physicalSize > $1.physicalSize }
            } else {
                stack.append((node, true))
                for child in node.children { stack.append((child, false)) }
            }
        }
    }

    private static func leaf(name: String, st: stat) -> FileItem {
        FileItem(name: name,
                 isDirectory: false,
                 logicalSize: UInt64(max(0, st.st_size)),
                 physicalSize: UInt64(max(0, st.st_blocks)) * 512,
                 modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
    }
}
