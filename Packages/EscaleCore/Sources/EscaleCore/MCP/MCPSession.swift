import Foundation

/// Client MCP déclaré à `initialize` (`clientInfo`), plus un identifiant de connexion propre à Escale.
public struct MCPClientInfo: Sendable, Equatable, Hashable {
    public var connectionID: UUID
    public var name: String
    public var version: String

    public init(connectionID: UUID = UUID(), name: String = "inconnu", version: String = "") {
        self.connectionID = connectionID; self.name = name; self.version = version
    }

    /// Libellé affiché (journal, confirmation).
    public var label: String { version.isEmpty ? name : "\(name) \(version)" }
}

/// Description d'un outil exposé par `tools/list`.
public struct MCPToolDefinition: Sendable, Equatable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var operation: MCPOperation

    public init(name: String, title: String, description: String, inputSchema: JSONValue, operation: MCPOperation) {
        self.name = name; self.title = title; self.description = description
        self.inputSchema = inputSchema; self.operation = operation
    }

    var json: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(operation == .read),
                "destructiveHint": .bool(operation == .action),
                "openWorldHint": true,
            ],
        ]
    }
}

/// Appel d'outil reçu (`tools/call`).
public struct MCPToolCall: Sendable {
    public var name: String
    public var arguments: MCPArguments
    public var client: MCPClientInfo

    public init(name: String, arguments: MCPArguments, client: MCPClientInfo) {
        self.name = name; self.arguments = arguments; self.client = client
    }
}

/// Résultat d'un outil : texte lisible par l'agent, plus une forme structurée optionnelle.
public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text; self.structured = structured; self.isError = isError
    }

    public static func error(_ message: String) -> MCPToolResult { MCPToolResult(text: message, isError: true) }

    /// Résultat structuré : le texte est le JSON lui-même (clients qui ignorent `structuredContent`).
    public static func json(_ v: JSONValue) -> MCPToolResult {
        MCPToolResult(text: String(decoding: MCPJSON.encode(v), as: UTF8.self), structured: v)
    }

    var json: JSONValue {
        var o: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(isError),
        ]
        // `structuredContent` doit être un objet (spécification 2025-06-18).
        if case .object = structured { o["structuredContent"] = structured }
        return .object(o)
    }
}

/// Erreur d'argument d'outil : rendue à l'agent comme résultat en erreur (il peut corriger son appel).
public struct MCPArgumentError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// Lecture typée et bornée des arguments d'un outil.
public struct MCPArguments: Sendable, Equatable {
    public var values: [String: JSONValue]
    public init(_ values: [String: JSONValue] = [:]) { self.values = values }

    public func string(_ key: String) throws -> String {
        guard let v = values[key] else { throw MCPArgumentError("missing argument '\(key)'") }
        guard let s = v.stringValue else { throw MCPArgumentError("argument '\(key)' must be a string") }
        return s
    }

    public func optionalString(_ key: String) throws -> String? {
        guard let v = values[key], v != .null else { return nil }
        guard let s = v.stringValue else { throw MCPArgumentError("argument '\(key)' must be a string") }
        return s
    }

    public func int(_ key: String, default d: Int, range: ClosedRange<Int>) throws -> Int {
        guard let v = values[key], v != .null else { return d }
        guard let i = v.intValue else { throw MCPArgumentError("argument '\(key)' must be an integer") }
        guard range.contains(i) else {
            throw MCPArgumentError("argument '\(key)' must be between \(range.lowerBound) and \(range.upperBound)")
        }
        return i
    }

    public func bool(_ key: String, default d: Bool) throws -> Bool {
        guard let v = values[key], v != .null else { return d }
        guard let b = v.boolValue else { throw MCPArgumentError("argument '\(key)' must be a boolean") }
        return b
    }
}

/// Fournisseur des outils (l'app) : catalogue et exécution. Une annulation de la tâche signifie que le client
/// s'est déconnecté (une confirmation en attente doit alors être retirée).
public protocol MCPToolProvider: Sendable {
    func tools() async -> [MCPToolDefinition]
    func call(_ call: MCPToolCall) async -> MCPToolResult
}

/// Une session MCP (une connexion d'un client) : JSON-RPC 2.0, une ligne JSON par message.
/// Seules les méthodes serveur nécessaires sont implémentées : `initialize`, `ping`, `tools/list`, `tools/call`.
public actor MCPSession {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public enum RPCError {
        public static let parse = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
    }

    private let provider: any MCPToolProvider
    private let serverVersion: String
    private let instructions: String
    public private(set) var client: MCPClientInfo
    public private(set) var negotiatedVersion: String?
    public private(set) var isInitialized = false

    public init(provider: any MCPToolProvider, serverVersion: String, instructions: String = MCPCatalog.instructions,
                connectionID: UUID = UUID()) {
        self.provider = provider; self.serverVersion = serverVersion; self.instructions = instructions
        self.client = MCPClientInfo(connectionID: connectionID)
    }

    /// Traite une ligne reçue ; rend la ligne de réponse (sans `\n`), ou nil pour une notification ou une réponse.
    public func handle(_ line: Data) async -> Data? {
        let msg: JSONValue
        do { msg = try MCPJSON.decode(line) } catch {
            return Self.error(id: .null, code: RPCError.parse, message: "parse error")
        }
        if case .array = msg { return Self.error(id: .null, code: RPCError.invalidRequest, message: "batches are not supported") }
        guard case .object(let o) = msg, o["jsonrpc"]?.stringValue == "2.0" else {
            return Self.error(id: .null, code: RPCError.invalidRequest, message: "invalid request")
        }
        guard let method = o["method"]?.stringValue else { return nil }   // réponse du client : ignorée
        guard let id = o["id"], id != .null else {
            if method == "notifications/initialized" { isInitialized = true }
            return nil                                                     // notification
        }
        switch id { case .int, .string: break
        default: return Self.error(id: .null, code: RPCError.invalidRequest, message: "invalid id") }
        let params = o["params"]?.objectValue ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            negotiatedVersion = version
            if let info = params["clientInfo"]?.objectValue {
                client.name = String((info["name"]?.stringValue ?? "inconnu").prefix(80))
                client.version = String((info["version"]?.stringValue ?? "").prefix(40))
            }
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "escale", "title": "Escale", "version": .string(serverVersion)],
                "instructions": .string(instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            let tools = await provider.tools()
            return Self.result(id: id, ["tools": .array(tools.map(\.json))])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: RPCError.invalidParams, message: "missing tool name")
            }
            guard await provider.tools().contains(where: { $0.name == name }) else {
                return Self.error(id: id, code: RPCError.invalidParams, message: "unknown tool: \(name)")
            }
            let args = params["arguments"]?.objectValue ?? [:]
            let r = await provider.call(MCPToolCall(name: name, arguments: MCPArguments(args), client: client))
            return Self.result(id: id, r.json)
        default:
            return Self.error(id: id, code: RPCError.methodNotFound, message: "method not found: \(method)")
        }
    }

    static func result(id: JSONValue, _ r: JSONValue) -> Data {
        MCPJSON.encode(["jsonrpc": "2.0", "id": id, "result": r])
    }

    public static func error(id: JSONValue, code: Int, message: String) -> Data {
        MCPJSON.encode(["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]])
    }
}
