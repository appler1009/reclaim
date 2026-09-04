import Foundation
import Testing
@testable import DiskMap

/// A store seeded with two scans of one target, an hour apart.
private struct HistoryFixture {
    let store: SnapshotStore
    let directory: URL
    let target = "/tmp/mcp-target"
    let earlier: Date
    let later: Date

    init() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reclaim-mcp-\(UUID().uuidString)")
        store = SnapshotStore(directory: directory)
        later = Date()
        earlier = later.addingTimeInterval(-3600)

        store.record(Self.snapshot(target: target, caches: 1_000_000, photos: 4_000_000, at: earlier))
        store.record(Self.snapshot(target: target, caches: 9_000_000, photos: 4_000_000, at: later))
    }

    private static func snapshot(target: String, caches: UInt64, photos: UInt64,
                                 at date: Date) -> Snapshot {
        let cacheFile = FileItem(name: "blobs.bin", isDirectory: false,
                                 logicalSize: caches, physicalSize: caches)
        let cachesDir = FileItem(name: "Caches", isDirectory: true, children: [cacheFile])
        cachesDir.physicalSize = caches
        let photo = FileItem(name: "trip.jpg", isDirectory: false,
                             logicalSize: photos, physicalSize: photos)
        let photosDir = FileItem(name: "Photos", isDirectory: true, children: [photo])
        photosDir.physicalSize = photos
        let root = FileItem(name: target, isDirectory: true, fileCount: 2,
                            children: [cachesDir, photosDir])
        root.physicalSize = caches + photos
        return Snapshot(root: root, target: target, measure: .physical, takenAt: date)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@Suite("Disk queries")
struct DiskQueriesTests {
    @Test func targetsReportTheLatestScan() {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let targets = DiskQueries(store: fixture.store).targets()
        #expect(targets.count == 1)
        #expect(targets.first?.target == fixture.target)
        #expect(targets.first?.totalBytes == 13_000_000, "the newer scan, not the older")
        #expect(targets.first?.scanCount == 2)
    }

    @Test func usageListsWhatIsDirectlyInside() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let usage = try #require(DiskQueries(store: fixture.store).usage(target: fixture.target))
        #expect(usage.bytes == 13_000_000)
        #expect(usage.children.map(\.path) == ["/tmp/mcp-target/Caches", "/tmp/mcp-target/Photos"])
        // Grandchildren belong to the folder below, not this one.
        #expect(!usage.children.contains { $0.path.hasSuffix("blobs.bin") })
        #expect(usage.children.first?.shareOfParent ?? 0 > 0.6)
    }

    @Test func usageCanDescendIntoAPath() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let usage = try #require(DiskQueries(store: fixture.store)
            .usage(target: fixture.target, path: "/tmp/mcp-target/Caches"))
        #expect(usage.bytes == 9_000_000)
        #expect(usage.children.map(\.path) == ["/tmp/mcp-target/Caches/blobs.bin"])
    }

    @Test func largestItemsRankTheWholeTree() {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let items = DiskQueries(store: fixture.store).largest(target: fixture.target, limit: 3)
        #expect(items.first?.bytes == 9_000_000)
        let directories = DiskQueries(store: fixture.store)
            .largest(target: fixture.target, directoriesOnly: true)
        #expect(directories.allSatisfy { $0.isDirectory })
    }

    @Test func growthNamesWhatActuallyGrew() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let growth = try #require(DiskQueries(store: fixture.store).growth(target: fixture.target))
        #expect(growth.totalChange == 8_000_000)
        #expect(growth.totalChangeHuman.hasPrefix("+"))
        let biggest = try #require(growth.changes.first)
        #expect(biggest.path.hasSuffix("Caches") || biggest.path.hasSuffix("blobs.bin"))
        #expect(biggest.bytes == 8_000_000)
        // What did not move is not reported at all.
        #expect(!growth.changes.contains { $0.path.hasSuffix("Photos") })
    }

    @Test func historyIsOrderedOldestFirstForPlotting() {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let history = DiskQueries(store: fixture.store).history(target: fixture.target)
        #expect(history.map(\.totalBytes) == [5_000_000, 13_000_000])
    }

    @Test func anUnknownTargetAnswersNothingRatherThanFailing() {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }
        let queries = DiskQueries(store: fixture.store)

        #expect(queries.usage(target: "/nope") == nil)
        #expect(queries.largest(target: "/nope").isEmpty)
        #expect(queries.growth(target: "/nope") == nil)
        #expect(queries.history(target: "/nope").isEmpty)
    }
}

@Suite("MCP endpoint")
struct MCPEndpointTests {
    private func endpoint(_ fixture: HistoryFixture) -> MCPEndpoint {
        MCPEndpoint(queries: DiskQueries(store: fixture.store)) { path in
            DiskQueries.TargetSummary(target: path, lastScan: Date(), totalBytes: 42,
                                      totalHuman: "42 B", fileCount: 1, unreadableCount: 0,
                                      scanCount: 1)
        }
    }

    private func callTool(_ endpoint: MCPEndpoint, _ name: String,
                          _ arguments: [String: Any] = [:]) -> [String: Any]? {
        endpoint.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                         "params": ["name": name, "arguments": arguments]])
    }

    private func text(of response: [String: Any]?) -> String {
        let result = response?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        return content?.first?["text"] as? String ?? ""
    }

    @Test func initializeAnnouncesTheServer() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let response = try #require(endpoint(fixture)
            .handle(["jsonrpc": "2.0", "id": 1, "method": "initialize"]))
        let result = try #require(response["result"] as? [String: Any])
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "Reclaim")
        #expect(result["protocolVersion"] as? String == MCPEndpoint.protocolVersion)
    }

    @Test func everyToolIsDescribedWithASchema() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let response = try #require(endpoint(fixture)
            .handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let result = try #require(response["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        #expect(names.sorted() == ["disk_usage", "growth", "largest_items",
                                   "list_targets", "scan_history", "scan_now",
                                   "volume_space"])
        for tool in tools {
            #expect((tool["description"] as? String)?.isEmpty == false)
            #expect(tool["inputSchema"] is [String: Any])
        }
    }

    @Test func notificationsGetNoReply() {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }
        #expect(endpoint(fixture)
            .handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    }

    @Test func toolsAnswerFromRecordedHistory() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }
        let endpoint = endpoint(fixture)

        #expect(text(of: callTool(endpoint, "list_targets")).contains(fixture.target))
        #expect(text(of: callTool(endpoint, "disk_usage", ["target": fixture.target]))
            .contains("Caches"))
        #expect(text(of: callTool(endpoint, "largest_items",
                                  ["target": fixture.target, "limit": 2])).contains("9000000"))
        #expect(text(of: callTool(endpoint, "growth", ["target": fixture.target]))
            .contains("8000000"))
        #expect(text(of: callTool(endpoint, "scan_history", ["target": fixture.target]))
            .contains("5000000"))
    }

    @Test func aMissingArgumentIsExplainedRatherThanCrashing() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let response = try #require(callTool(endpoint(fixture), "disk_usage"))
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        #expect(text(of: response).contains("`target` is required"))
    }

    @Test func anUnknownTargetComesBackAsAToolErrorNotAProtocolError() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let response = try #require(callTool(endpoint(fixture), "growth", ["target": "/nope"]))
        #expect(response["error"] == nil, "the call succeeded; the answer is the problem")
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test func scanNowGoesThroughTheScanner() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let response = callTool(endpoint(fixture), "scan_now", ["path": "/tmp/whatever"])
        #expect(text(of: response).contains("/tmp/whatever"))
    }

    @Test func unknownMethodsAreRejectedProperly() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }

        let response = try #require(endpoint(fixture)
            .handle(["jsonrpc": "2.0", "id": 9, "method": "sorcery"]))
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }
}

@Suite("MCP over HTTP", .serialized)
struct MCPServerTests {
    /// Starts the server on a free port and talks to it the way a client would.
    private func withServer(_ body: (String) throws -> Void) throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }
        let endpoint = MCPEndpoint(queries: DiskQueries(store: fixture.store)) { _ in nil }
        // Port 0 asks the system for a free one, so tests never fight the app.
        let server = MCPServer(endpoint: endpoint, port: 0)
        try server.start()
        defer { server.stop() }

        // Wait for the listener to report the port it was given.
        for _ in 0 ..< 100 where server.port == 0 {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(server.port != 0, "the server never came up")
        try body(fixture.target)
        _ = server
    }

    private func post(_ port: UInt16, _ payload: [String: Any]) throws -> [String: Any]? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var result: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, !data.isEmpty {
                result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return result
    }

    @Test func aClientCanInitializeAndListTools() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }
        let endpoint = MCPEndpoint(queries: DiskQueries(store: fixture.store)) { _ in nil }
        let server = MCPServer(endpoint: endpoint, port: 0)
        try server.start()
        defer { server.stop() }
        for _ in 0 ..< 100 where server.port == 0 { Thread.sleep(forTimeInterval: 0.02) }
        let port = server.port
        #expect(port != 0)

        let initialize = try post(port, ["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        let info = (initialize?["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        #expect(info?["name"] as? String == "Reclaim")

        let list = try post(port, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.count == 7)

        // And a real question, answered from the recorded history.
        let call = try post(port, ["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                   "params": ["name": "growth",
                                              "arguments": ["target": fixture.target]]])
        let content = (call?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect((content?.first?["text"] as? String)?.contains("8000000") == true)
    }

    @Test func badJSONIsRefusedWithoutTakingTheServerDown() throws {
        let fixture = HistoryFixture()
        defer { fixture.cleanUp() }
        let server = MCPServer(endpoint: MCPEndpoint(queries: DiskQueries(store: fixture.store)) { _ in nil },
                               port: 0)
        try server.start()
        defer { server.stop() }
        for _ in 0 ..< 100 where server.port == 0 { Thread.sleep(forTimeInterval: 0.02) }
        let port = server.port

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{not json".utf8)
        let done = DispatchSemaphore(value: 0)
        var status = 0
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        #expect(status == 400)

        // Still answering afterwards.
        let ping = try post(port, ["jsonrpc": "2.0", "id": 1, "method": "ping"])
        #expect(ping?["result"] != nil)
    }
}
