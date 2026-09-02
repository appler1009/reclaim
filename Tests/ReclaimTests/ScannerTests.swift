import Foundation
import Testing
@testable import DiskMap

@Suite("Scanner")
struct ScannerTests {
    private func scan(_ fixture: Fixture, options: ScanOptions = ScanOptions()) throws -> FileItem {
        let root = Scanner.scan(url: fixture.root, options: options, session: ScanSession())
        return try #require(root)
    }

    @Test func totalsMatchDu() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("a.bin", bytes: 12_000)
        try fixture.file("nested/b.bin", bytes: 40_000)
        try fixture.file("nested/deep/c.bin", bytes: 1_000)

        let root = try scan(fixture)
        #expect(root.physicalSize == fixture.duBytes())
        #expect(root.logicalSize == 53_000)
        #expect(root.fileCount == 3)
        #expect(root.unreadableCount == 0)
    }

    @Test func sumsMatchTheirChildren() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("one/a.bin", bytes: 5_000)
        try fixture.file("one/b.bin", bytes: 7_000)
        try fixture.file("two/c.bin", bytes: 9_000)

        let root = try scan(fixture)
        for node in walk(root) where node.isDirectory {
            let childBytes = node.children.reduce(UInt64(0)) { $0 + $1.physicalSize }
            #expect(node.physicalSize == childBytes, "\(node.name) does not equal its children")
        }
    }

    @Test func childrenArrivePreSortedForTheLayout() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("small.bin", bytes: 1_000)
        try fixture.file("huge.bin", bytes: 90_000)
        try fixture.file("medium.bin", bytes: 30_000)

        let root = try scan(fixture)
        let sizes = root.children.map(\.physicalSize)
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test func hardLinksAreCountedOnce() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try fixture.file("original.bin", bytes: 30_000)
        try fixture.hardLink("copies/link.bin", to: original)

        let deduped = try scan(fixture, options: ScanOptions(countHardLinksOnce: true))
        let counted = try scan(fixture, options: ScanOptions(countHardLinksOnce: false))
        #expect(deduped.physicalSize < counted.physicalSize)
        #expect(counted.physicalSize == deduped.physicalSize * 2)
    }

    @Test func hiddenFilesCanBeExcluded() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("visible.bin", bytes: 8_000)
        try fixture.file(".hidden.bin", bytes: 8_000)

        let withHidden = try scan(fixture, options: ScanOptions(includeHidden: true))
        let withoutHidden = try scan(fixture, options: ScanOptions(includeHidden: false))
        #expect(withHidden.fileCount == 2)
        #expect(withoutHidden.fileCount == 1)
    }

    @Test func unreadableDirectoriesAreReportedNotSilentlySkipped() throws {
        let fixture = try Fixture()
        defer {
            try? fixture.chmod("locked", 0o755)   // so cleanup can remove it
            fixture.cleanUp()
        }
        try fixture.file("locked/secret.bin", bytes: 4_000)
        try fixture.file("open.bin", bytes: 4_000)
        try fixture.chmod("locked", 0o000)

        let root = try scan(fixture)
        #expect(root.unreadableCount == 1)
    }

    @Test func symlinksAreNotFollowed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let target = try fixture.directory("real")
        try fixture.file("real/big.bin", bytes: 60_000)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("link"),
                                                   withDestinationURL: target)

        let root = try scan(fixture)
        // The link itself is tiny; following it would double the total.
        #expect(root.physicalSize < 80_000)
    }

    @Test func scanningAFileReturnsThatFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let file = try fixture.file("solo.bin", bytes: 2_048)
        let node = try #require(Scanner.scan(url: file, options: ScanOptions(), session: ScanSession()))
        #expect(!node.isDirectory)
        #expect(node.logicalSize == 2_048)
    }

    @Test func cancellationStopsTheScan() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("a.bin", bytes: 1_000)
        let session = ScanSession()
        session.cancel()
        #expect(Scanner.scan(url: fixture.root, options: ScanOptions(), session: session) == nil)
    }

    @Test func missingPathsReturnNil() {
        let url = URL(fileURLWithPath: "/nope/does/not/exist-\(UUID().uuidString)")
        #expect(Scanner.scan(url: url, options: ScanOptions(), session: ScanSession()) == nil)
    }

    private func walk(_ root: FileItem) -> [FileItem] {
        var all: [FileItem] = []
        var stack = [root]
        while let node = stack.popLast() {
            all.append(node)
            stack.append(contentsOf: node.children)
        }
        return all
    }
}
