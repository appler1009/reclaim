import Foundation

/// `Reclaim --scan <path>` runs a scan in the terminal and prints the summary.
/// Handy for verifying totals against `du` without opening the window.
enum CLI {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--scan"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        let session = ScanSession()
        let started = Date()
        guard let root = Scanner.scan(url: url, options: ScanOptions(), session: session) else {
            FileHandle.standardError.write(Data("cannot scan \(url.path)\n".utf8))
            exit(1)
        }
        let elapsed = Date().timeIntervalSince(started)
        print("root       \(root.path)")
        print("physical   \(root.physicalSize) (\(ByteFormat.string(root.physicalSize)))")
        print("logical    \(root.logicalSize) (\(ByteFormat.string(root.logicalSize)))")
        print("files      \(root.fileCount)  unreadable dirs \(root.unreadableCount)")
        print(String(format: "elapsed    %.2fs", elapsed))

        let waste = WasteAnalyzer.analyze(root: root, measure: .physical)
        print("\nreclaimable \(ByteFormat.string(waste.reduce(0) { $0 + $1.bytes }))")
        for group in waste.grouped() {
            print("  \(group.category.rawValue.padding(toLength: 22, withPad: " ", startingAt: 0)) "
                  + "\(ByteFormat.string(group.bytes))  (\(group.items.count))")
            for item in group.items.prefix(3) {
                print("      \(ByteFormat.string(item.bytes))  \(item.path)")
            }
        }
        exit(0)
    }
}
