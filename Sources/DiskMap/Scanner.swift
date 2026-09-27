import Foundation
import ReclaimKit

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
    /// Files smaller than this, in a folder that is keeping a tree, become one
    /// "N small files" entry. Nil keeps every file, which is what tests and the
    /// command-line scan want.
    var smallFileLimit: UInt64?
    /// Directory names whose children are not kept. The folder's totals are,
    /// and opening it reads the children from disk. `node_modules` and `.git`
    /// are the ones an interactive scan names.
    var foldNames: Set<String> = []
    /// What a window scans: small files and the two directory names that are
    /// mostly files nobody opens from the map.
    static var interactive: ScanOptions {
        var options = ScanOptions()
        options.smallFileLimit = 64 * 1024
        options.foldNames = ["node_modules", ".git"]
        return options
    }
    /// Directory readers running in parallel.
    ///
    /// One per core, and never fewer than eight. This used to be four per core,
    /// on the theory that scanning is I/O-bound and oversubscribing hides the
    /// latency. On a warm cache it is not I/O-bound at all — it is syscall-bound
    /// — and 40 threads on 10 cores spent their time descheduling each other: a
    /// `~/Library` scan ran 2.3s with 10 workers and 6.1s with 40, for the same
    /// work.
    ///
    /// The floor of eight is deliberate, and is oversubscription on a machine
    /// with fewer cores than that. Contention is what makes a large thread count
    /// expensive, and a small machine has little; too few readers, meanwhile,
    /// leaves the disk waiting, which is measurable even here — four workers ran
    /// the same scan in 3.2s against 2.3s for ten. All of this was measured on a
    /// 10-core machine, so the floor is a hedge for hardware that was not
    /// available to test, not a second measured optimum.
    var workers = max(8, ProcessInfo.processInfo.activeProcessorCount)
}

/// Thread-safe cancellation + progress accounting shared by the scan workers.
final class ScanSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var files = 0
    private var bytes: UInt64 = 0
    private var current = ""
    private var lastReport = DispatchTime.now()
    /// Bytes found so far under each top-level child of the scan root.
    ///
    /// This is what lets the map draw a scan while it is still running: the
    /// tiles are the root's children, and these are their sizes so far.
    private var branchBytes: [UInt64] = []
    private var branchFiles: [Int] = []
    /// How many top-level directories the scan has finished, out of how many.
    /// Byte counts cannot give a fraction — nothing knows the total until the
    /// walk is over — but "34 of 76 folders" is both true and steady.
    private var branchesToComplete = 0
    private var branchesCompleted = 0

    var onProgress: ((ScanProgress) -> Void)?
    /// Over `ScanBudget`, cancel instead of finishing. Set on walks that have
    /// no window waiting for a tree.
    var stopsWhenLarge = false
    /// Over `ScanBudget`, stop keeping individual small files. Set on a window's
    /// scan, which still has to come back with something to draw.
    var foldsWhenLarge = false
    private var foldAllFiles = false
    private var budgetChecks = 0
    /// Footprint when this walk first checked, so later checks measure growth.
    private var footprintAtStart: UInt64?

    /// Whether later files in this scan should be folded even when they are
    /// large. Set from the budget check, read by the directory workers.
    var shouldFoldAll: Bool {
        lock.lock()
        defer { lock.unlock() }
        return foldAllFiles
    }

    /// Samples the footprint every few directories. Cheap next to `lstat`, and
    /// rare enough that a normal scan never notices it.
    func considerBudget() {
        lock.lock()
        budgetChecks += 1
        let due = budgetChecks % 64 == 0
        let stop = stopsWhenLarge
        let fold = foldsWhenLarge
        let baseline = footprintAtStart
        lock.unlock()
        guard due else { return }
        let footprint = ProcessMemory.physFootprint
        guard let baseline else {
            lock.lock()
            if footprintAtStart == nil { footprintAtStart = footprint }
            lock.unlock()
            return
        }
        guard ScanBudget.grew(from: baseline, to: footprint) else { return }
        lock.lock()
        if stop { cancelled = true }
        if fold, !foldAllFiles {
            foldAllFiles = true
            lock.unlock()
            Log.info("scan folding", ["reason": "memory"])
            return
        }
        lock.unlock()
    }

    func prepareBranches(_ count: Int) {
        lock.lock()
        branchBytes = [UInt64](repeating: 0, count: count)
        branchFiles = [Int](repeating: 0, count: count)
        lock.unlock()
    }

    func setBranchesToComplete(_ count: Int) {
        lock.lock(); branchesToComplete = count; lock.unlock()
    }

    func markBranchComplete() {
        lock.lock(); branchesCompleted += 1; lock.unlock()
    }

    /// Directories finished, total to finish, and the fraction between them.
    func completion() -> (done: Int, total: Int, fraction: Double) {
        lock.lock(); defer { lock.unlock() }
        guard branchesToComplete > 0 else { return (0, 0, 0) }
        return (branchesCompleted, branchesToComplete,
                Double(branchesCompleted) / Double(branchesToComplete))
    }

    /// Bytes and file counts per top-level branch, in the order prepared.
    func branchTotals() -> (bytes: [UInt64], files: [Int]) {
        lock.lock(); defer { lock.unlock() }
        return (branchBytes, branchFiles)
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func note(files delta: Int, bytes deltaBytes: UInt64, path: String, branch: Int = -1) {
        lock.lock()
        files += delta
        bytes += deltaBytes
        if branch >= 0, branch < branchBytes.count {
            branchBytes[branch] += deltaBytes
            branchFiles[branch] += delta
        }
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
    struct Job {
        let node: FileItem
        let path: String
        /// Index of the top-level child this job sits under, or -1 for the root.
        let branch: Int
    }

    private let lock = NSCondition()
    private var stack: [Job] = []
    private var busy = 0
    private var finished = false
    /// Outstanding jobs per top-level branch, so a branch can be called done.
    private var pending: [Int: Int] = [:]
    var onBranchFinished: ((Int) -> Void)?

    func push(_ jobs: [Job]) {
        guard !jobs.isEmpty else { return }
        lock.lock()
        for job in jobs where job.branch >= 0 {
            pending[job.branch, default: 0] += 1
        }
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

    func complete(branch: Int = -1) {
        lock.lock()
        busy -= 1
        var branchFinished = false
        if branch >= 0, let outstanding = pending[branch] {
            let left = outstanding - 1
            pending[branch] = left
            branchFinished = left == 0
        }
        if busy == 0 && stack.isEmpty {
            finished = true
            lock.broadcast()
        }
        lock.unlock()
        if branchFinished { onBranchFinished?(branch) }
    }

    func abort() {
        lock.lock(); finished = true; lock.broadcast(); lock.unlock()
    }
}

enum Scanner {
    /// Builds the tree for `url`. Structure is discovered by a pool of worker
    /// threads; sizes are summed afterwards in a single post-order pass, which
    /// keeps the parallel phase lock-free per directory.
    ///
    /// `onTopLevel` receives a standalone copy of the root and its immediate
    /// children as soon as they are known — within milliseconds — so the app can
    /// draw the scan while it runs. The copy is deliberately not part of the tree
    /// the workers are building: they go on mutating that from several threads,
    /// and the UI must have something it can read safely. Each copied child's
    /// index is its branch number, and `ScanSession.branchTotals()` reports the
    /// bytes found under each so far.
    static func scan(url: URL,
                     options: ScanOptions,
                     session: ScanSession,
                     onTopLevel: ((FileItem) -> Void)? = nil) -> FileItem? {
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
        let skip = Firmlinks.duplicates(underScanRoot: path)
        let links = LinkLedger(enabled: options.countHardLinksOnce)
        // Read the first level up front, so the caller has something to show and
        // the branch numbering is fixed before any worker starts.
        let topLevel = read(job: .init(node: root, path: path, branch: -1),
                            rootDev: st.st_dev,
                            skip: skip,
                            options: options,
                            session: session,
                            links: links,
                            assignBranches: true)
        session.prepareBranches(root.children.count)
        if let onTopLevel {
            onTopLevel(copyTopLevel(of: root))
        }

        let queue = DirectoryQueue()
        queue.onBranchFinished = { _ in session.markBranchComplete() }
        session.setBranchesToComplete(topLevel.count)
        queue.push(topLevel)

        let group = DispatchGroup()
        for _ in 0 ..< options.workers {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                while let job = queue.take() {
                    if session.isCancelled {
                        queue.abort()
                        queue.complete(branch: job.branch)
                        return
                    }
                    let subdirectories = read(job: job,
                                              rootDev: st.st_dev,
                                              skip: skip,
                                              options: options,
                                              session: session,
                                              links: links)
                    queue.push(subdirectories)
                    queue.complete(branch: job.branch)
                }
            }
        }
        group.wait()
        if session.isCancelled { return nil }

        aggregate(root: root)
        return root
    }

    /// Reads one directory, attaching its children, and returns the
    /// subdirectories that still need visiting.
    private static func read(job: DirectoryQueue.Job,
                             rootDev: dev_t,
                             skip: Set<String>,
                             options: ScanOptions,
                             session: ScanSession,
                             links: LinkLedger,
                             assignBranches: Bool = false) -> [DirectoryQueue.Job] {
        session.considerBudget()
        guard let dir = opendir(job.path) else {
            job.node.unreadableCount = 1
            return []
        }
        defer { closedir(dir) }

        var subdirectories: [DirectoryQueue.Job] = []
        var children: [FileItem] = []
        var localFiles = 0
        var localBytes: UInt64 = 0
        var smallLogical: UInt64 = 0
        var smallPhysical: UInt64 = 0
        var smallCount = 0
        var smallFamilies = FamilyTotals()
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
                if skip.contains(fullPath) { continue }
                if options.foldNames.contains(name) {
                    guard let summary = summarize(url: URL(fileURLWithPath: fullPath),
                                                  options: options,
                                                  session: session,
                                                  rootDev: rootDev,
                                                  links: links) else { continue }
                    let node = FileItem(name: name,
                                        isDirectory: true,
                                        logicalSize: summary.logicalSize,
                                        physicalSize: summary.physicalSize,
                                        modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                                        fileCount: summary.fileCount)
                    node.unreadableCount = summary.unreadableCount
                    node.adopt(summary.families)
                    node.isFolded = true
                    node.parent = job.node
                    children.append(node)
                    localFiles += summary.fileCount
                    localBytes += summary.physicalSize
                    continue
                }
                let node = FileItem(name: name,
                                    isDirectory: true,
                                    modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
                                    fileCount: 0)
                node.parent = job.node
                children.append(node)
                // A root child starts its own branch, numbered by its position
                // among the root's children; anything deeper inherits it.
                let branch = assignBranches ? children.count - 1 : job.branch
                subdirectories.append(.init(node: node, path: fullPath, branch: branch))
            } else {
                // Symlinks and special files are counted at their own size, never followed.
                let measured = sizes(of: st)
                if mode == S_IFREG, st.st_nlink > 1, !links.count(key(for: st)) {
                    // Already counted through another link.
                    continue
                }
                let fold = session.shouldFoldAll
                    || options.smallFileLimit.map { measured.physical < $0 } == true
                if fold {
                    smallLogical += measured.logical
                    smallPhysical += measured.physical
                    smallCount += 1
                    smallFamilies.add(FamilyTotals(family: family(ofName: name),
                                                   physical: measured.physical,
                                                   logical: measured.logical))
                    localFiles += 1
                    localBytes += measured.physical
                    continue
                }
                let node = leaf(name: name, st: st)
                node.parent = job.node
                children.append(node)
                localFiles += 1
                localBytes += node.physicalSize
            }
        }

        if smallCount > 0 {
            let bundle = FileItem(name: smallCount == 1 ? "1 small file" : "\(smallCount) small files",
                                  isDirectory: false,
                                  logicalSize: smallLogical,
                                  physicalSize: smallPhysical,
                                  fileCount: smallCount)
            bundle.representsSmallFiles = true
            bundle.adopt(smallFamilies)
            bundle.parent = job.node
            children.append(bundle)
        }

        // Only this worker touches `job.node.children`, so no lock is needed.
        job.node.children = children
        session.note(files: localFiles, bytes: localBytes, path: job.path, branch: job.branch)
        return subdirectories
    }

    /// A detached copy of the root and its immediate children: names and sizes
    /// only, with no grandchildren, so nothing the workers touch is shared.
    private static func copyTopLevel(of root: FileItem) -> FileItem {
        let children = root.children.map { child in
            let copy = FileItem(name: child.name,
                                isDirectory: child.isDirectory,
                                logicalSize: child.logicalSize,
                                physicalSize: child.physicalSize,
                                modified: child.modified,
                                fileCount: child.isDirectory ? child.fileCount : child.fileCount)
            copy.isFolded = child.isFolded
            copy.representsSmallFiles = child.representsSmallFiles
            if let totals = child.carriedTotals() { copy.adopt(totals) }
            return copy
        }
        let copy = FileItem(name: root.name,
                            isDirectory: true,
                            modified: root.modified,
                            fileCount: 0,
                            children: children)
        copy.physicalSize = children.reduce(0) { $0 + $1.physicalSize }
        copy.logicalSize = children.reduce(0) { $0 + $1.logicalSize }
        return copy
    }

    /// Iterative post-order sum of sizes, file counts and unreadable directories.
    private static func aggregate(root: FileItem) {
        var stack: [(node: FileItem, visited: Bool)] = [(root, false)]

        while let frame = stack.popLast() {
            let node = frame.node
            if !node.isDirectory || node.isFolded { continue }
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
        let measured = sizes(of: st)
        return FileItem(name: name,
                        isDirectory: false,
                        logicalSize: measured.logical,
                        physicalSize: measured.physical,
                        modified: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
    }

    private static func sizes(of st: stat) -> (logical: UInt64, physical: UInt64) {
        (UInt64(max(0, st.st_size)), UInt64(max(0, st.st_blocks)) * 512)
    }

    private static func key(for st: stat) -> UInt64 {
        UInt64(bitPattern: Int64(st.st_dev)) &* 1_000_003 &+ UInt64(st.st_ino)
    }

    private static func family(ofName name: String) -> FileFamily {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return FileFamily.of(extension: "")
        }
        return FileFamily.of(extension: String(name[name.index(after: dot)...]).lowercased())
    }

    /// Totals and a snapshot's worth of entries, without a node per file.
    ///
    /// The watchlist, `scan_now` and a folded directory only need the numbers.
    /// Memory follows how deep the walk is and how many entries the snapshot
    /// keeps, which is capped, rather than how many files the folder holds.
    static func summarize(url: URL,
                          options: ScanOptions,
                          session: ScanSession,
                          rootDev givenRoot: dev_t? = nil,
                          links sharedLinks: LinkLedger? = nil) -> ScanSummary? {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            let measured = sizes(of: st)
            return ScanSummary(logicalSize: measured.logical,
                               physicalSize: measured.physical,
                               fileCount: 1,
                               unreadableCount: 0,
                               topLevelCount: 1,
                               entries: [])
        }

        let rootDev = givenRoot ?? st.st_dev
        let skip = Firmlinks.duplicates(underScanRoot: path)
        let links = sharedLinks ?? LinkLedger(enabled: options.countHardLinksOnce)
        let collector = RankedEntries()
        guard let acc = walk(path: path, depth: 0, rootDev: rootDev, skip: skip,
                             options: options, session: session, links: links,
                             collector: collector) else { return nil }
        var summary = ScanSummary()
        summary.logicalSize = acc.logical
        summary.physicalSize = acc.physical
        summary.fileCount = acc.files
        summary.unreadableCount = acc.unreadable
        summary.topLevelCount = acc.top
        summary.entries = collector.finish(total: acc.physical)
        summary.families = acc.families
        return summary
    }

    private static func walk(path: String,
                             depth: Int,
                             rootDev: dev_t,
                             skip: Set<String>,
                             options: ScanOptions,
                             session: ScanSession,
                             links: LinkLedger,
                             collector: RankedEntries) -> SummaryAcc? {
        if session.isCancelled { return nil }
        session.considerBudget()
        if session.isCancelled { return nil }
        guard let dir = opendir(path) else { return SummaryAcc(unreadable: 1) }
        defer { closedir(dir) }

        var acc = SummaryAcc()
        let prefix = path == "/" ? "" : (path.hasSuffix("/") ? String(path.dropLast()) : path)

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

            let fullPath = prefix.isEmpty ? "/" + name : prefix + "/" + name
            var st = stat()
            guard lstat(fullPath, &st) == 0 else { continue }
            let mode = st.st_mode & S_IFMT

            if mode == S_IFDIR {
                if options.stayOnVolume && st.st_dev != rootDev { continue }
                if skip.contains(fullPath) { continue }
                if depth == 0 { acc.top += 1 }
                guard let child = walk(path: fullPath, depth: depth + 1, rootDev: rootDev,
                                       skip: skip, options: options, session: session,
                                       links: links, collector: collector) else { return nil }
                acc.logical += child.logical
                acc.physical += child.physical
                acc.files += child.files
                acc.unreadable += child.unreadable
                acc.families.add(child.families)
                collector.add(path: fullPath, bytes: child.physical, isDirectory: true, depth: depth)
            } else {
                if depth == 0 { acc.top += 1 }
                let measured = sizes(of: st)
                var logical = measured.logical
                var physical = measured.physical
                var files = 1
                if mode == S_IFREG, st.st_nlink > 1, !links.count(key(for: st)) {
                    logical = 0
                    physical = 0
                    files = 0
                }
                acc.logical += logical
                acc.physical += physical
                acc.files += files
                if files > 0 {
                    acc.families.add(FamilyTotals(family: family(ofName: name),
                                                  physical: physical,
                                                  logical: logical))
                }
                collector.add(path: fullPath, bytes: physical, isDirectory: false, depth: depth)
            }
        }
        return acc
    }
}

/// What `Scanner.summarize` keeps. Entries are already filtered the way a
/// snapshot filters a tree: three levels always, and below that only what is
/// large against the whole.
struct ScanSummary {
    var logicalSize: UInt64 = 0
    var physicalSize: UInt64 = 0
    var fileCount: Int = 0
    var unreadableCount: Int = 0
    /// Immediate children of the root, which is what the Trash figure counts.
    var topLevelCount: Int = 0
    var entries: [Snapshot.Entry] = []
    var families = FamilyTotals()
}

private struct SummaryAcc {
    var logical: UInt64 = 0
    var physical: UInt64 = 0
    var files: Int = 0
    var unreadable: Int = 0
    var top: Int = 0
    var families = FamilyTotals()

    init() {}
    init(unreadable: Int) { self.unreadable = unreadable }
}

/// Snapshot candidates kept while a summary walk runs.
///
/// Shallow entries are capped by sorting when they overflow. Deep entries sit
/// in a min-heap so replacing the smallest is logarithmic: a linear scan of
/// the full list, once per file, was the expensive part of a large fold.
final class RankedEntries {
    private struct Candidate {
        var entry: Snapshot.Entry
    }

    private struct MinHeap {
        private var items: [Candidate] = []
        var count: Int { items.count }
        var minimumBytes: UInt64 { items[0].entry.bytes }
        var entries: [Snapshot.Entry] { items.map(\.entry) }

        mutating func insert(_ item: Candidate) {
            items.append(item)
            siftUp(items.count - 1)
        }

        mutating func replaceMinimum(with item: Candidate) {
            items[0] = item
            siftDown(0)
        }

        private mutating func siftUp(_ start: Int) {
            var index = start
            while index > 0 {
                let parent = (index - 1) / 2
                if items[parent].entry.bytes <= items[index].entry.bytes { break }
                items.swapAt(parent, index)
                index = parent
            }
        }

        private mutating func siftDown(_ start: Int) {
            var index = start
            while true {
                let left = index * 2 + 1
                let right = left + 1
                var smallest = index
                if left < items.count, items[left].entry.bytes < items[smallest].entry.bytes {
                    smallest = left
                }
                if right < items.count, items[right].entry.bytes < items[smallest].entry.bytes {
                    smallest = right
                }
                if smallest == index { return }
                items.swapAt(index, smallest)
                index = smallest
            }
        }
    }

    private var shallow: [Candidate] = []
    private var deep = MinHeap()
    private let deepLimit: Int

    init(deepLimit: Int = 8_000) {
        self.deepLimit = deepLimit
    }

    func add(path: String, bytes: UInt64, isDirectory: Bool, depth: Int) {
        guard bytes > 0 else { return }
        let candidate = Candidate(entry: Snapshot.Entry(path: path, bytes: bytes, isDirectory: isDirectory))
        if depth < Snapshot.alwaysKeepDepth {
            shallow.append(candidate)
            if shallow.count > 16_000 {
                shallow.sort { $0.entry.bytes > $1.entry.bytes }
                shallow.removeLast(shallow.count - 8_000)
            }
            return
        }
        if deep.count < deepLimit {
            deep.insert(candidate)
        } else if bytes > deep.minimumBytes {
            deep.replaceMinimum(with: candidate)
        }
    }

    func finish(total: UInt64) -> [Snapshot.Entry] {
        let threshold = UInt64(Double(total) * Snapshot.significantFraction)
        return shallow.map(\.entry) + deep.entries.filter { $0.bytes >= threshold }
    }
}

/// Hard-link keys seen so far in one walk. The first link keeps its size.
final class LinkLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<UInt64>()
    private let enabled: Bool

    init(enabled: Bool) { self.enabled = enabled }

    /// True when this key should be counted. A disabled ledger counts everything.
    func count(_ key: UInt64) -> Bool {
        guard enabled else { return true }
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(key).inserted
    }
}

/// The System and Data volumes are joined by firmlinks: `/Users` and
/// `/System/Volumes/Data/Users` are the same directory, with the same device
/// and inode, so neither `stayOnVolume` nor hard-link counting notices. A scan
/// of `/` would walk the whole Data volume twice.
///
/// The firmlinked side is the one people recognise, so it is kept and the copy
/// under the Data mount is skipped. Whatever lives only on the Data side
/// (Spotlight's index, `MobileSoftwareUpdate`) is still counted there.
enum Firmlinks {
    static let dataMount = "/System/Volumes/Data"
    static let table = "/usr/share/firmlinks"

    /// Paths under the Data mount that repeat a firmlinked directory, for a scan
    /// rooted at `scanRoot`. Empty unless the scan would walk into the Data mount
    /// from above — scanning the Data volume itself reaches each directory once.
    static func duplicates(underScanRoot scanRoot: String, table: String = table) -> Set<String> {
        let rootPrefix = scanRoot.hasSuffix("/") ? scanRoot : scanRoot + "/"
        guard dataMount.hasPrefix(rootPrefix),
              let contents = try? String(contentsOfFile: table, encoding: .utf8) else { return [] }

        var paths = Set<String>()
        for line in contents.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 2 else { continue }
            let linked = String(fields[0])
            let duplicate = dataMount + "/" + fields[1]
            // Only skip what really is the same directory, so a stale or odd
            // table can never hide data.
            var a = stat(), b = stat()
            guard stat(linked, &a) == 0, lstat(duplicate, &b) == 0,
                  a.st_dev == b.st_dev, a.st_ino == b.st_ino else { continue }
            paths.insert(duplicate)
        }
        return paths
    }
}
