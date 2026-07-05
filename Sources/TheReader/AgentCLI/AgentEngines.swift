import Foundation

/// One local CLI agent. `answer` runs the CLI headless + read-only in
/// `workingDirectory` and returns the final answer text plus a session id for
/// resuming (when the CLI exposes one). Passing `sessionID` resumes that
/// conversation; callers handle fallback-to-replay when a resume fails.
protocol AgentEngine {
    var kind: AgentEngineKind { get }
    func answer(
        prompt: String,
        sessionID: String?,
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> AgentAnswer
}

extension AgentEngine {
    var isAvailable: Bool {
        AgentCLIProcess.resolveExecutable(named: kind.executableName) != nil
    }
}

// MARK: - Claude Code

/// `claude -p "<prompt>" --output-format json` → one JSON object on stdout with
/// `result`, `session_id`, and `is_error`. Read-only is enforced with a
/// tool allowlist that grants no writes/exec; in `-p` mode any other permission
/// request is auto-denied, so the process can never hang on an approval prompt.
struct ClaudeCodeEngine: AgentEngine {
    let kind = AgentEngineKind.claudeCode

    func answer(
        prompt: String,
        sessionID: String?,
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> AgentAnswer {
        guard let executable = AgentCLIProcess.resolveExecutable(named: kind.executableName) else {
            throw AgentCLIError.notInstalled(kind)
        }

        var arguments = [
            "-p", prompt,
            "--output-format", "json",
            "--allowedTools", "Read,Glob,Grep",
            "--disallowedTools", "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch,Task,TodoWrite"
        ]
        if let sessionID {
            arguments += ["--resume", sessionID]
        }

        let result = try await AgentCLIProcess.run(
            executablePath: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        if result.timedOut {
            throw AgentCLIError.timedOut(kind, seconds: Int(timeout))
        }

        if let object = Self.jsonObject(in: result.stdout) {
            let text = (object["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let newSessionID = object["session_id"] as? String
            let isError = (object["is_error"] as? Bool) ?? false

            if isError {
                throw AgentCLIError.runFailed(
                    kind,
                    detail: AgentCLIError.outputTail(text ?? result.stderr)
                )
            }
            if let text, !text.isEmpty {
                // A resumed conversation gets a fresh session id each run, so
                // always hand back the id from this response.
                return AgentAnswer(text: text, sessionID: newSessionID)
            }
        }

        guard result.exitCode == 0 else {
            throw AgentCLIError.runFailed(
                kind,
                detail: AgentCLIError.outputTail(result.stderr.isEmpty ? result.stdout : result.stderr)
            )
        }
        throw AgentCLIError.unparseableOutput(kind, detail: AgentCLIError.outputTail(result.stdout))
    }

    /// Extracts the result object from `--output-format json` stdout. Newer CLIs
    /// emit a JSON array of events (system/assistant/result); older ones emit
    /// the result object alone. Falls back to scanning lines for robustness.
    private static func jsonObject(in stdout: String) -> [String: Any]? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = resultObject(fromParsed: try? JSONSerialization.jsonObject(with: data)) {
            return object
        }
        for line in trimmed.split(separator: "\n").reversed() {
            if let data = line.data(using: .utf8),
               let object = resultObject(fromParsed: try? JSONSerialization.jsonObject(with: data)) {
                return object
            }
        }
        return nil
    }

    private static func resultObject(fromParsed parsed: Any?) -> [String: Any]? {
        if let object = parsed as? [String: Any] {
            return object
        }
        if let events = (parsed as? [Any])?.compactMap({ $0 as? [String: Any] }), !events.isEmpty {
            return events.last { ($0["type"] as? String) == "result" } ?? events.last
        }
        return nil
    }
}

// MARK: - Codex

/// `codex exec "<prompt>" --json` (or `codex exec resume <id> …`) with
/// `sandbox_mode="read-only"`. The final assistant message and the session id
/// are parsed from the JSONL event stream; session-id capture is best-effort
/// (openai/codex#3817) — when it fails the controller replays the thread next
/// turn instead of resuming.
struct CodexEngine: AgentEngine {
    let kind = AgentEngineKind.codex

    func answer(
        prompt: String,
        sessionID: String?,
        workingDirectory: URL,
        timeout: TimeInterval
    ) async throws -> AgentAnswer {
        guard let executable = AgentCLIProcess.resolveExecutable(named: kind.executableName) else {
            throw AgentCLIError.notInstalled(kind)
        }

        var arguments = ["exec"]
        if let sessionID {
            arguments += ["resume", sessionID]
        }
        arguments += [
            "--json",
            "--skip-git-repo-check",
            "-c", "sandbox_mode=\"read-only\"",
            prompt
        ]

        let result = try await AgentCLIProcess.run(
            executablePath: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeout: timeout
        )
        if result.timedOut {
            throw AgentCLIError.timedOut(kind, seconds: Int(timeout))
        }

        let parsed = Self.parseEventStream(result.stdout)
        if let message = parsed.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            return AgentAnswer(text: message, sessionID: parsed.sessionID ?? sessionID)
        }

        guard result.exitCode == 0 else {
            throw AgentCLIError.runFailed(
                kind,
                detail: AgentCLIError.outputTail(result.stderr.isEmpty ? result.stdout : result.stderr)
            )
        }
        throw AgentCLIError.unparseableOutput(
            kind,
            detail: AgentCLIError.outputTail(result.stdout.isEmpty ? result.stderr : result.stdout)
        )
    }

    /// Tolerates both JSONL shapes Codex has shipped: the older
    /// `{"id":…,"msg":{"type":"agent_message","message":…}}` events and the
    /// newer `{"type":"item.completed","item":{…}}` / `{"type":"thread.started"}`.
    static func parseEventStream(_ stdout: String) -> (message: String?, sessionID: String?) {
        var message: String?
        var sessionID: String?

        for line in stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            if let msg = object["msg"] as? [String: Any], let type = msg["type"] as? String {
                switch type {
                case "session_configured":
                    sessionID = (msg["session_id"] as? String) ?? sessionID
                case "agent_message":
                    message = (msg["message"] as? String) ?? message
                default:
                    break
                }
            }

            if let type = object["type"] as? String {
                if type == "thread.started" || type == "session.created" {
                    sessionID = (object["thread_id"] as? String)
                        ?? (object["session_id"] as? String)
                        ?? sessionID
                }
                if type == "item.completed",
                   let item = object["item"] as? [String: Any],
                   let itemType = (item["type"] as? String) ?? (item["item_type"] as? String),
                   itemType == "agent_message" || itemType == "assistant_message" {
                    message = (item["text"] as? String) ?? (item["message"] as? String) ?? message
                }
            }

            if sessionID == nil, let sid = object["session_id"] as? String {
                sessionID = sid
            }
        }

        return (message, sessionID)
    }
}
