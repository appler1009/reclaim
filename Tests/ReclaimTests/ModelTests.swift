import Foundation
import Testing
@testable import DiskMap

@Suite("File tree")
struct FileItemTests {
    private func sample() -> FileItem {
        let photo = FileItem(name: "trip.jpg", isDirectory: false,
                             logicalSize: 900, physicalSize: 1_000)
        let clip = FileItem(name: "clip.mov", isDirectory: false,
                            logicalSize: 4_000, physicalSize: 4_000)
        let media = FileItem(name: "Media", isDirectory: true, fileCount: 2,
                             children: [clip, photo])
        media.physicalSize = 5_000
        media.logicalSize = 4_900

        let source = FileItem(name: "main.swift", isDirectory: false,
                              logicalSize: 500, physicalSize: 1_000)
        let root = FileItem(name: "/tmp/sample", isDirectory: true, fileCount: 3,
                            children: [media, source])
        root.physicalSize = 6_000
        root.logicalSize = 5_400
        return root
    }

    @Test func pathsAreBuiltFromTheParentChain() {
        let root = sample()
        let clip = root.children[0].children[0]
        #expect(clip.path == "/tmp/sample/Media/clip.mov")
        #expect(clip.depth == 2)
    }

    @Test func extensionsIgnoreDotfilesAndDirectories() {
        #expect(FileItem(name: "a.TAR.GZ", isDirectory: false).ext == "gz")
        #expect(FileItem(name: ".zshrc", isDirectory: false).ext == "")
        #expect(FileItem(name: "plain", isDirectory: false).ext == "")
        #expect(FileItem(name: "Folder.app", isDirectory: true).ext == "")
    }

    @Test func removingAChildSubtractsFromEveryAncestor() {
        let root = sample()
        let media = root.children[0]
        let clip = media.children[0]

        media.remove(child: clip)
        #expect(media.physicalSize == 1_000)
        #expect(root.physicalSize == 2_000)
        #expect(root.fileCount == 2)
        #expect(clip.parent == nil)
    }

    @Test func measureSelectsLogicalOrPhysicalSize() {
        let root = sample()
        #expect(root.size(.physical) == 6_000)
        #expect(root.size(.logical) == 5_400)
    }

    @Test func dominantFamilyDescribesFolderContents() {
        let root = sample()
        #expect(root.children[0].dominantFamily(.physical) == .media)
        #expect(root.dominantFamily(.physical) == .media)
    }

    @Test func dominantFamilyIsRecomputedAfterDeletion() {
        let root = sample()
        let media = root.children[0]
        #expect(root.dominantFamily(.physical) == .media)   // caches
        root.remove(child: media)
        #expect(root.dominantFamily(.physical) == .code)
    }

    @Test func descendantChecksWalkUpwards() {
        let root = sample()
        let clip = root.children[0].children[0]
        #expect(clip.isDescendant(of: root))
        #expect(!root.isDescendant(of: clip))
    }
}

@Suite("Breakdown")
struct BreakdownTests {
    private func sample() -> FileItem {
        let big = FileItem(name: "big.mov", isDirectory: false,
                           logicalSize: 8_000, physicalSize: 8_000)
        let mid = FileItem(name: "mid.swift", isDirectory: false,
                           logicalSize: 1_500, physicalSize: 1_600)
        let small = FileItem(name: "small.png", isDirectory: false,
                             logicalSize: 400, physicalSize: 400)
        let empty = FileItem(name: "empty.txt", isDirectory: false)
        let root = FileItem(name: "/tmp/breakdown", isDirectory: true, fileCount: 4,
                            children: [big, mid, small, empty])
        root.physicalSize = 10_000
        root.children.sort { $0.physicalSize > $1.physicalSize }
        return root
    }

    @Test func rowsAreRankedAndSharesSumToOne() {
        let breakdown = Breakdown.of(sample(), measure: .physical)
        #expect(breakdown.rows.map(\.name) == ["big.mov", "mid.swift", "small.png"])
        #expect(breakdown.rows.map(\.bytes) == breakdown.rows.map(\.bytes).sorted(by: >))
        let shares = breakdown.rows.reduce(0.0) { $0 + $1.share }
        #expect(abs(shares - 1.0) < 0.0001)
    }

    @Test func emptyItemsAreLeftOutOfTheList() {
        let breakdown = Breakdown.of(sample(), measure: .physical)
        #expect(!breakdown.rows.contains { $0.name == "empty.txt" })
    }

    @Test func typeTotalsCoverTheWholeSubtree() {
        let breakdown = Breakdown.of(sample(), measure: .physical)
        #expect(breakdown.types.first?.family == .media)
        #expect(breakdown.types.reduce(UInt64(0)) { $0 + $1.bytes } == 10_000)
        #expect(breakdown.types.map(\.bytes) == breakdown.types.map(\.bytes).sorted(by: >))
    }

    @Test func totalsFollowTheChosenMeasure() {
        let root = sample()
        #expect(Breakdown.of(root, measure: .physical).total == 10_000)
        #expect(Breakdown.of(root, measure: .logical).total == root.logicalSize)
    }
}

@Suite("Volumes")
struct VolumeTests {
    @Test func theStartupVolumeIsListedFirst() {
        let volumes = VolumeScanner.mounted()
        let startup = try? #require(volumes.first)
        #expect(startup?.isStartupVolume == true)
        #expect(startup?.url.path == "/")
    }

    @Test func usageAddsUp() {
        for volume in VolumeScanner.mounted() {
            #expect(volume.used <= volume.capacity)
            #expect(volume.usedFraction >= 0 && volume.usedFraction <= 1)
        }
    }
}

@Suite("Family roll-ups")
struct FamilyTotalsTests {
    private func tree() -> FileItem {
        let clip = FileItem(name: "a.mov", isDirectory: false, logicalSize: 900, physicalSize: 1_000)
        let code = FileItem(name: "b.swift", isDirectory: false, logicalSize: 100, physicalSize: 200)
        let inner = FileItem(name: "inner", isDirectory: true, fileCount: 2, children: [clip, code])
        inner.physicalSize = 1_200
        inner.logicalSize = 1_000
        let photo = FileItem(name: "c.png", isDirectory: false, logicalSize: 300, physicalSize: 400)
        let root = FileItem(name: "/tmp/rollup", isDirectory: true, fileCount: 3,
                            children: [inner, photo])
        root.physicalSize = 1_600
        root.logicalSize = 1_300
        return root
    }

    @Test func totalsMatchAManualWalkOfTheSubtree() {
        let root = tree()
        let totals = root.totals()
        #expect(totals.bytes(.physical)[FileFamily.media.index] == 1_000)
        #expect(totals.bytes(.physical)[FileFamily.code.index] == 200)
        #expect(totals.bytes(.physical)[FileFamily.image.index] == 400)
        #expect(totals.bytes(.logical)[FileFamily.media.index] == 900)
        #expect(totals.bytes(.physical).reduce(0, +) == root.physicalSize)
        #expect(totals.counts.reduce(0, +) == 3)
    }

    @Test func totalsAreComputedWithoutTheScannerHavingRun() {
        // Hand-built trees must work too: the roll-up computes itself on demand.
        #expect(tree().dominantFamily(.physical) == .media)
    }

    @Test func deletingUpdatesTheCachedRollUp() {
        let root = tree()
        let inner = root.children[0]
        _ = root.totals()               // cache it first
        root.remove(child: inner)
        let totals = root.totals()
        #expect(totals.bytes(.physical)[FileFamily.media.index] == 0)
        #expect(totals.bytes(.physical)[FileFamily.image.index] == 400)
        #expect(totals.counts.reduce(0, +) == 1)
    }

    @Test func emptyTotalsFallBackToOther() {
        let empty = FileItem(name: "empty", isDirectory: true)
        #expect(empty.dominantFamily(.physical) == .other)
    }
}

@Suite("Paths")
struct PathTests {
    @Test func pathsJoinWithoutTouchingTheFilesystem() {
        // Names that do not exist on disk still produce the right path, which is
        // only true because path building never stats anything.
        let leaf = FileItem(name: "file.txt", isDirectory: false)
        let mid = FileItem(name: "middle", isDirectory: true, children: [leaf])
        let root = FileItem(name: "/nowhere/at/all", isDirectory: true, children: [mid])
        #expect(leaf.path == "/nowhere/at/all/middle/file.txt")
        #expect(root.path == "/nowhere/at/all")
        #expect(leaf.url.path == "/nowhere/at/all/middle/file.txt")
    }

    @Test func aVolumeRootDoesNotDoubleItsSlash() {
        let child = FileItem(name: "Users", isDirectory: true)
        let root = FileItem(name: "/", isDirectory: true, children: [child])
        _ = root
        #expect(child.path == "/Users")
    }
}

@Suite("Sidebar width")
struct SidebarWidthTests {
    @Test func widthsStayWithinBounds() {
        #expect(SidebarWidth.clamped(10) == SidebarWidth.minimum)
        #expect(SidebarWidth.clamped(10_000) == SidebarWidth.maximum)
        #expect(SidebarWidth.clamped(420) == 420)
    }

    @Test func nonsenseFallsBackToTheDefault() {
        // A corrupt preference must not collapse the sidebar to nothing.
        #expect(SidebarWidth.clamped(.nan) == SidebarWidth.default)
        #expect(SidebarWidth.clamped(.infinity) == SidebarWidth.maximum)
    }
}
