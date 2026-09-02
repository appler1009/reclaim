import Foundation
import Testing
@testable import DiskMap

@Suite("Live scanning")
struct LiveScanTests {
    /// A tree big enough that the scan takes long enough to observe.
    private func makeFixture() throws -> Fixture {
        let fixture = try Fixture()
        for branch in 0 ..< 4 {
            for file in 0 ..< 40 {
                try fixture.file("branch-\(branch)/sub-\(file % 5)/file-\(file).bin",
                                 bytes: 4_000 * (branch + 1))
            }
        }
        try fixture.file("loose.bin", bytes: 9_000)
        return fixture
    }

    @Test func theFirstLevelArrivesBeforeTheScanFinishes() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        var partial: FileItem?
        var partialArrivedBeforeReturn = false
        let root = Scanner.scan(url: fixture.root, options: ScanOptions(), session: ScanSession()) {
            partial = $0
            partialArrivedBeforeReturn = true
        }

        #expect(partialArrivedBeforeReturn, "the top level must be handed over during the scan")
        let top = try #require(partial)
        let finished = try #require(root)
        #expect(top.children.count == finished.children.count)
        #expect(Set(top.children.map(\.name)) == Set(finished.children.map(\.name)))
    }

    @Test func thePartialCopySharesNothingWithTheLiveTree() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        var partial: FileItem?
        let root = try #require(Scanner.scan(url: fixture.root, options: ScanOptions(),
                                             session: ScanSession()) { partial = $0 })
        let top = try #require(partial)

        // Nothing the workers touch may be reachable from what the UI reads.
        for child in top.children {
            #expect(child.children.isEmpty, "the copy must not expose subtrees being built")
            #expect(!root.children.contains { $0 === child })
        }
    }

    @Test func filesAtTheTopLevelAlreadyHaveTheirRealSize() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        var partial: FileItem?
        _ = Scanner.scan(url: fixture.root, options: ScanOptions(), session: ScanSession()) {
            partial = $0
        }
        let loose = try #require(partial?.children.first { $0.name == "loose.bin" })
        #expect(loose.physicalSize > 0, "a file's size is known the moment it is seen")
    }

    @Test func branchTotalsAddUpToTheFinishedScan() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let session = ScanSession()
        var partial: FileItem?
        let root = try #require(Scanner.scan(url: fixture.root, options: ScanOptions(),
                                             session: session) { partial = $0 })
        let top = try #require(partial)
        let totals = session.branchTotals().bytes
        #expect(totals.count == top.children.count)

        // Every directory branch ends up matching the real subtree it tracked.
        for (index, child) in top.children.enumerated() where child.isDirectory {
            let real = try #require(root.children.first { $0.name == child.name })
            #expect(totals[index] == real.physicalSize,
                    "branch \(child.name): \(totals[index]) vs \(real.physicalSize)")
        }
    }

    @Test func branchTotalsStartEmptyAndOnlyGrow() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let session = ScanSession()
        var samples: [[UInt64]] = []
        let sampler = Thread {
            for _ in 0 ..< 400 {
                samples.append(session.branchTotals().bytes)
                usleep(200)
            }
        }
        sampler.start()
        _ = Scanner.scan(url: fixture.root, options: ScanOptions(), session: session)
        while !sampler.isFinished { usleep(500) }

        let sized = samples.filter { !$0.isEmpty }
        #expect(!sized.isEmpty, "the sampler should have seen the branches")
        for index in 0 ..< (sized.first?.count ?? 0) {
            let series = sized.map { $0[index] }
            #expect(series == series.sorted(), "branch \(index) went backwards")
        }
    }
}

extension LiveScanTests {
    @Test func branchFileCountsMatchTheFinishedTree() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("alpha/one.bin", bytes: 1_000)
        try fixture.file("alpha/two.bin", bytes: 1_000)
        try fixture.file("beta/deep/three.bin", bytes: 1_000)

        let session = ScanSession()
        var partial: FileItem?
        let root = try #require(Scanner.scan(url: fixture.root, options: ScanOptions(),
                                             session: session) { partial = $0 })
        let top = try #require(partial)
        let counts = session.branchTotals().files

        for (index, child) in top.children.enumerated() where child.isDirectory {
            let real = try #require(root.children.first { $0.name == child.name })
            #expect(counts[index] == real.fileCount, "\(child.name) counted \(counts[index])")
        }
    }
}

@Suite("Scan progress")
struct ScanProgressTests {
    private func fixture() throws -> Fixture {
        let fixture = try Fixture()
        for branch in 0 ..< 5 {
            for file in 0 ..< 20 {
                try fixture.file("branch-\(branch)/nested/file-\(file).bin", bytes: 2_000)
            }
        }
        return fixture
    }

    @Test func progressReachesEveryFolderByTheEnd() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }

        let session = ScanSession()
        _ = Scanner.scan(url: fixture.root, options: ScanOptions(), session: session)

        let completion = session.completion()
        #expect(completion.total == 5, "one branch per top-level folder")
        #expect(completion.done == completion.total)
        #expect(completion.fraction == 1.0, "a finished scan must read as finished")
    }

    @Test func progressOnlyMovesForward() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }

        let session = ScanSession()
        var samples: [Double] = []
        let sampler = Thread {
            for _ in 0 ..< 500 {
                samples.append(session.completion().fraction)
                usleep(200)
            }
        }
        sampler.start()
        _ = Scanner.scan(url: fixture.root, options: ScanOptions(), session: session)
        while !sampler.isFinished { usleep(500) }

        #expect(samples == samples.sorted(), "the bar must never go backwards")
        #expect(samples.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func nothingToScanReportsNoProgressRatherThanDividingByZero() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.file("only-a-file.bin", bytes: 1_000)

        let session = ScanSession()
        _ = Scanner.scan(url: fixture.root, options: ScanOptions(), session: session)
        let completion = session.completion()
        #expect(completion.total == 0)
        #expect(completion.fraction == 0)
    }
}
