import Foundation

/// Ships log entries to a local LogDock collector over HTTP.
///
/// Speaks LogDock's intake format directly rather than linking its LogShip
/// package: that package lives beside this one on disk, and a relative path
/// dependency cannot be resolved by a fresh clone or a CI runner. The wire
/// format is four fields, so owning it costs less than the coupling.
///
/// Never throws and never blocks the caller. If the collector is missing or
/// slow, entries are dropped — a logging aid must not be able to affect the app
/// it is watching.
final class LogShipper: @unchecked Sendable {
    static let shared = LogShipper()

    private let lock = NSLock()
    private var collectorURL: URL?
    private var token = ""
    private var source = "unknown"
    private var buffer: [Entry] = []
    private var flushScheduled = false

    /// Batched rather than sent per line, and capped so a burst while the
    /// collector is down cannot grow without bound.
    private static let flushInterval: TimeInterval = 2
    private static let batchSize = 20
    private static let maximumBuffered = 500

    private struct Entry: Encodable {
        let level: String
        let message: String
        let timestamp: Date
        let metadata: [String: String]?
    }

    private struct Payload: Encodable {
        let source: String
        let entries: [Entry]
    }

    /// Version tags on every entry, so a log line says which build produced it.
    private static let buildMetadata: [String: String] = {
        let info = Bundle.main.infoDictionary
        var tags: [String: String] = [:]
        if let version = info?["CFBundleShortVersionString"] as? String { tags["appVersion"] = version }
        if let build = info?["CFBundleVersion"] as? String { tags["appBuild"] = build }
        if let commit = info?["ReclaimSourceCommit"] as? String { tags["commit"] = commit }
        return tags
    }()

    func configure(collectorURL: URL, token: String, source: String) {
        lock.lock()
        self.collectorURL = collectorURL
        self.token = token
        self.source = source
        lock.unlock()
    }

    func log(level: String, message: String, metadata: [String: String]?) {
        var tags = Self.buildMetadata
        for (key, value) in metadata ?? [:] { tags[key] = value }
        let entry = Entry(level: level, message: message, timestamp: Date(), metadata: tags)

        lock.lock()
        guard collectorURL != nil else { lock.unlock(); return }
        buffer.append(entry)
        if buffer.count > Self.maximumBuffered { buffer.removeFirst(buffer.count - Self.maximumBuffered) }
        let sendNow = buffer.count >= Self.batchSize
        let needsSchedule = !flushScheduled && !sendNow
        if needsSchedule { flushScheduled = true }
        lock.unlock()

        if sendNow {
            flush()
        } else if needsSchedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.flushInterval) {
                [weak self] in
                self?.lock.lock()
                self?.flushScheduled = false
                self?.lock.unlock()
                self?.flush()
            }
        }
    }

    private func flush() {
        lock.lock()
        guard let collectorURL, !buffer.isEmpty else { lock.unlock(); return }
        let entries = buffer
        buffer.removeAll()
        let payload = Payload(source: source, entries: entries)
        let token = self.token
        lock.unlock()

        var request = URLRequest(url: collectorURL.appendingPathComponent("v1/ingest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let body = try? encoder.encode(payload) else { return }
        request.httpBody = body

        // Best effort: a failure loses those entries and says nothing about it.
        URLSession.shared.dataTask(with: request).resume()
    }
}
