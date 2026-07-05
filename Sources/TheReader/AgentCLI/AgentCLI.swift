import Foundation

/// Experimental "answer a comment thread with a local CLI agent" feature.
/// Everything the feature touches (UI, spawning, session storage) checks this
/// single constant, so flipping it to `false` removes the feature from every
/// code path without other changes.
enum AgentCLIFeature {
    static let isEnabled = true
}

/// The two supported local CLI agents. `rawValue` doubles as the stable key in
/// `CommentThread.agentSessions`, so never change it for a shipped case.
enum AgentEngineKind: String, CaseIterable, Identifiable, Sendable {
    case claudeCode = "claude-code"
    case codex = "codex"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// Only Claude Code gets the region snapshot PNG; Codex is text-only.
    var supportsImages: Bool { self == .claudeCode }

    /// Whether the engine can actually reach the reader's MCP server. Both can
    /// today — but Codex only because its runs turn the sandbox OFF (see
    /// `CodexEngine`); if that trade-off is ever reverted, flip this back to
    /// `self == .claudeCode` so the prompt stops pointing Codex at the server.
    var supportsMCP: Bool { true }

    func makeEngine() -> AgentEngine {
        switch self {
        case .claudeCode: return ClaudeCodeEngine()
        case .codex: return CodexEngine()
        }
    }
}

/// Final result of one engine run. `sessionID` is best-effort (Codex may not
/// expose one non-interactively); when absent the next turn replays the thread.
/// `toolCalls` lists the names of the tools the run invoked, in call order
/// (MCP tools as `mcp__<server>__<tool>`; Codex shell/MCP calls normalized).
struct AgentAnswer: Sendable {
    let text: String
    let sessionID: String?
    let toolCalls: [String]
}

/// Renders a tool-call list as a compact one-line brief for the UI:
/// first-appearance-order aggregation with counts, names humanized —
/// ["Read", "Read", "mcp__simple-pdf__list_highlights"] → "Read ×2 · Highlights".
/// The reader's own MCP server is implicit, so its prefix is dropped and its
/// tool names get friendly labels; other servers keep a "server: tool" form.
enum AgentToolCallBrief {
    static func format(_ calls: [String]) -> String {
        var counts: [(name: String, count: Int)] = []
        for call in calls.map(prettify) {
            if let index = counts.firstIndex(where: { $0.name == call }) {
                counts[index].count += 1
            } else {
                counts.append((call, 1))
            }
        }
        return counts
            .map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }
            .joined(separator: " · ")
    }

    private static let friendlyToolNames: [String: String] = [
        "get_current_page": "Current page",
        "get_page": "Page text",
        "get_pages": "Page text",
        "get_selection": "Selection",
        "list_recent_selections": "Recent selections",
        "list_highlights": "Highlights",
        "list_notes": "Notes",
        "search": "PDF search",
        "list_comments": "Comments",
        "get_comment": "Comment",
        "open_at_page": "Open page",
        "add_comment": "Add comment",
        "reply_to_comment": "Reply",
        "resolve_comment": "Resolve",
        "reopen_comment": "Reopen"
    ]

    private static func prettify(_ name: String) -> String {
        // Claude's raw MCP form: mcp__<server>__<tool>.
        if name.hasPrefix("mcp__") {
            let components = name.components(separatedBy: "__").filter { !$0.isEmpty }
            if components.count >= 3 {
                return label(server: components[1], tool: components.dropFirst(2).joined(separator: "__"))
            }
        }
        // Codex's normalized form: "<server>: <tool>".
        if let separator = name.range(of: ": ") {
            return label(server: String(name[..<separator.lowerBound]), tool: String(name[separator.upperBound...]))
        }
        return capitalizedFirst(name)
    }

    private static func label(server: String, tool: String) -> String {
        let friendly = friendlyToolNames[tool]
            ?? capitalizedFirst(tool.replacingOccurrences(of: "_", with: " "))
        return server == MCPService.serverName ? friendly : "\(server): \(friendly)"
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

/// The reader's own MCP server, as seen by the spawned agents: they should
/// pull extra PDF context from it first and only fall back to reading the PDF
/// file directly. The mutating tools stay off-limits — the app posts the
/// agent's reply itself.
enum SimplePDFMCP {
    static var url: String {
        "http://127.0.0.1:\(MCPService.defaultPort)\(MCPService.endpointPath)"
    }

    static let readOnlyTools = [
        "get_current_page", "get_page", "get_pages", "get_selection",
        "list_recent_selections", "list_highlights", "list_notes", "search",
        "list_comments", "get_comment"
    ]

    static let mutatingTools = [
        "open_at_page", "add_comment", "reply_to_comment",
        "resolve_comment", "reopen_comment"
    ]
}

enum AgentCLIError: LocalizedError {
    case notInstalled(AgentEngineKind)
    case launchFailed(String)
    case timedOut(AgentEngineKind, seconds: Int)
    case runFailed(AgentEngineKind, detail: String)
    case unparseableOutput(AgentEngineKind, detail: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let kind):
            return "The \(kind.displayName) CLI (`\(kind.executableName)`) was not found in your login shell PATH. Install it and sign in, then try again."
        case .launchFailed(let detail):
            return "The agent CLI could not be launched: \(detail)"
        case .timedOut(let kind, let seconds):
            return "\(kind.displayName) did not finish within \(seconds / 60) minutes and was stopped."
        case .runFailed(let kind, let detail):
            return "\(kind.displayName) failed: \(detail)"
        case .unparseableOutput(let kind, let detail):
            return "\(kind.displayName) finished but its output could not be parsed: \(detail)"
        }
    }

    /// Last few hundred characters of CLI output, flattened for an inline error label.
    static func outputTail(_ text: String, limit: Int = 400) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "(no output)" }
        return String(flattened.suffix(limit))
    }
}
