import Foundation
import Testing
@testable import DiskMap

@Suite("Container volumes")
struct ContainerVolumesTests {
    /// The shape `diskutil apfs list -plist` prints, trimmed to what is read.
    private let listing: Data = {
        func volume(_ id: String, _ name: String, _ role: String?, _ bytes: UInt64) -> [String: Any] {
            var v: [String: Any] = ["DeviceIdentifier": id, "Name": name, "CapacityInUse": bytes]
            if let role { v["Roles"] = [role] }
            return v
        }
        let plist: [String: Any] = ["Containers": [
            ["ContainerReference": "disk1", "Volumes": [
                volume("disk1s1", "iSCPreboot", "Preboot", 6_000_000),
            ]],
            ["ContainerReference": "disk3", "Volumes": [
                volume("disk3s1", "Macintosh HD", "System", 13_000),
                volume("disk3s2", "Preboot", "Preboot", 10_000),
                volume("disk3s3", "Recovery", "Recovery", 1_500),
                volume("disk3s5", "Data", "Data", 190_000),
                volume("disk3s6", "VM", "VM", 7_500),
                volume("disk3s10", "Empty", nil, 0),
            ]],
            ["ContainerReference": "disk7", "Volumes": [
                volume("disk7s1", "500GB SSD", nil, 39_000),
            ]],
        ]]
        return try! PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }()

    @Test func theStartupDiskLeavesOutBothHalvesOfItself() {
        let devices = ["/": "disk3s1s1", Firmlinks.dataMount: "disk3s5"]
        let others = ContainerVolumes.others(forMount: "/", listing: { listing },
                                             device: { devices[$0] })
        #expect(others.map(\.name) == ["Preboot", "VM", "Recovery"], "largest first, empty ones dropped")
        #expect(others.first?.role == "Preboot")
    }

    @Test func onlyTheScannedVolumesContainerIsConsidered() {
        let others = ContainerVolumes.others(forMount: "/Volumes/500GB SSD", listing: { listing },
                                             device: { _ in "disk7s1" })
        #expect(others.isEmpty, "alone in its container")
    }

    @Test func aSnapshotBelongsToItsVolumeButASiblingWithALongerNumberDoesNot() {
        #expect(ContainerVolumes.belongs("disk3s1s1", to: "disk3s1"))
        #expect(ContainerVolumes.belongs("disk3s5", to: "disk3s5"))
        #expect(!ContainerVolumes.belongs("disk3s10", to: "disk3s1"))
        #expect(!ContainerVolumes.belongs("disk3s1s", to: "disk3s1"))
    }

    @Test func anythingUnreadableGivesNothingRatherThanFailing() {
        #expect(ContainerVolumes.others(forMount: "/", listing: { nil }, device: { _ in "disk3s1" }).isEmpty)
        #expect(ContainerVolumes.others(forMount: "/", listing: { Data("nope".utf8) },
                                        device: { _ in "disk3s1" }).isEmpty)
        #expect(ContainerVolumes.others(forMount: "/", listing: { listing }, device: { _ in nil }).isEmpty)
    }
}

@Suite("Other volumes in the header")
@MainActor
struct OtherVolumesHeaderTests {
    private let gigabyte: UInt64 = 1024 * 1024 * 1024

    private func model(target: String, scanned: UInt64, used: UInt64) -> AppModel {
        let model = AppModel()
        let file = FileItem(name: "big.bin", isDirectory: false, logicalSize: scanned, physicalSize: scanned)
        let root = FileItem(name: target, isDirectory: true, fileCount: 1, children: [file])
        root.physicalSize = scanned
        model.adoptForTesting(root: root, url: URL(fileURLWithPath: target))
        model.volumeSpace = VolumeSpace(volume: "/", capacity: 200 * gigabyte,
                                        available: 200 * gigabyte - used, free: 200 * gigabyte - used)
        return model
    }

    @Test func otherVolumesComeOutOfTheUnaccountedGap() {
        let model = model(target: "/", scanned: 100 * gigabyte, used: 150 * gigabyte)
        #expect(model.unaccountedBytes == 50 * gigabyte)

        model.setOtherVolumesForTesting([
            ContainerVolumes.Volume(name: "Preboot", role: "Preboot", bytes: 12 * gigabyte),
            ContainerVolumes.Volume(name: "VM", role: "VM", bytes: 8 * gigabyte),
        ])
        #expect(model.otherVolumesBytes == 20 * gigabyte)
        #expect(model.unaccountedBytes == 30 * gigabyte)
    }

    @Test func aFolderScanShowsNeither() {
        let model = model(target: "/Users", scanned: 100 * gigabyte, used: 150 * gigabyte)
        model.setOtherVolumesForTesting([ContainerVolumes.Volume(name: "VM", role: "VM", bytes: 8 * gigabyte)])
        #expect(model.otherVolumesBytes == nil)
        #expect(model.unaccountedBytes == nil)
    }

    @Test func otherVolumesThatExplainTheWholeGapLeaveNothingUnaccounted() {
        let model = model(target: "/", scanned: 100 * gigabyte, used: 110 * gigabyte)
        model.setOtherVolumesForTesting([ContainerVolumes.Volume(name: "VM", role: "VM", bytes: 10 * gigabyte)])
        #expect(model.otherVolumesBytes == 10 * gigabyte)
        #expect(model.unaccountedBytes == nil)
    }
}
