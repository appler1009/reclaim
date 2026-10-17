import CoreGraphics
import Foundation
import Testing
import ReclaimKit
@testable import DiskMap

@Suite("City map districts")
struct DistrictTests {
    @Test func familiesAreZonedAsTheirDistrict() {
        #expect(District.zoned(.code) == .techCampus)
        #expect(District.zoned(.document) == .school)
        #expect(District.zoned(.archive) == .warehouse)
        // Every family has somewhere to go, and none is landfill by itself.
        for family in FileFamily.allCases {
            #expect(District.zoned(family) != .landfill)
        }
    }

    @Test func cachesAndBuildOutputAreLandfill() {
        for name in ["Caches", "node_modules", "DerivedData", ".build", "__pycache__", "Logs"] {
            #expect(District.isReclaimable(name: name, isDirectory: true, ext: ""), "\(name)")
        }
        #expect(District.isReclaimable(name: "Installer.dmg", isDirectory: false, ext: "dmg"))
        #expect(District.isReclaimable(name: "system.log", isDirectory: false, ext: "log"))
        #expect(District.isReclaimable(name: ".DS_Store", isDirectory: false, ext: ""))
    }

    @Test func onlyWholeNamesCount() {
        // A folder that merely mentions a cache is somebody's data.
        #expect(!District.isReclaimable(name: "Cache Valley Photos", isDirectory: true, ext: ""))
        #expect(!District.isReclaimable(name: "Documents", isDirectory: true, ext: ""))
        // A file called "Caches" is not the Caches folder.
        #expect(!District.isReclaimable(name: "Caches", isDirectory: false, ext: ""))
        #expect(!District.isReclaimable(name: "notes.md", isDirectory: false, ext: "md"))
    }

    @Test func everythingInsideARebuildableFolderIsLandfill() {
        let library = FileItem(name: "Library", isDirectory: true)
        let caches = FileItem(name: "Caches", isDirectory: true)
        let app = FileItem(name: "com.example.App", isDirectory: true)
        let photos = FileItem(name: "Photos", isDirectory: true)
        library.children = [caches, photos]
        caches.parent = library
        photos.parent = library
        caches.children = [app]
        app.parent = caches

        #expect(app.isWithinReclaimable)
        #expect(caches.isWithinReclaimable)
        #expect(!photos.isWithinReclaimable)
        #expect(District.of(app, family: .data, insideReclaimable: caches.isWithinReclaimable) == .landfill)
        #expect(District.of(photos, family: .image, insideReclaimable: false) == .park)
    }

    @Test func sceneryIsTheSameEveryTime() {
        // Seeded from the name, never `hashValue`, which changes every launch.
        #expect(CityBlock.seed("Projects") == CityBlock.seed("Projects"))
        #expect(CityBlock.seed("Projects") != CityBlock.seed("Projectz"))
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0 ..< 8 { #expect(a.next() == b.next()) }
    }

    @Test func aCityRendersOffscreen() throws {
        // One child per district, laid out and drawn into a bitmap: the painter
        // must cope with every block shape the layout produces.
        let names = ["Sources.swift", "db.sqlite", "thesis.pdf", "film.mov", "photo.heic",
                     "backup.zip", "Tool.app", "prefs.plist", "README", "Caches"]
        let children = names.enumerated().map { index, name in
            FileItem(name: name, isDirectory: name == "Caches",
                     logicalSize: UInt64(1000 - index * 90), physicalSize: UInt64(1000 - index * 90))
        }
        let root = FileItem(name: "root", isDirectory: true, children: children)
        root.physicalSize = children.reduce(0) { $0 + $1.physicalSize }
        root.logicalSize = root.physicalSize
        for child in children { child.parent = root }

        let box = CGRect(x: 0, y: 0, width: 900, height: 600)
        let layout = TreemapLayout.build(root: root, in: box, measure: .physical, maximumDepth: 1)
        let context = try #require(CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        TreemapRenderer.draw(layout: layout, in: context, dirty: box, measure: .physical, staged: [])

        let districts = Set(layout.cells.map {
            TreemapRenderer.district(of: $0, in: layout, measure: .physical, rootWithin: false)
        })
        #expect(districts.contains(.landfill))
        #expect(districts.contains(.techCampus))
        #expect(districts.contains(.school))
    }
}
