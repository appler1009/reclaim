import Foundation

/// A throwaway directory tree on disk, so scanner tests exercise the real
/// syscalls rather than a mock filesystem.
struct Fixture {
    let root: URL

    init(_ name: String = UUID().uuidString) throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclaim-tests")
            .appendingPathComponent(name)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes `bytes` of content; file sizes on APFS round up to 4 KB blocks,
    /// which is exactly what the physical-size measurement should report.
    @discardableResult
    func file(_ path: String, bytes: Int) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    func hardLink(_ path: String, to existing: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: existing, to: url)
        return url
    }

    func chmod(_ path: String, _ mode: Int) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// `du -sk`-equivalent, used to check totals against the system's own answer.
    func duBytes(_ path: String? = nil) -> UInt64 {
        let target = path.map { root.appendingPathComponent($0).path } ?? root.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", target]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let kilobytes = UInt64(output.split(separator: "\t").first.map(String.init) ?? "") ?? 0
        return kilobytes * 1024
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
