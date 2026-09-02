import CoreGraphics
import Foundation

/// Terminal entry points, mostly for verifying the scanner without the UI:
///   Reclaim --volumes          list mounted volumes
///   Reclaim --scan <path>      scan and print the breakdown
enum CLI {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        if arguments.contains("--volumes") {
            listVolumes()
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--bench-nav"), index + 1 < arguments.count {
            if arguments.contains("--long") { navigationPasses = 400 }
            benchmarkNavigation(URL(fileURLWithPath: arguments[index + 1]))
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--bench-draw"), index + 1 < arguments.count {
            benchmarkDraw(URL(fileURLWithPath: arguments[index + 1]))
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--bench-loop"), index + 1 < arguments.count {
            benchmarkLoop(URL(fileURLWithPath: arguments[index + 1]))
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--bench"), index + 1 < arguments.count {
            benchmark(URL(fileURLWithPath: arguments[index + 1]))
            exit(0)
        }
        guard let index = arguments.firstIndex(of: "--scan"), index + 1 < arguments.count else { return }
        scan(URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL)
        exit(0)
    }

    private static func listVolumes() {
        for volume in VolumeScanner.mounted() {
            print(pad(volume.name, 24)
                  + pad(volume.kindDescription, 16)
                  + "\(ByteFormat.string(volume.used)) used of \(ByteFormat.string(volume.capacity)) "
                  + "· \(ByteFormat.string(volume.available)) free · \(volume.url.path)")
        }
    }

    private static func scan(_ url: URL) {
        let session = ScanSession()
        let started = Date()
        guard let root = Scanner.scan(url: url, options: ScanOptions(), session: session) else {
            FileHandle.standardError.write(Data("cannot scan \(url.path)\n".utf8))
            exit(1)
        }
        print("root       \(root.path)")
        print("physical   \(root.physicalSize) (\(ByteFormat.string(root.physicalSize)))")
        print("logical    \(root.logicalSize) (\(ByteFormat.string(root.logicalSize)))")
        print("files      \(root.fileCount)  unreadable dirs \(root.unreadableCount)")
        print(String(format: "elapsed    %.2fs", Date().timeIntervalSince(started)))

        let breakdown = Breakdown.of(root, measure: .physical)
        print("\ncontents, largest first")
        for row in breakdown.rows.prefix(15) {
            let bar = String(repeating: "▉", count: max(1, Int(row.share * 24)))
            print("  " + pad(ByteFormat.string(row.bytes), 10)
                  + String(format: "%5.1f%%  ", row.share * 100)
                  + pad(bar, 26) + row.name)
        }
        print("\nby file type")
        for total in breakdown.types {
            print("  " + pad(total.family.label, 10)
                  + pad(ByteFormat.string(total.bytes), 10)
                  + "\(total.files) files")
        }
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }
}

extension CLI {
    /// `Reclaim --bench <path>` times the treemap layout at several detail
    /// thresholds, which is how the live-resize budget was chosen.
    static func benchmark(_ url: URL) {
        let session = ScanSession()
        guard let root = Scanner.scan(url: url, options: ScanOptions(), session: session) else { return }
        print("scanned \(root.fileCount) files\n")
        let box = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for minimumArea in [16.0, 64.0, 256.0, 1024.0, 4096.0] as [CGFloat] {
            var cells = 0
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 3 {
                let started = DispatchTime.now().uptimeNanoseconds
                let layout = TreemapLayout.build(root: root, in: box, measure: .physical,
                                                 minimumArea: minimumArea)
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
                cells = layout.cells.count
            }
            print(String(format: "minArea %7.0f  %6.1f ms  %d cells", minimumArea, best, cells))
        }
    }
}

extension CLI {
    /// `Reclaim --bench-loop <path>` lays out repeatedly so a sampling profiler
    /// has something to attach to.
    static func benchmarkLoop(_ url: URL) {
        let session = ScanSession()
        guard let root = Scanner.scan(url: url, options: ScanOptions(), session: session) else { return }
        let box = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let deadline = Date().addingTimeInterval(12)
        var passes = 0
        while Date() < deadline {
            _ = TreemapLayout.build(root: root, in: box, measure: .physical, minimumArea: 16)
            passes += 1
        }
        print("passes \(passes)")
    }
}

extension CLI {
    /// `Reclaim --bench-draw <path>` times a full map render off-screen.
    static func benchmarkDraw(_ url: URL) {
        let session = ScanSession()
        guard let root = Scanner.scan(url: url, options: ScanOptions(), session: session) else { return }
        let box = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for minimumArea in [16.0, 64.0, 256.0] as [CGFloat] {
            let layout = TreemapLayout.build(root: root, in: box, measure: .physical,
                                             minimumArea: minimumArea)
            guard let context = CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            var best = Double.greatestFiniteMagnitude
            for _ in 0 ..< 3 {
                let started = DispatchTime.now().uptimeNanoseconds
                TreemapRenderer.draw(layout: layout, in: context, dirty: box,
                                     measure: .physical, staged: [])
                best = min(best, Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
            }
            print(String(format: "minArea %6.0f  draw %6.1f ms  %d cells",
                         minimumArea, best, layout.cells.count))
        }
    }
}

extension CLI {
    /// `Reclaim --bench-nav <path>` walks in and back out of the largest folders
    /// the way scrolling does, timing exactly the work a navigation step costs:
    /// the map layout plus the sidebar breakdown.
    static var navigationPasses = 5

    static func benchmarkNavigation(_ url: URL) {
        let session = ScanSession()
        guard let root = Scanner.scan(url: url, options: ScanOptions(), session: session) else { return }
        let box = CGRect(x: 0, y: 0, width: 1200, height: 800)

        // The app warms the per-family roll-ups on the scan thread; do the same
        // here so the numbers describe what a user actually experiences.
        let warmStarted = DispatchTime.now().uptimeNanoseconds
        root.warmTotals()
        print(String(format: "warm totals %6.1f ms",
                     Double(DispatchTime.now().uptimeNanoseconds - warmStarted) / 1e6))

        var path: [FileItem] = [root]
        var timings: [Double] = []
        var deepest = 0

        func step(to node: FileItem) {
            let started = DispatchTime.now().uptimeNanoseconds
            _ = TreemapLayout.build(root: node, in: box, measure: .physical,
                                    minimumArea: 16, maximumDepth: 1)
            _ = Breakdown.of(node, measure: .physical)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        }

        // Down to the deepest large folder, then back up.
        for _ in 0 ..< navigationPasses {
            while let current = path.last,
                  let next = current.children.first(where: { $0.isDirectory && !$0.children.isEmpty }),
                  path.count < 12 {
                path.append(next)
                step(to: next)
            }
            deepest = max(deepest, path.count)
            while path.count > 1 {
                path.removeLast()
                step(to: path[path.count - 1])
            }
        }

        let sorted = timings.sorted()
        let worst = sorted.last ?? 0
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let mean = timings.isEmpty ? 0 : timings.reduce(0, +) / Double(timings.count)
        print(String(format: "%d navigation steps, depth %d", timings.count, deepest))
        print(String(format: "median %6.2f ms   mean %6.2f ms   worst %6.2f ms", median, mean, worst))
        print(String(format: "steps over 16ms (a dropped frame): %d",
                     timings.filter { $0 > 16 }.count))
    }
}
