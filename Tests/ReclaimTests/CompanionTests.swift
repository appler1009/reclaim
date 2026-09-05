import Foundation
import ReclaimKit
import Testing
@testable import DiskMap

/// A tree with known sizes, so a payload can be checked against arithmetic
/// rather than against whatever happens to be on the disk.
@MainActor
private func sampleTab(target: String = "/tmp/sample") -> AppModel {
    let photo = FileItem(name: "trip.jpg", isDirectory: false,
                         logicalSize: 900, physicalSize: 1_000)
    let clip = FileItem(name: "clip.mov", isDirectory: false,
                        logicalSize: 4_000, physicalSize: 4_000)
    let empty = FileItem(name: "nothing.txt", isDirectory: false)
    let media = FileItem(name: "Media", isDirectory: true, fileCount: 3,
                         children: [clip, photo, empty])
    media.physicalSize = 5_000
    media.logicalSize = 4_900

    let source = FileItem(name: "main.swift", isDirectory: false,
                          logicalSize: 500, physicalSize: 1_000)
    let root = FileItem(name: target, isDirectory: true, fileCount: 4,
                        children: [media, source])
    root.physicalSize = 6_000
    root.logicalSize = 5_400

    let model = AppModel()
    model.adoptForTesting(root: root, url: URL(fileURLWithPath: target))
    return model
}

private func get(_ target: String, token: String? = nil) -> HTTPListener.Request {
    var headers: [String: String] = [:]
    if let token { headers["authorization"] = "Bearer \(token)" }
    return HTTPListener.Request(method: "GET", target: target, headers: headers, body: Data())
}

private func post(_ target: String, _ body: String) -> HTTPListener.Request {
    HTTPListener.Request(method: "POST", target: target, headers: [:], body: Data(body.utf8))
}

private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPListener.Response) throws -> T {
    try CompanionAPI.decoder().decode(type, from: response.body)
}

/// Its own defaults suite each time: a test must not pair a device into the
/// user's real preferences, nor inherit one from the test before it.
@MainActor
private func isolatedService() -> CompanionService {
    let defaults = UserDefaults(suiteName: "reclaim.tests.\(UUID().uuidString)")!
    return CompanionService(defaults: defaults)
}

@Suite("Live tabs")
@MainActor
struct LiveTabsTests {
    @Test func aTabSummarisesWhatItIsShowing() {
        let model = sampleTab()
        let summary = LiveTabs.summary(of: model)
        #expect(summary.id == model.tabID)
        #expect(summary.target == "/tmp/sample")
        #expect(summary.phase == "ready")
        #expect(summary.totalBytes == 6_000)          // physical, the default measure
        #expect(summary.totalHuman == "5.9 KB")
        #expect(summary.fileCount == 4)
        #expect(summary.currentPath == "/tmp/sample")
        #expect(summary.error == nil)
    }

    @Test func aFailedScanCarriesItsReason() {
        let model = AppModel()
        model.phase = .failed("No permission")
        let summary = LiveTabs.summary(of: model)
        #expect(summary.phase == "failed")
        #expect(summary.error == "No permission")
        #expect(summary.title == "New Scan")
    }

    @Test func theRootNodeRanksItsChildrenAndDropsEmptyOnes() throws {
        let model = sampleTab()
        let node = try #require(LiveTabs.node(of: model, path: nil))
        #expect(node.path == "/tmp/sample")
        #expect(node.children.map(\.name) == ["Media", "main.swift"])
        #expect(node.children[0].bytes == 5_000)
        #expect(abs(node.children[0].share - 5.0 / 6.0) < 0.0001)
        #expect(node.directoryCount == 1)
        #expect(node.omittedChildren == 0)
        #expect(node.breadcrumb.map(\.name) == ["/tmp/sample"])
    }

    @Test func drillingDownKeepsTheTrailBackUp() throws {
        let model = sampleTab()
        let node = try #require(LiveTabs.node(of: model, path: "/tmp/sample/Media"))
        #expect(node.name == "Media")
        #expect(node.breadcrumb.map(\.path) == ["/tmp/sample", "/tmp/sample/Media"])
        // The zero-byte file is not a tile and not a row.
        #expect(node.children.map(\.name) == ["clip.mov", "trip.jpg"])
        #expect(node.children[0].family == .media)
    }

    @Test func aCappedFolderSaysHowMuchItLeftOut() throws {
        let model = sampleTab()
        let node = try #require(LiveTabs.node(of: model, path: nil, limit: 1))
        #expect(node.children.count == 1)
        #expect(node.omittedChildren == 1)
    }

    @Test func browsingDoesNotMoveTheMacWindow() throws {
        let model = sampleTab()
        _ = LiveTabs.node(of: model, path: "/tmp/sample/Media")
        #expect(model.zoomRoot?.path == "/tmp/sample")
    }

    @Test func pathsOutsideTheScanAreNotFound() {
        let model = sampleTab()
        #expect(LiveTabs.node(of: model, path: "/etc/passwd") == nil)
        #expect(LiveTabs.node(of: model, path: "/tmp/sample-other") == nil)
        #expect(LiveTabs.node(of: model, path: "/tmp/sample/Media/missing") == nil)
    }

    @Test func aTrailingSlashIsTheSameFolder() throws {
        let model = sampleTab()
        let node = try #require(LiveTabs.node(of: model, path: "/tmp/sample/Media/"))
        #expect(node.name == "Media")
    }

    @Test func aVolumeScanIsFoundFromItsRoot() throws {
        let root = FileItem(name: "/", isDirectory: true, fileCount: 1)
        let library = FileItem(name: "Library", isDirectory: true, physicalSize: 10)
        root.children = [library]
        library.parent = root
        root.physicalSize = 10
        let model = AppModel()
        model.adoptForTesting(root: root, url: URL(fileURLWithPath: "/"))

        #expect(LiveTabs.find(in: root, path: "/")?.name == "/")
        #expect(LiveTabs.find(in: root, path: "/Library") === library)
    }

    @Test func aScanRegistersItselfAndIsFoundByID() {
        let tab = sampleTab(target: "/tmp/one")
        #expect(LiveTabs.model(id: tab.tabID) === tab)
        #expect(LiveTabs.models.contains { $0 === tab })
        #expect(LiveTabs.model(id: "not-a-tab") == nil)
    }

    @Test func aClosedTabDropsOutOfTheList() {
        let id: String
        do {
            let tab = sampleTab(target: "/tmp/closing")
            id = tab.tabID
            #expect(LiveTabs.model(id: id) != nil)
        }
        // Weakly held: nothing tells a model its window has gone, so the list
        // is only as long as the windows that are still open.
        #expect(LiveTabs.model(id: id) == nil)
    }
}

@Suite("Companion API")
@MainActor
struct CompanionRouterTests {
    @Test func theHandshakeNeedsNoToken() throws {
        let service = isolatedService()
        let response = CompanionRouter.respond(to: get("/api/v1/info"), service: service)
        #expect(response.status == "200 OK")
        let info = try decode(CompanionAPI.ServiceInfo.self, response)
        #expect(info.apiVersion == "v1")
        #expect(info.pairingOpen == false)
    }

    @Test func everythingElseNeedsOne() {
        let service = isolatedService()
        let response = CompanionRouter.respond(to: get("/api/v1/tabs"), service: service)
        #expect(response.status == "401 Unauthorized")
    }

    @Test func aPairedDeviceSeesTheOpenTabs() throws {
        let service = isolatedService()
        let model = sampleTab()
        let token = service.paired.admit(name: "Phone")

        let response = CompanionRouter.respond(to: get("/api/v1/tabs", token: token),
                                               service: service)
        #expect(response.status == "200 OK")
        let list = try decode(CompanionAPI.TabList.self, response)
        #expect(list.tabs.map(\.id).contains(model.tabID))
    }

    @Test func aTabServesItsRootAndAnyFolderInside() throws {
        let service = isolatedService()
        let model = sampleTab()
        let token = service.paired.admit(name: "Phone")

        let root = CompanionRouter.respond(to: get("/api/v1/tabs/\(model.tabID)", token: token),
                                           service: service)
        let rootNode = try decode(CompanionAPI.Node.self, root)
        #expect(rootNode.path == "/tmp/sample")

        let inner = CompanionRouter.respond(
            to: get("/api/v1/tabs/\(model.tabID)/node?path=/tmp/sample/Media", token: token),
            service: service)
        let innerNode = try decode(CompanionAPI.Node.self, inner)
        #expect(innerNode.name == "Media")
    }

    @Test func anEncodedPathSurvivesTheQueryString() throws {
        let service = isolatedService()
        let model = sampleTab(target: "/tmp/a folder")
        let token = service.paired.admit(name: "Phone")
        let response = CompanionRouter.respond(
            to: get("/api/v1/tabs/\(model.tabID)/node?path=/tmp/a%20folder", token: token),
            service: service)
        let node = try decode(CompanionAPI.Node.self, response)
        #expect(node.path == "/tmp/a folder")
    }

    @Test func aClosedTabIsNotFound() {
        let service = isolatedService()
        let token = service.paired.admit(name: "Phone")
        let response = CompanionRouter.respond(to: get("/api/v1/tabs/gone/node", token: token),
                                               service: service)
        #expect(response.status == "404 Not Found")
    }

    @Test func aTabWithNoScanSaysSoDistinctly() {
        let service = isolatedService()
        let model = AppModel()
        let token = service.paired.admit(name: "Phone")
        let response = CompanionRouter.respond(
            to: get("/api/v1/tabs/\(model.tabID)", token: token), service: service)
        #expect(response.status == "409 Conflict")
    }

    @Test func mcpIsServedToPairedDevicesOnly() {
        let service = isolatedService()
        let unauthorised = CompanionRouter.respond(to: post("/mcp", #"{"method":"ping","id":1}"#),
                                                   service: service)
        #expect(unauthorised.status == "401 Unauthorized")

        let token = service.paired.admit(name: "Phone")
        var request = post("/mcp", #"{"jsonrpc":"2.0","method":"ping","id":1}"#)
        request = HTTPListener.Request(method: "POST", target: "/mcp",
                                       headers: ["authorization": "Bearer \(token)"],
                                       body: request.body)
        let response = CompanionRouter.respond(to: request, service: service)
        #expect(response.status == "200 OK")
        #expect(String(decoding: response.body, as: UTF8.self).contains("\"result\""))
    }

    @Test func anUnknownEndpointSaysWhichOne() {
        let service = isolatedService()
        let token = service.paired.admit(name: "Phone")
        let response = CompanionRouter.respond(to: get("/api/v1/nonsense", token: token),
                                               service: service)
        #expect(response.status == "404 Not Found")
    }
}

@Suite("Pairing")
@MainActor
struct PairingTests {
    @Test func theRightCodeBuysAWorkingToken() throws {
        let service = isolatedService()
        let offer = service.offerPairing()
        let response = CompanionRouter.respond(
            to: post("/api/v1/pair", #"{"code":"\#(offer.code)","device":"Phone"}"#),
            service: service)

        #expect(response.status == "200 OK")
        let paired = try decode(CompanionAPI.PairResponse.self, response)
        #expect(service.paired.accepts(token: paired.token))
        #expect(service.paired.devices.map(\.name) == ["Phone"])
    }

    @Test func aCodeIsGoodOnce() {
        let service = isolatedService()
        let offer = service.offerPairing()
        let body = #"{"code":"\#(offer.code)","device":"Phone"}"#
        _ = CompanionRouter.respond(to: post("/api/v1/pair", body), service: service)
        let second = CompanionRouter.respond(to: post("/api/v1/pair", body), service: service)

        #expect(second.status == "403 Forbidden")
        #expect(service.paired.devices.count == 1)
    }

    @Test func aRunOfWrongGuessesClosesTheOffer() {
        let service = isolatedService()
        let offer = service.offerPairing()
        let wrong = #"{"code":"000000","device":"Intruder"}"#
        // A code that happens to be the offered one would make this test lie.
        #expect(offer.code != "000000")

        for _ in 0 ..< PairingOffer.allowedAttempts {
            #expect(CompanionRouter.respond(to: post("/api/v1/pair", wrong),
                                            service: service).status == "403 Forbidden")
        }
        #expect(service.offer == nil)
        let rightButTooLate = CompanionRouter.respond(
            to: post("/api/v1/pair", #"{"code":"\#(offer.code)","device":"Phone"}"#),
            service: service)
        #expect(rightButTooLate.status == "403 Forbidden")
        #expect(service.paired.devices.isEmpty)
    }

    @Test func anExpiredOfferIsNoOffer() {
        let service = isolatedService()
        let offer = service.offerPairing(now: Date().addingTimeInterval(-PairingOffer.lifetime - 1))
        let result = service.redeem(code: offer.code, device: "Phone")
        #expect(throws: CompanionService.PairingRefusal.self) { try result.get() }
        #expect(service.offer == nil)
    }

    @Test func withNoOfferThereIsNoWayIn() {
        let service = isolatedService()
        let response = CompanionRouter.respond(
            to: post("/api/v1/pair", #"{"code":"123456","device":"Phone"}"#), service: service)
        #expect(response.status == "403 Forbidden")
    }

    @Test func tokensAreStoredHashedAndNeverInTheClear() {
        let service = isolatedService()
        let token = service.paired.admit(name: "Phone")
        let device = service.paired.devices[0]
        #expect(device.tokenHash != token)
        #expect(device.tokenHash == PairedDevices.hash(token))
        #expect(service.paired.accepts(token: "not the token") == false)
        #expect(service.paired.accepts(token: "") == false)
    }

    @Test func forgettingADeviceShutsItOut() {
        let service = isolatedService()
        let token = service.paired.admit(name: "Phone")
        service.paired.forget(service.paired.devices[0])
        #expect(service.paired.accepts(token: token) == false)
    }

    @Test func codesAreSixDigits() {
        for _ in 0 ..< 50 {
            let code = PairingOffer.newCode()
            #expect(code.count == 6)
            #expect(code.allSatisfy { $0.isNumber })
        }
    }
}

@Suite("HTTP parsing")
struct HTTPListenerTests {
    private func parse(_ text: String) -> HTTPListener.Request? {
        HTTPListener.parse(Data(text.utf8))
    }

    @Test func aRequestIsHeldBackUntilItsBodyHasArrived() throws {
        #expect(parse("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nab") == nil)
        let whole = try #require(parse("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nabcde"))
        #expect(String(decoding: whole.body, as: UTF8.self) == "abcde")
    }

    @Test func headerNamesAreCaseInsensitive() throws {
        let request = try #require(parse("GET / HTTP/1.1\r\nAUTHORIZATION: Bearer x\r\n\r\n"))
        #expect(request.headers["authorization"] == "Bearer x")
    }

    @Test func theQueryStringIsSplitAndDecoded() throws {
        let request = try #require(
            parse("GET /api/v1/tabs/1/node?path=/tmp/a%20b&limit=10 HTTP/1.1\r\n\r\n"))
        #expect(request.path == "/api/v1/tabs/1/node")
        #expect(request.segments == ["api", "v1", "tabs", "1", "node"])
        #expect(request.query["path"] == "/tmp/a b")
        #expect(request.query["limit"] == "10")
    }

    @Test func aResponseCarriesItsOwnLength() {
        let response = HTTPListener.Response.json(#"{"ok":true}"#)
        let text = String(decoding: response.data, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 11\r\n"))
        #expect(text.hasSuffix("\r\n\r\n" + #"{"ok":true}"#))
    }

    @Test func aFailureIsJSONEvenWhenTheMessageHasQuotes() throws {
        let response = HTTPListener.Response.failure("404 Not Found", #"no "such" tab"#)
        let decoded = try JSONDecoder().decode(CompanionAPI.APIError.self, from: response.body)
        #expect(decoded.error == #"no "such" tab"#)
    }
}

@Suite("Treemap layout, shared")
struct SquarifyTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

    @Test func everyWeightGetsATile() {
        let tiles = Squarify.layout(weights: [50, 30, 20, 1], in: bounds)
        #expect(tiles.count == 4)
        #expect(Set(tiles.map(\.index)) == [0, 1, 2, 3])
    }

    @Test func areasAreProportionalToWeights() throws {
        let weights = [60.0, 30.0, 10.0]
        let tiles = Squarify.layout(weights: weights, in: bounds)
        let total = Double(bounds.width * bounds.height)
        for tile in tiles {
            let expected = weights[tile.index] / weights.reduce(0, +) * total
            let actual = Double(tile.rect.width * tile.rect.height)
            #expect(abs(actual - expected) / expected < 0.02)
        }
    }

    @Test func tilesStayInsideTheBoundsAndDoNotOverlap() {
        let tiles = Squarify.layout(weights: [40, 25, 20, 10, 5], in: bounds)
        for tile in tiles {
            #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(tile.rect))
        }
        for (index, tile) in tiles.enumerated() {
            for other in tiles[(index + 1)...] {
                let overlap = tile.rect.intersection(other.rect)
                #expect(overlap.isNull || overlap.width < 0.001 || overlap.height < 0.001)
            }
        }
    }

    @Test func aSingleWeightFillsTheWholeArea() throws {
        let tile = try #require(Squarify.layout(weights: [1], in: bounds).first)
        #expect(tile.rect == bounds)
    }

    @Test func nothingToLayOutIsNotACrash() {
        #expect(Squarify.layout(weights: [], in: bounds).isEmpty)
        #expect(Squarify.layout(weights: [0, 0], in: bounds).isEmpty)
        #expect(Squarify.layout(weights: [1], in: .zero).isEmpty)
    }

    @Test func zeroWeightsAreSkippedRatherThanDrawnFlat() {
        let tiles = Squarify.layout(weights: [10, 0, 5], in: bounds)
        #expect(tiles.map(\.index) == [0, 2])
    }
}

/// The whole stack over a real socket: a listener, a URLSession, and the router
/// behind it. The route tests above prove the answers; this proves the wiring.
///
/// Not on the main actor, and not blocking on a semaphore: the router answers
/// *on* the main actor, so a test that held it would be waiting for itself.
@Suite("Companion over HTTP")
struct CompanionOverHTTPTests {
    private func request(_ url: URL, token: String? = nil) async -> (status: Int, data: Data) {
        var request = URLRequest(url: url)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return (0, Data())
        }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    @Test func aPairedDeviceCanWalkFromTheTabListIntoAFolder() async throws {
        // The model is held for the length of the test: `LiveTabs` keeps tabs
        // weakly, and a scan nobody is showing is not an open tab.
        let (service, model, token) = await MainActor.run { () -> (CompanionService, AppModel, String) in
            let service = isolatedService()
            let model = sampleTab()
            return (service, model, service.paired.admit(name: "Phone"))
        }
        let tabID = await model.tabID

        // Loopback rather than the whole network: a test should not put this
        // machine's disk map on the office Wi-Fi.
        let listener = HTTPListener(port: 0, reach: .loopback, label: "test") { request in
            await MainActor.run { CompanionRouter.respond(to: request, service: service) }
        }
        try listener.start()
        defer { listener.stop() }
        for _ in 0 ..< 100 where listener.port == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(listener.port != 0)
        let base = "http://127.0.0.1:\(listener.port)/api/v1"

        let unauthorised = await request(URL(string: base + "/tabs")!)
        #expect(unauthorised.status == 401)

        let tabs = await request(URL(string: base + "/tabs")!, token: token)
        #expect(tabs.status == 200)
        let list = try CompanionAPI.decoder().decode(CompanionAPI.TabList.self, from: tabs.data)
        // Contains, not equals: suites run in parallel and another one's model
        // may still be open.
        #expect(list.tabs.map(\.id).contains(tabID))

        let inner = await request(URL(string: base + "/tabs/\(tabID)/node?path=/tmp/sample/Media")!,
                                  token: token)
        #expect(inner.status == 200)
        let node = try CompanionAPI.decoder().decode(CompanionAPI.Node.self, from: inner.data)
        #expect(node.name == "Media")
        #expect(node.children.map(\.name) == ["clip.mov", "trip.jpg"])
    }
}
