import CoreGraphics
import Foundation
import Testing
import ReclaimKit
@testable import DiskMap

@Suite("City map districts")
struct DistrictTests {
    private func classify(_ name: String, directory: Bool = false, family: FileFamily = .other,
                          bytes: UInt64 = 1 << 20, files: Int = 1, modified: Date? = nil,
                          git: Bool = false, in ancestors: [String] = []) -> District {
        let ext = directory ? "" : (name.split(separator: ".").count > 1
            ? String(name.split(separator: ".").last!).lowercased() : "")
        return District.classify(DistrictClue(name: name, isDirectory: directory, ext: ext, family: family,
                                              bytes: bytes, fileCount: files, modified: modified,
                                              hasGitFolder: git, ancestors: ancestors))
    }

    @Test func garbageComesInManyKinds() {
        #expect(classify("Caches", directory: true) == .landfill)
        #expect(classify("node_modules", directory: true) == .scrapyard)
        #expect(classify("DerivedData", directory: true) == .rubble)
        #expect(classify("Logs", directory: true) == .logYard)
        #expect(classify("system.log") == .logYard)
        #expect(classify("DiagnosticReports", directory: true) == .toxicDump)
        #expect(classify("Safari-2026-01-01.ips") == .toxicDump)
        #expect(classify(".Trash", directory: true) == .recyclingDepot)
        #expect(classify("iOS DeviceSupport", directory: true) == .ghostTown)
        #expect(classify("Installer.dmg", family: .archive) == .slum)
        #expect(classify(".DS_Store") == .junkyard)
        let kinds = Set(District.allCases.filter(\.isGarbage))
        #expect(kinds.count >= 9)
    }

    @Test func garbageSpreadsDownwards() {
        #expect(classify("com.example.App", directory: true, family: .data,
                         in: ["Caches", "Library", "me"]) == .landfill)
        #expect(classify("react", directory: true, family: .code, in: ["node_modules", "app"]) == .scrapyard)
        // Downloads keeps your files as they are, but its leftovers are a shantytown.
        #expect(classify("old.zip", family: .archive, in: ["Downloads"]) == .slum)
        #expect(classify("notes.md", family: .document, in: ["Downloads"]) == .school)
    }

    @Test func onlyWholeNamesCount() {
        #expect(classify("Cache Valley Photos", directory: true, family: .image) == .park)
        #expect(classify("Caches", directory: false) != .landfill)
    }

    @Test func oneFamilyBecomesManyDistricts() {
        // Code alone: a repository, a big tree, a small project, its history.
        #expect(classify("reclaim", directory: true, family: .code, bytes: 400 << 20, git: true) == .techCampus)
        #expect(classify("monorepo", directory: true, family: .code, bytes: 2 << 30, files: 9000) == .techCampus)
        #expect(classify("service", directory: true, family: .code, bytes: 300 << 20, files: 900) == .officePark)
        #expect(classify("script", directory: true, family: .code, bytes: 1 << 20) == .startupGarage)
        #expect(classify(".git", directory: true, family: .data) == .recordsHall)
        // Documents, media, images, apps.
        #expect(classify("Thesis", directory: true, family: .document, files: 30) == .school)
        #expect(classify("Archive", directory: true, family: .document, files: 5000) == .university)
        #expect(classify("novel.epub", family: .document) == .publicLibrary)
        #expect(classify("song.flac", family: .media) == .concertHall)
        #expect(classify("clip.mov", family: .media) == .filmStudio)
        #expect(classify("Photos Library.photoslibrary", directory: true, family: .image) == .museum)
        #expect(classify("shot.dng", family: .image) == .artStudio)
        #expect(classify("Applications", directory: true, family: .app) == .industrialPark)
        #expect(classify("Steam", directory: true, family: .app) == .amusementPark)
        #expect(classify("Big.app", directory: true, family: .app, bytes: 900 << 20) == .factory)
        // Things known by name.
        #expect(classify("llama.gguf", family: .other) == .aiLab)
        #expect(classify("Ubuntu.utm", family: .other) == .embassy)
        #expect(classify("Docker.raw", family: .data) == .containerPort)
        #expect(classify("Mobile Documents", directory: true) == .airport)
        #expect(classify("Mail", directory: true, family: .data) == .postOffice)
        #expect(classify("Backups", directory: true, family: .archive) == .bankVault)
        #expect(classify("Inter.ttf", family: .other) == .printShop)
        #expect(classify("Desktop", directory: true) == .downtown)
    }

    @Test func oldArchivesBecomeAGhostTown() {
        let longAgo = Date(timeIntervalSinceNow: -5 * 365 * 24 * 3600)
        #expect(classify("dump.tar", family: .archive, bytes: 2 << 30, modified: longAgo) == .ghostTown)
        #expect(classify("dump.tar", family: .archive, bytes: 2 << 30, modified: Date()) == .warehouse)
    }

    @Test func everyDistrictHasAShape() {
        for district in District.allCases {
            #expect(!district.label.isEmpty)
            #expect(!district.hint.isEmpty)
            _ = district.archetype
        }
        #expect(Set(District.allCases.map(\.archetype)).count == Archetype.allCases.count)
    }

    @Test func sceneryIsTheSameEveryTime() {
        // Seeded from the name, never `hashValue`, which changes every launch.
        #expect(CityBlock.seed("Projects") == CityBlock.seed("Projects"))
        #expect(CityBlock.seed("Projects") != CityBlock.seed("Projectz"))
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0 ..< 8 { #expect(a.next() == b.next()) }
    }

    /// One child per archetype, so every builder runs at least once.
    private func town() -> FileItem {
        let names = ["Sources.swift", "db.sqlite", "thesis.pdf", "film.mov", "photo.heic",
                     "backup.zip", "Tool.app", "prefs.plist", "README", "Caches", "node_modules",
                     "Installer.dmg", "crash.ips", "system.log", "Mobile Documents", "Logs"]
        let children = names.enumerated().map { index, name in
            FileItem(name: name, isDirectory: ["Caches", "node_modules", "Mobile Documents", "Logs"].contains(name),
                     logicalSize: UInt64(2000 - index * 90), physicalSize: UInt64(2000 - index * 90))
        }
        let root = FileItem(name: "root", isDirectory: true, children: children)
        root.physicalSize = children.reduce(0) { $0 + $1.physicalSize }
        root.logicalSize = root.physicalSize
        root.children.sort { $0.physicalSize > $1.physicalSize }
        return root
    }

    @Test func aFlatCityRendersOffscreen() throws {
        let root = town()
        let box = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let layout = TreemapLayout.build(root: root, in: box, measure: .physical, maximumDepth: 1)
        let districts = layout.zoned(.physical)
        #expect(districts.count == layout.cells.count)
        #expect(districts.contains(.landfill))
        #expect(districts.contains(.scrapyard))
        let context = try #require(CGContext(data: nil, width: 1200, height: 800, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        TreemapRenderer.draw(layout: layout, in: context, dirty: box, measure: .physical, staged: [],
                             districts: districts)
        // Every archetype also draws without being handed districts.
        TreemapRenderer.draw(layout: layout, in: context, dirty: box, measure: .physical, staged: [])
    }

    @Test func everyArchetypeBuildsIn3D() {
        let materials = MaterialCache()
        let rect = CGRect(x: 100, y: 100, width: 220, height: 160)
        for district in District.allCases {
            var kit = Kit(lot: CityLot(index: 0, rect: rect, district: district, family: .code,
                                       seed: CityBlock.seed(district.rawValue), name: district.label, detail: ""),
                          materials: materials, rng: SplitMix64(seed: 1))
            kit.build()
            #expect(kit.root.childNodes.count > 2, "\(district) built nothing")
            #expect(kit.tallest > 0)
            _ = kit.root.flattenedClone()
        }
    }

    @Test func aTownBuildsWithLabels() {
        let lots = (0 ..< 6).map { index in
            CityLot(index: index, rect: CGRect(x: CGFloat(index) * 150, y: 0, width: 150, height: 300),
                    district: District.allCases[index * 5], family: .data, seed: UInt64(index),
                    name: "lot \(index)", detail: "1 GB")
        }
        let town = CityBuilder.build(lots)
        #expect(town.blocks.count == lots.count)
        #expect(town.town.childNodes.contains { $0.name == "label" })
    }
}
