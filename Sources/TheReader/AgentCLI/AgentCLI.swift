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

    func makeEngine() -> AgentEngine {
        switch self {
        case .claudeCode: return ClaudeCodeEngine()
        case .codex: return CodexEngine()
        }
    }
}

/// Final result of one engine run. `sessionID` is best-effort (Codex may not
/// expose one non-interactively); when absent the next turn replays the thread.
struct AgentAnswer: Sendable {
    let text: String
    let sessionID: String?
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
