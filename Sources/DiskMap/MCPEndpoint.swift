import Foundation

/// Speaks MCP over JSON-RPC, so a local agent can ask what is on the disk.
///
/// Hand-rolled rather than pulled from an SDK: the surface an app this size
/// needs is three methods — initialize, tools/list, tools/call — and a
/// dependency that drags in a networking stack costs more than it saves here.
/// Everything below is pure request-in/response-out, which is how it is tested.
struct MCPEndpoint {
    let queries: DiskQueries
    /// Runs a fresh scan, so an agent can ask about a folder never scanned
    /// before. Injectable to keep tests off the filesystem.
    var scanner: (String) -> DiskQueries.TargetSummary?

    static let protocolVersion = "2024-11-05"
    static let serverName = "Reclaim"
    /// Taken from the bundle rather than written here, so what the server tells
    /// a client is the version that was actually built.
    static let serverVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
        as? String ?? "0.0.0"

    init(queries: DiskQueries = DiskQueries(),
         scanner: @escaping (String) -> DiskQueries.TargetSummary? = MCPEndpoint.liveScan) {
        self.queries = queries
        self.scanner = scanner
    }

    // MARK: - Tools

    static let tools: [[String: Any]] = [
        [
            "name": "list_targets",
            "description": """
                Every disk or folder Reclaim has scanned, with its size at the last \
                scan, when that was, and how many scans are on record. Start here.
                """,
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "disk_usage",
            "description": """
                What a path holds and what is directly inside it, largest first, \
                from the most recent scan. Omit `path` for the target itself.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "A target from list_targets."],
                    "path": ["type": "string", "description": "A path inside the target."],
                    "limit": ["type": "integer", "description": "Children to return, default 25."],
                ],
                "required": ["target"],
            ],
        ],
        [
            "name": "largest_items",
            "description": "The biggest files and folders anywhere in a target's latest scan.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string"],
                    "limit": ["type": "integer", "description": "default 20"],
                    "directories_only": ["type": "boolean", "description": "default false"],
                ],
                "required": ["target"],
            ],
        ],
        [
            "name": "growth",
            "description": """
                What grew or shrank between the latest scan and an earlier one — \
                the answer to "what has been eating my disk lately". `since` is an \
                ISO 8601 timestamp; without it, the previous scan is used.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string"],
                    "since": ["type": "string", "description": "ISO 8601 timestamp"],
                    "limit": ["type": "integer", "description": "default 20"],
                ],
                "required": ["target"],
            ],
        ],
        [
            "name": "scan_history",
            "description": "Every recorded scan of a target, oldest first: when, how big, how many files.",
            "inputSchema": [
                "type": "object",
                "properties": ["target": ["type": "string"]],
                "required": ["target"],
            ],
        ],
        [
            "name": "volume_space",
            "description": """
                Where a volume's space went, including the space no scan can \
                account for. Reports free and occupied space at every recorded \
                scan of a target, what the scan itself added up to, and the \
                difference — then reads local Time Machine snapshots and the \
                Trash live, which is usually what explains a drop in free space \
                that no folder accounts for. Use this when the disk shrank but \
                `growth` shows nothing big.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": ["type": "string", "description": "A target from list_targets."],
                    "since": ["type": "string",
                              "description": "ISO 8601 timestamp to compare against. "
                                  + "Without it, the oldest scan on record."],
                ],
                "required": ["target"],
            ],
        ],
        [
            "name": "scan_now",
            "description": """
                Scan a path right now and record the result, then return its totals. \
                Use for a folder with no history yet. A large volume can take seconds.
                """,
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string"]],
                "required": ["path"],
            ],
        ],
    ]

    // MARK: - Dispatch

    /// Handles one JSON-RPC request. Returns nil for notifications, which take
    /// no response.
    func handle(_ request: [String: Any]) -> [String: Any]? {
        let id = request["id"]
        guard let method = request["method"] as? String else {
            return Self.error(id: id, code: -32600, message: "Not a JSON-RPC request")
        }

        switch method {
        case "initialize":
            return Self.result(id: id, [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion],
            ])

        case "notifications/initialized", "initialized":
            return nil

        case "tools/list":
            return Self.result(id: id, ["tools": Self.tools])

        case "tools/call":
            let params = request["params"] as? [String: Any] ?? [:]
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                return Self.result(id: id, try call(name, arguments))
            } catch let error as ToolError {
                return Self.result(id: id, Self.toolFailure(error.message))
            } catch {
                return Self.result(id: id, Self.toolFailure(error.localizedDescription))
            }

        case "ping":
            return Self.result(id: id, [:])

        default:
            return Self.error(id: id, code: -32601, message: "Unknown method: \(method)")
        }
    }

    private struct ToolError: Error { let message: String }

    private func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        func requiredString(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.isEmpty else {
                throw ToolError(message: "`\(key)` is required")
            }
            return value
        }

        switch name {
        case "list_targets":
            let targets = queries.targets()
            guard !targets.isEmpty else {
                return Self.toolText("Nothing has been scanned yet. "
                                     + "Use scan_now with a path, or scan from the app.")
            }
            return try Self.toolJSON(targets)

        case "disk_usage":
            let target = try requiredString("target")
            let limit = arguments["limit"] as? Int ?? 25
            guard let usage = queries.usage(target: target,
                                            path: arguments["path"] as? String,
                                            limit: limit) else {
                throw ToolError(message: "No scan on record for \(target). Try list_targets.")
            }
            return try Self.toolJSON(usage)

        case "largest_items":
            let target = try requiredString("target")
            let items = queries.largest(target: target,
                                        limit: arguments["limit"] as? Int ?? 20,
                                        directoriesOnly: arguments["directories_only"] as? Bool ?? false)
            guard !items.isEmpty else {
                throw ToolError(message: "No scan on record for \(target). Try list_targets.")
            }
            return try Self.toolJSON(items)

        case "growth":
            let target = try requiredString("target")
            let since = (arguments["since"] as? String).flatMap(Self.parseDate)
            guard let growth = queries.growth(target: target, since: since,
                                              limit: arguments["limit"] as? Int ?? 20) else {
                throw ToolError(message: "\(target) has only been scanned once, "
                                + "so there is nothing to compare against.")
            }
            return try Self.toolJSON(growth)

        case "volume_space":
            let target = try requiredString("target")
            let since = (arguments["since"] as? String).flatMap(Self.parseDate)
            guard let report = queries.space(target: target, since: since) else {
                throw ToolError(message: "No scan of \(target) carries volume figures. "
                                + "Scans recorded before Reclaim started keeping them, and "
                                + "targets never scanned, both look like this — scan it again.")
            }
            return try Self.toolJSON(report)

        case "scan_history":
            let target = try requiredString("target")
            let history = queries.history(target: target)
            guard !history.isEmpty else {
                throw ToolError(message: "No scan on record for \(target).")
            }
            return try Self.toolJSON(history)

        case "scan_now":
            let path = try requiredString("path")
            guard let summary = scanner(path) else {
                throw ToolError(message: "Could not scan \(path). It may not exist, "
                                + "or Reclaim may lack permission to read it.")
            }
            return try Self.toolJSON(summary)

        default:
            throw ToolError(message: "Unknown tool: \(name)")
        }
    }

    /// Scans a path for real and files the result into history.
    static func liveScan(_ path: String) -> DiskQueries.TargetSummary? {
        let url = URL(fileURLWithPath: path)
        let session = ScanSession()
        guard let root = Scanner.scan(url: url, options: ScanOptions(), session: session) else {
            return nil
        }
        let snapshot = Snapshot(root: root, target: url.path, measure: .physical,
                                volume: VolumeSpace.read(for: url))
        SnapshotStore().record(snapshot)
        return DiskQueries.TargetSummary(target: url.path,
                                         lastScan: snapshot.takenAt,
                                         totalBytes: snapshot.totalBytes,
                                         totalHuman: ByteFormat.string(snapshot.totalBytes),
                                         fileCount: snapshot.fileCount,
                                         unreadableCount: snapshot.unreadableCount,
                                         scanCount: SnapshotStore().snapshots(forTarget: url.path).count)
    }

    // MARK: - JSON-RPC shapes

    static func result(id: Any?, _ value: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(),
         "error": ["code": code, "message": message]]
    }

    /// MCP returns tool output as content blocks, not raw JSON.
    static func toolText(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    static func toolFailure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    static func toolJSON<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Paths are most of what this returns; escaped slashes make them harder
        // to read for both the agent and anyone looking over its shoulder.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return toolText(String(data: data, encoding: .utf8) ?? "[]")
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
