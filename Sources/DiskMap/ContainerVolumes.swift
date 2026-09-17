import Foundation

/// The other APFS volumes sharing space with the one a scan covered.
///
/// APFS volumes in a container draw on one pool, so a volume's "used" figure
/// is really the container's: on a startup disk it includes Preboot, VM and
/// Recovery, gigabytes that no walk of `/` will ever enter. Set against a scan
/// they read as a mystery; named, they are not one.
///
/// Read by asking `diskutil`, which is the documented way to get per-volume
/// figures without root. The command runner is injectable so the parsing can
/// be tested against a fixed listing.
enum ContainerVolumes {
    struct Volume: Codable, Equatable {
        let name: String
        /// The APFS role — "Preboot", "VM", "Recovery" — when it has one.
        let role: String?
        let bytes: UInt64
    }

    /// Volumes in the same container as the one mounted at `mount`, excluding
    /// whatever a scan of `mount` walks. Empty when that cannot be told, which
    /// is not an error: the figure is an explanation, not a requirement.
    static func others(forMount mount: String,
                       listing: () -> Data? = ContainerVolumes.diskutil,
                       device: (String) -> String? = ContainerVolumes.device) -> [Volume] {
        guard let own = device(mount), let data = listing() else { return [] }
        var devices: Set<String> = [own]
        // The startup volume is two: the sealed System snapshot at "/" and the
        // Data volume firmlinked into it, which the scan walks as well.
        if mount == "/", let data = device(Firmlinks.dataMount) { devices.insert(data) }
        return parse(data, excluding: devices)
    }

    static func parse(_ data: Data, excluding devices: Set<String>) -> [Volume] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let containers = (plist as? [String: Any])?["Containers"] as? [[String: Any]] else { return [] }

        for container in containers {
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            let identifiers = volumes.compactMap { $0["DeviceIdentifier"] as? String }
            let isOwn = { (identifier: String) in devices.contains { belongs($0, to: identifier) } }
            guard identifiers.contains(where: isOwn) else { continue }

            return volumes.compactMap { volume -> Volume? in
                guard let identifier = volume["DeviceIdentifier"] as? String, !isOwn(identifier),
                      let bytes = (volume["CapacityInUse"] as? NSNumber)?.uint64Value, bytes > 0 else { return nil }
                return Volume(name: volume["Name"] as? String ?? identifier,
                              role: (volume["Roles"] as? [String])?.first,
                              bytes: bytes)
            }
            .sorted { $0.bytes > $1.bytes }
        }
        return []
    }

    /// Whether a mounted device is the volume `identifier` — itself, or a
    /// snapshot of it: "/" mounts "disk3s1s1", a snapshot of volume "disk3s1".
    /// Not a bare prefix test, which would also take "disk3s10" for "disk3s1".
    static func belongs(_ device: String, to identifier: String) -> Bool {
        if device == identifier { return true }
        guard device.hasPrefix(identifier + "s") else { return false }
        let suffix = device.dropFirst(identifier.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// The BSD device a path's volume is mounted from, "disk3s5".
    private static func device(_ path: String) -> String? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        let from = withUnsafePointer(to: &fs.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) { String(cString: $0) }
        }
        return from.hasPrefix("/dev/") ? String(from.dropFirst(5)) : nil
    }

    private static func diskutil() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["apfs", "list", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            Log.debug("could not list APFS volumes", ["error": error.localizedDescription])
            return nil
        }
    }
}
