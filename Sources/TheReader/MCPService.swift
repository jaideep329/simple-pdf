import Foundation
import MCP
import Network

// MARK: - Bridge to the reader

/// Main-actor isolated accessor that the (actor-isolated) MCP server uses to read
/// live reader state. Because it is `@MainActor` it is `Sendable`, so it can be
/// captured by the server's `@Sendable` tool handlers, and every access hops to
/// the main thread before touching PDFKit / AppKit.
@MainActor
final class ReaderMCPBridge {
    // Set once at init and only read from @MainActor methods, so nonisolated access is safe.
    nonisolated(unsafe) weak var store: ReaderStore?

    nonisolated init(store: ReaderStore) {
        self.store = store
    }

    func pageInfo() -> MCPPageInfo? { store?.mcpPageInfo() }
    func pageInfo(number: Int) -> MCPPageInfo? { store?.mcpPageInfo(forPageNumber: number) }
    func highlights(limit: Int?) -> [MCPHighlight] { store?.mcpHighlights(limit: limit) ?? [] }
    func recentSelections(limit: Int) -> [SelectionEntry] { store?.mcpRecentSelections(limit: limit) ?? [] }
    func currentOrLatestSelection() -> SelectionEntry? { store?.mcpCurrentOrLatestSelection() }
    func search(query: String, limit: Int) -> [MCPSearchHit] { store?.mcpSearch(query: query, limit: limit) ?? [] }

    @discardableResult
    func open(pageNumber: Int, path: String?, quote: String?) -> Bool {
        store?.mcpOpen(pageNumber: pageNumber, path: path, quote: quote) ?? false
    }

    func comments() -> [CommentThread] { store?.commentThreads ?? [] }
    func pageText(_ page: Int) -> String? { store?.mcpPageInfo(forPageNumber: page)?.text }

    func addComment(body: String, page: Int?, quote: String?) -> CommentThread? {
        guard let store else { return nil }
        let anchor = store.textAnchor(page: page, quote: quote)
        return store.addComment(anchor: anchor, body: body, author: .agent)
    }

    func reply(id: String, body: String) -> CommentThread? {
        store?.replyToComment(id: id, body: body, author: .agent)
    }

    func setStatus(id: String, status: CommentStatus) -> CommentThread? {
        store?.setCommentStatus(id: id, status: status)
    }
}

// MARK: - Service

/// Hosts the in-process MCP server over loopback HTTP. See plan.md, Feature 2.
final class MCPService: @unchecked Sendable {
    static let defaultPort: UInt16 = 8082
    /// Hardcoded, constant bearer token so the client config never needs re-authentication.
    static let bearerToken = "tr-mcp-9f47c2a8e1b6d530"
    static let serverName = "simple-pdf"
    static let serverVersion = "0.1.0"
    private static let displayName = "Simple PDF"
    private static let endpointPath = "/mcp"
    private static let protocolVersion = "2025-11-25"
    private static let supportDirectoryNames = ["SimplePDF", "Simple PDF", "TheReader", "the-reader"]
    private static let toolNames = [
        "get_current_page",
        "get_page",
        "get_selection",
        "list_recent_selections",
        "list_highlights",
        "open_at_page",
        "search",
        "list_comments",
        "get_comment",
        "add_comment",
        "reply_to_comment",
        "resolve_comment",
        "reopen_comment",
    ]

    private let bridge: ReaderMCPBridge
    private let port: UInt16

    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var listener: MCPHTTPListener?

    init(bridge: ReaderMCPBridge, port: UInt16 = MCPService.defaultPort) {
        self.bridge = bridge
        self.port = port
    }

    func start() async {
        let token = persistDiscoveryFiles()

        let server = Server(
            name: Self.serverName,
            version: Self.serverVersion,
            capabilities: .init(tools: .init(listChanged: false))
        )

        // Keep the pipeline permissive for maximum client compatibility: only
        // loopback origin + bearer auth. Dropping the Accept/Content-Type/protocol
        // validators avoids clients being rejected over header strictness.
        let transport = StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                OriginValidator.localhost(port: Int(port)),
                ReaderBearerValidator(token: token),
            ])
        )

        do {
            try await server.start(transport: transport)
        } catch {
            NSLog("MCP server failed to start: \(error.localizedDescription)")
            return
        }

        // Register AFTER start() so our idempotent `initialize` replaces the SDK's
        // default handler, which rejects a second initialize ("Server is already
        // initialized") and breaks fresh clients/threads (e.g. each Codex turn).
        await registerHandlers(on: server)

        let listener = MCPHTTPListener(
            port: port,
            endpointPath: Self.endpointPath
        ) { request in
            await transport.handleRequest(request)
        }

        do {
            try listener.start()
        } catch {
            NSLog("MCP HTTP listener failed to bind on port \(port): \(error.localizedDescription)")
            await server.stop()
            return
        }

        self.server = server
        self.transport = transport
        self.listener = listener
    }

    func stop() async {
        listener?.stop()
        listener = nil
        await server?.stop()
        server = nil
        transport = nil
    }

    // MARK: - Tool registration

    private func registerHandlers(on server: Server) async {
        let bridge = self.bridge

        // Idempotent initialize: always succeed and echo the client's requested
        // protocol version. Our tools are stateless and read-only, so there is no
        // per-session state to protect — every client/turn can initialize cleanly.
        await server.withMethodHandler(Initialize.self) { params in
            Initialize.Result(
                protocolVersion: params.protocolVersion,
                capabilities: .init(tools: .init(listChanged: false)),
                serverInfo: .init(name: Self.serverName, version: Self.serverVersion),
                instructions: nil
            )
        }

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.toolDefinitions())
        }

        await server.withMethodHandler(CallTool.self) { params in
            await Self.handleToolCall(params, bridge: bridge)
        }
    }

    private static func handleToolCall(
        _ params: CallTool.Parameters,
        bridge: ReaderMCPBridge
    ) async -> CallTool.Result {
        let args = params.arguments ?? [:]

        switch params.name {
        case "get_current_page":
            let includeText = args["includeText"]?.boolValue ?? true
            guard var info = await bridge.pageInfo() else {
                return text("No PDF is open.", isError: true)
            }
            if !includeText {
                info = MCPPageInfo(
                    documentTitle: info.documentTitle,
                    documentPath: info.documentPath,
                    page: info.page,
                    pageCount: info.pageCount,
                    chapter: info.chapter,
                    text: nil
                )
            }
            return text(json(info))

        case "get_page":
            guard let page = args["page"]?.intValue else {
                return text("Missing required argument: page", isError: true)
            }
            let includeText = args["includeText"]?.boolValue ?? true
            guard var info = await bridge.pageInfo(number: page) else {
                return text("No PDF is open.", isError: true)
            }
            if !includeText {
                info = MCPPageInfo(
                    documentTitle: info.documentTitle,
                    documentPath: info.documentPath,
                    page: info.page,
                    pageCount: info.pageCount,
                    chapter: info.chapter,
                    text: nil
                )
            }
            return text(json(info))

        case "get_selection":
            let selection = await bridge.currentOrLatestSelection()
            return text(selection.map(json) ?? "null")

        case "list_recent_selections":
            let limit = args["limit"]?.intValue ?? 20
            return text(json(await bridge.recentSelections(limit: limit)))

        case "list_highlights":
            let limit = args["limit"]?.intValue
            return text(json(await bridge.highlights(limit: limit)))

        case "open_at_page":
            guard let page = args["page"]?.intValue else {
                return text("Missing required argument: page", isError: true)
            }
            let opened = await bridge.open(
                pageNumber: page,
                path: args["path"]?.stringValue,
                quote: args["quote"]?.stringValue
            )
            return opened
                ? text(#"{"ok":true,"page":\#(page)}"#)
                : text("Could not open the document at that page (no PDF open?).", isError: true)

        case "search":
            guard let query = args["query"]?.stringValue, !query.isEmpty else {
                return text("Missing required argument: query", isError: true)
            }
            let limit = args["limit"]?.intValue ?? 20
            return text(json(await bridge.search(query: query, limit: limit)))

        case "list_comments":
            var threads = await bridge.comments()
            if let status = args["status"]?.stringValue, let wanted = CommentStatus(rawValue: status) {
                threads = threads.filter { $0.status == wanted }
            }
            if let page = args["page"]?.intValue {
                threads = threads.filter { $0.anchor.page == page }
            }
            threads.sort { $0.updatedAt > $1.updatedAt }
            if let limit = args["limit"]?.intValue, limit > 0, threads.count > limit {
                threads = Array(threads.prefix(limit))
            }
            // Drop the heavy region image from the list; it's returned by get_comment.
            return text(json(threads.map(Self.strippingImage)))

        case "get_comment":
            guard let id = args["id"]?.stringValue else {
                return text("Missing required argument: id", isError: true)
            }
            guard let thread = await bridge.comments().first(where: { $0.id == id }) else {
                return text("No comment with id \(id).", isError: true)
            }
            let pageText = await bridge.pageText(thread.anchor.page)
            var content: [Tool.Content] = [
                .text(
                    text: json(CommentWithContext(thread: Self.strippingImage(thread), pageText: pageText)),
                    annotations: nil,
                    _meta: nil
                )
            ]
            // Region anchors carry a PNG snapshot — hand it to the agent as a real image block.
            if thread.anchor.kind == .region, let png = thread.anchor.imagePNGBase64 {
                content.append(.image(data: png, mimeType: "image/png", annotations: nil, _meta: nil))
            }
            return CallTool.Result(content: content, isError: false)

        case "add_comment":
            guard let body = args["body"]?.stringValue, !body.isEmpty else {
                return text("Missing required argument: body", isError: true)
            }
            guard let thread = await bridge.addComment(
                body: body,
                page: args["page"]?.intValue,
                quote: args["quote"]?.stringValue
            ) else {
                return text("No PDF is open.", isError: true)
            }
            return text(json(thread))

        case "reply_to_comment":
            guard let id = args["id"]?.stringValue else {
                return text("Missing required argument: id", isError: true)
            }
            guard let body = args["body"]?.stringValue, !body.isEmpty else {
                return text("Missing required argument: body", isError: true)
            }
            guard let updated = await bridge.reply(id: id, body: body) else {
                return text("No comment with id \(id).", isError: true)
            }
            return text(json(updated))

        case "resolve_comment":
            guard let id = args["id"]?.stringValue else {
                return text("Missing required argument: id", isError: true)
            }
            guard let updated = await bridge.setStatus(id: id, status: .resolved) else {
                return text("No comment with id \(id).", isError: true)
            }
            return text(json(updated))

        case "reopen_comment":
            guard let id = args["id"]?.stringValue else {
                return text("Missing required argument: id", isError: true)
            }
            guard let updated = await bridge.setStatus(id: id, status: .open) else {
                return text("No comment with id \(id).", isError: true)
            }
            return text(json(updated))

        default:
            return text("Unknown tool: \(params.name)", isError: true)
        }
    }

    private static func toolDefinitions() -> [Tool] {
        [
            Tool(
                name: "get_current_page",
                description: "The page currently shown in the reader: title, path, 1-based page number, page count, chapter, and (optionally) the page text.",
                inputSchema: objectSchema(
                    properties: ["includeText": prop("boolean", "Include the extracted page text. Defaults to true.")]
                )
            ),
            Tool(
                name: "get_page",
                description: "The text and metadata for a specific 1-based page number, without navigating the reader. Use this to read any page directly.",
                inputSchema: objectSchema(
                    properties: [
                        "page": prop("number", "1-based page number to read."),
                        "includeText": prop("boolean", "Include the extracted page text. Defaults to true."),
                    ],
                    required: ["page"]
                )
            ),
            Tool(
                name: "get_selection",
                description: "The live text selection if there is one, otherwise the most recent selection (the \"latest selection\"). Returns null when nothing has been selected.",
                inputSchema: objectSchema(properties: [:])
            ),
            Tool(
                name: "list_recent_selections",
                description: "Recent text selections, newest first, each with citation and a reader deep link.",
                inputSchema: objectSchema(
                    properties: ["limit": prop("number", "Maximum number of selections to return. Defaults to 20.")]
                )
            ),
            Tool(
                name: "list_highlights",
                description: "All highlights in the open PDF, newest first by modification time, each with highlighted text, page, color, and a reader deep link.",
                inputSchema: objectSchema(
                    properties: ["limit": prop("number", "Maximum number of highlights to return.")]
                )
            ),
            Tool(
                name: "open_at_page",
                description: "Bring the reader to the front and navigate to a page, optionally selecting a quote on arrival.",
                inputSchema: objectSchema(
                    properties: [
                        "page": prop("number", "1-based page number to open."),
                        "path": prop("string", "PDF file path. Defaults to the currently open document."),
                        "quote": prop("string", "Optional text to select on the page."),
                    ],
                    required: ["page"]
                )
            ),
            Tool(
                name: "search",
                description: "Search the open PDF for a string. Returns matches with page numbers, a surrounding snippet, and a reader deep link.",
                inputSchema: objectSchema(
                    properties: [
                        "query": prop("string", "Text to search for."),
                        "limit": prop("number", "Maximum number of matches to return. Defaults to 20."),
                    ],
                    required: ["query"]
                )
            ),
            Tool(
                name: "list_comments",
                description: "Comment threads the user attached to passages/regions of the PDF, newest-first. Each thread has an anchor (page, quoted text, optional region image), a status (open or resolved), and a message history. To answer the user's questions, list open threads and reply to each.",
                inputSchema: objectSchema(
                    properties: [
                        "status": prop("string", "Filter by status: \"open\" or \"resolved\"."),
                        "page": prop("number", "Filter to a 1-based page number."),
                        "limit": prop("number", "Maximum number of threads to return."),
                    ]
                )
            ),
            Tool(
                name: "get_comment",
                description: "One comment thread by id, plus the text of the page it is anchored to for context.",
                inputSchema: objectSchema(
                    properties: ["id": prop("string", "Comment thread id.")],
                    required: ["id"]
                )
            ),
            Tool(
                name: "add_comment",
                description: "Start a new comment thread anchored to a page (and optional quoted text). Use this to flag something to the user.",
                inputSchema: objectSchema(
                    properties: [
                        "body": prop("string", "The comment text (markdown)."),
                        "page": prop("number", "1-based page to anchor to. Defaults to the current page."),
                        "quote": prop("string", "Optional quoted text on that page to anchor to."),
                    ],
                    required: ["body"]
                )
            ),
            Tool(
                name: "reply_to_comment",
                description: "Post a reply into an existing comment thread. Replies are attributed to the agent and appear in the reader.",
                inputSchema: objectSchema(
                    properties: [
                        "id": prop("string", "Comment thread id."),
                        "body": prop("string", "The reply text (markdown)."),
                    ],
                    required: ["id", "body"]
                )
            ),
            Tool(
                name: "resolve_comment",
                description: "Mark a comment thread resolved.",
                inputSchema: objectSchema(
                    properties: ["id": prop("string", "Comment thread id.")],
                    required: ["id"]
                )
            ),
            Tool(
                name: "reopen_comment",
                description: "Reopen a resolved comment thread.",
                inputSchema: objectSchema(
                    properties: ["id": prop("string", "Comment thread id.")],
                    required: ["id"]
                )
            ),
        ]
    }

    // MARK: - Discovery files

    /// Writes the loopback endpoint + (constant) bearer token to Application
    /// Support. `mcp-endpoint.json` stays intentionally tiny for compatibility,
    /// while `mcp-discovery.json` and `mcp-codex.toml` give agents enough context
    /// to find and register the running app.
    @discardableResult
    private func persistDiscoveryFiles() -> String {
        let token = Self.bearerToken

        let fileManager = FileManager.default
        guard let applicationSupportDir = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) else {
            return token
        }

        let url = "http://127.0.0.1:\(port)\(Self.endpointPath)"
        let endpoint = MCPEndpointFile(url: url, token: token)
        let discovery = MCPDiscoveryFile(
            serverName: Self.serverName,
            displayName: Self.displayName,
            transport: "streamable-http",
            url: url,
            token: token,
            authorizationHeader: "Bearer \(token)",
            protocolVersion: Self.protocolVersion,
            endpointFile: "mcp-endpoint.json",
            codexConfigTOML: Self.codexConfigSnippet(url: url, token: token),
            tools: Self.toolNames,
            notes: [
                "The server is hosted in-process by the running Simple PDF macOS app.",
                "Start /Applications/Simple PDF.app before calling this endpoint.",
                "Use Authorization: Bearer <token>, Accept: application/json, and Content-Type: application/json.",
            ]
        )

        for directoryName in Self.supportDirectoryNames {
            let supportDir = applicationSupportDir.appendingPathComponent(directoryName, isDirectory: true)
            try? fileManager.createDirectory(at: supportDir, withIntermediateDirectories: true)
            Self.writeJSON(endpoint, to: supportDir.appendingPathComponent("mcp-endpoint.json"))
            Self.writeJSON(discovery, to: supportDir.appendingPathComponent("mcp-discovery.json"), prettyPrinted: true)
            try? Self.codexConfigSnippet(url: url, token: token)
                .write(to: supportDir.appendingPathComponent("mcp-codex.toml"), atomically: true, encoding: .utf8)
        }

        return token
    }

    private static func codexConfigSnippet(url: String, token: String) -> String {
        """
        [mcp_servers.\(serverName)]
        url = "\(url)"
        http_headers = { Authorization = "Bearer \(token)" }

        """
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL, prettyPrinted: Bool = false) {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        }
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// A copy of the thread without the inline region PNG (kept out of list/JSON payloads).
    private static func strippingImage(_ thread: CommentThread) -> CommentThread {
        var copy = thread
        copy.anchor.imagePNGBase64 = nil
        return copy
    }
}

// MARK: - Helpers

private struct MCPEndpointFile: Codable {
    let url: String
    let token: String
}

private struct CommentWithContext: Encodable {
    let thread: CommentThread
    let pageText: String?
}

private struct MCPDiscoveryFile: Codable {
    let serverName: String
    let displayName: String
    let transport: String
    let url: String
    let token: String
    let authorizationHeader: String
    let protocolVersion: String
    let endpointFile: String
    let codexConfigTOML: String
    let tools: [String]
    let notes: [String]
}

private struct ReaderBearerValidator: HTTPRequestValidator {
    let token: String

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        guard let auth = request.header(HTTPHeaderName.authorization) else {
            return .error(statusCode: 401, .invalidRequest("Missing bearer token"))
        }
        guard auth == "Bearer \(token)" else {
            return .error(statusCode: 401, .invalidRequest("Invalid bearer token"))
        }
        return nil
    }
}

private func objectSchema(properties: [String: Value], required: [String] = []) -> Value {
    var schema: [String: Value] = [
        "type": "object",
        "properties": .object(properties),
    ]
    if !required.isEmpty {
        schema["required"] = .array(required.map { .string($0) })
    }
    return .object(schema)
}

private func prop(_ type: String, _ description: String) -> Value {
    .object(["type": .string(type), "description": .string(description)])
}

private func text(_ body: String, isError: Bool = false) -> CallTool.Result {
    CallTool.Result(content: [.text(text: body, annotations: nil, _meta: nil)], isError: isError)
}

private func json<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
    guard
        let data = try? encoder.encode(value),
        let string = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return string
}

// MARK: - Loopback HTTP listener

/// Minimal HTTP/1.1 listener on `127.0.0.1` that adapts requests to the SDK's
/// framework-agnostic `HTTPRequest`/`HTTPResponse`. The stateless transport returns
/// plain JSON (no SSE), so connections are one-shot request/response with `Connection: close`.
final class MCPHTTPListener: @unchecked Sendable {
    private let port: UInt16
    private let endpointPath: String
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let queue = DispatchQueue(label: "com.jaideepsingh.simplepdf.mcp.http")
    private var listener: NWListener?

    init(
        port: UInt16,
        endpointPath: String,
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) {
        self.port = port
        self.endpointPath = endpointPath
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "MCPHTTPListener", code: 1)
        }

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = self.parse(buffer) {
                if request.path != self.endpointPath {
                    self.send(.error(statusCode: 404, .invalidRequest("Not Found")), on: connection)
                    return
                }
                Task {
                    let response = await self.handler(request)
                    self.send(response, on: connection)
                }
                return
            }

            if error != nil || isComplete {
                connection.cancel()
                return
            }

            self.receive(connection, accumulated: buffer)
        }
    }

    /// Parses a complete HTTP/1.1 request from `buffer`, or returns nil if more bytes are needed.
    private func parse(_ buffer: Data) -> HTTPRequest? {
        let terminator = Data([13, 10, 13, 10]) // \r\n\r\n
        guard let headerRange = buffer.range(of: terminator) else { return nil }

        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        let method = String(requestParts[0])
        let rawTarget = String(requestParts[1])
        let path = rawTarget.split(separator: "?").first.map(String.init) ?? rawTarget

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers[name] = value }
        }

        let bodyStart = headerRange.upperBound
        let contentLength = headers.first { $0.key.lowercased() == "content-length" }
            .flatMap { Int($0.value) } ?? 0
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }

        let body: Data?
        if contentLength > 0 {
            let end = buffer.index(bodyStart, offsetBy: contentLength)
            body = buffer.subdata(in: bodyStart..<end)
        } else {
            body = nil
        }

        return HTTPRequest(method: method, headers: headers, body: body, path: path)
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        Task {
            let (status, headers, body) = await Self.materialize(response)
            let data = Self.serialize(status: status, headers: headers, body: body)
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func materialize(_ response: HTTPResponse) async -> (Int, [String: String], Data?) {
        if case .stream(let stream, let headers) = response {
            var body = Data()
            do {
                for try await chunk in stream { body.append(chunk) }
            } catch {}
            return (200, headers, body)
        }
        return (response.statusCode, response.headers, response.bodyData)
    }

    private static func serialize(status: Int, headers: [String: String], body: Data?) -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = String(body?.count ?? 0)
        allHeaders["Connection"] = "close"
        for (name, value) in allHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var out = Data(head.utf8)
        if let body { out.append(body) }
        return out
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
