import Foundation

/// Lists the APFS snapshots Time Machine keeps on a local volume.
///
/// These are the usual answer to "the disk lost gigabytes and nothing grew":
/// a snapshot pins the blocks of every file it captured, so space that a scan
/// attributes to nothing at all is very often sitting here. macOS thins them
/// on its own, and they are counted as purgeable, which is why free space can
/// come back without anyone deleting a thing.
///
/// Read by asking `tmutil`, because there is no API for it and parsing one
/// line format is cheaper than reading APFS structures. The command runner is
/// injectable so the parsing can be tested without a Time Machine on the box.
enum LocalSnapshots {
    struct Entry: Codable, Equatable {
        /// The full snapshot name, e.g. `com.apple.TimeMachine.2026-09-03-152436.local`.
        let name: String
        /// When it was taken, read out of the name. Nil if the name is not one
        /// Time Machine made.
        let takenAt: Date?
    }

    /// Names look like `com.apple.TimeMachine.2026-09-03-152436.local`.
    private static let stamp = "yyyy-MM-dd-HHmmss"

    static func parse(_ output: String, calendar: Calendar = .current) -> [Entry] {
        let formatter = DateFormatter()
        formatter.dateFormat = stamp
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone

        return output.split(separator: "\n").compactMap { line -> Entry? in
            let name = line.trimmingCharacters(in: .whitespaces)
            // The first line is a heading, and anything without the prefix is
            // not a snapshot we can say anything about.
            guard name.hasPrefix("com.apple.TimeMachine.") else { return nil }
            let middle = name
                .replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
                .replacingOccurrences(of: ".local", with: "")
            return Entry(name: name, takenAt: formatter.date(from: middle))
        }
        .sorted { ($0.takenAt ?? .distantPast) < ($1.takenAt ?? .distantPast) }
    }

    /// What `tmutil` says about a volume. Empty when it cannot be asked, which
    /// is not an error: no Time Machine, no snapshots, nothing to report.
    static func list(volume: String = "/",
                     run: (String) -> String? = LocalSnapshots.tmutil) -> [Entry] {
        guard let output = run(volume) else { return [] }
        return parse(output)
    }

    private static func tmutil(_ volume: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volume]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(decoding: data, as: UTF8.self)
        } catch {
            Log.debug("could not list local snapshots", ["volume": volume,
                                                         "error": error.localizedDescription])
            return nil
        }
    }
}
