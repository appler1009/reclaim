import AppKit

struct VolumeInfo: Identifiable, Equatable {
    let url: URL
    let name: String
    let capacity: UInt64
    /// Free space as macOS reports it for important usage: it counts space the
    /// system would purge if pressed, so it reads higher than what is free now.
    let available: UInt64
    /// Free space without that promise. The gap between the two is what the
    /// system holds as purgeable — local snapshots, mostly.
    let free: UInt64
    let isInternal: Bool
    let isRemovable: Bool
    let isReadOnly: Bool

    var id: String { url.path }
    /// Paired with `available`, so the two always add up to the capacity the
    /// list shows. `VolumeSpace.used` counts occupied blocks instead, which is
    /// the stricter figure and the one worth comparing a scan against.
    var used: UInt64 { capacity > available ? capacity - available : 0 }
    /// What the system is holding but would give back under pressure.
    var purgeable: UInt64 { available > free ? available - free : 0 }
    var usedFraction: Double {
        capacity > 0 ? min(1, Double(used) / Double(capacity)) : 0
    }
    var isStartupVolume: Bool { url.path == "/" }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    var kindDescription: String {
        if isStartupVolume { return "Startup volume" }
        if isRemovable { return "Removable" }
        return isInternal ? "Internal" : "External"
    }
}

enum VolumeScanner {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsBrowsableKey,
        .volumeIsLocalKey, .volumeIsReadOnlyKey, .volumeIsEjectableKey,
        .volumeAvailableCapacityKey,
    ]

    /// Mounted, browsable, local volumes — what a person thinks of as "my disks".
    static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]) ?? []

        var volumes: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            guard values.volumeIsBrowsable ?? false, values.volumeIsLocal ?? false else { continue }
            let capacity = UInt64(values.volumeTotalCapacity ?? 0)
            guard capacity > 0 else { continue }
            volumes.append(VolumeInfo(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                capacity: capacity,
                available: UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)),
                free: UInt64(max(0, values.volumeAvailableCapacity ?? 0)),
                isInternal: values.volumeIsInternal ?? true,
                isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false),
                isReadOnly: values.volumeIsReadOnly ?? false))
        }
        // Startup volume first, then internal disks, then externals.
        return volumes.sorted {
            if $0.isStartupVolume != $1.isStartupVolume { return $0.isStartupVolume }
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

extension VolumeSpace {
    /// Reads the volume `url` sits on. Nil when the volume cannot be measured,
    /// which is no reason to fail a scan — the space figures are an extra.
    static func read(for url: URL) -> VolumeSpace? {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let capacity = UInt64(values.volumeTotalCapacity ?? 0)
        guard capacity > 0 else { return nil }
        let mount = values.volume?.standardizedFileURL.path ?? "/"
        return VolumeSpace(volume: mount,
                           capacity: capacity,
                           available: UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)),
                           free: UInt64(max(0, values.volumeAvailableCapacity ?? 0)))
    }
}
