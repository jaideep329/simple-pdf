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

    /// Whether the engine can actually reach the reader's MCP server. Codex
    /// (as of 0.141) cancels every MCP tool call unless the sandbox is
    /// `danger-full-access` ("user cancelled MCP tool call"), and we never run
    /// it outside read-only — so its runs disable the server and the prompt
    /// must not point it there.
    var supportsMCP: Bool { self == .claudeCode }

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
/// consecutive-order aggregation with counts, MCP names prettified —
/// ["Read", "Read", "mcp__simple-pdf__get_page"] → "Read ×2 · simple-pdf: get_page".
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

    /// "mcp__<server>__<tool>" → "<server>: <tool>"; anything else unchanged.
    private static func prettify(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let components = name.components(separatedBy: "__").filter { !$0.isEmpty }
        guard components.count >= 3 else { return name }
        return "\(components[1]): \(components.dropFirst(2).joined(separator: "__"))"
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
        "list_recent_selections", "list_highlights", "search",
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
