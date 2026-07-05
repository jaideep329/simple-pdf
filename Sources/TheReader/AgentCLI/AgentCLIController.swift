import Foundation

/// Coordinates "answer this comment thread with a local CLI agent" runs: builds
/// the prompt from the thread + anchored page text, spawns the engine off the
/// main thread with a timeout, and appends the final answer as an agent message
/// via `ReaderStore.replyToComment`.
///
/// Owned by `ReaderStore` only when `AgentCLIFeature.isEnabled`. Like the store
/// itself, all public methods are called on the main thread (SwiftUI); engine
/// work happens in detached tasks that hop back via `MainActor.run`.
final class AgentCLIController: ObservableObject {
    /// threadID → engine currently answering it (one run per thread at a time).
    @Published private(set) var activeRuns: [String: AgentEngineKind] = [:]
    /// threadID → last error, shown inline in the thread panel until dismissed.
    @Published private(set) var errors: [String: String] = [:]

    weak var store: ReaderStore?

    private var tasks: [String: Task<Void, Never>] = [:]
    private static let runTimeout: TimeInterval = 300

    // MARK: - State queries

    func runningEngine(forThread threadID: String) -> AgentEngineKind? {
        activeRuns[threadID]
    }

    func error(forThread threadID: String) -> String? {
        errors[threadID]
    }

    func clearError(forThread threadID: String) {
        errors[threadID] = nil
    }

    // MARK: - Run lifecycle

    func answer(threadID: String, using engineKind: AgentEngineKind) {
        guard AgentCLIFeature.isEnabled,
              activeRuns[threadID] == nil,
              let store,
              let thread = store.commentThreads.first(where: { $0.id == threadID })
        else {
            return
        }

        guard thread.messages.contains(where: { $0.author == .human }) else {
            errors[threadID] = "Write a comment first, then ask \(engineKind.displayName) to answer it."
            return
        }

        errors[threadID] = nil
        activeRuns[threadID] = engineKind

        // Prompts are assembled up front on the main thread (page text comes
        // from PDFKit via the store); the detached task only touches strings.
        let imagePath = engineKind.supportsImages ? writeRegionSnapshot(for: thread) : nil
        let replayPrompt = replayPrompt(for: thread, imagePath: imagePath)
        let resumePrompt = resumePrompt(for: thread)
        let sessionID = thread.agentSessions?[engineKind.rawValue]
        let workingDirectory = Self.scratchDirectory()
        let timeout = Self.runTimeout

        tasks[threadID] = Task.detached { [weak self] in
            let engine = engineKind.makeEngine()
            do {
                var usedReplay = sessionID == nil
                var answer: AgentAnswer

                if let sessionID {
                    do {
                        answer = try await engine.answer(
                            prompt: resumePrompt,
                            sessionID: sessionID,
                            workingDirectory: workingDirectory,
                            timeout: timeout
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch AgentCLIError.notInstalled(let kind) {
                        throw AgentCLIError.notInstalled(kind)
                    } catch {
                        // Stale session id or resume unsupported → the persisted
                        // thread is the history: replay it as a fresh run.
                        usedReplay = true
                        answer = try await engine.answer(
                            prompt: replayPrompt,
                            sessionID: nil,
                            workingDirectory: workingDirectory,
                            timeout: timeout
                        )
                    }
                } else {
                    answer = try await engine.answer(
                        prompt: replayPrompt,
                        sessionID: nil,
                        workingDirectory: workingDirectory,
                        timeout: timeout
                    )
                }

                let finalAnswer = answer
                let replayed = usedReplay
                await MainActor.run {
                    self?.finish(threadID: threadID, engine: engineKind, answer: finalAnswer, usedReplay: replayed)
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.clearRun(threadID: threadID)
                }
            } catch {
                let message = (error as? AgentCLIError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    self?.fail(threadID: threadID, message: message)
                }
            }
        }
    }

    func cancel(threadID: String) {
        tasks[threadID]?.cancel()
    }

    private func finish(threadID: String, engine: AgentEngineKind, answer: AgentAnswer, usedReplay: Bool) {
        clearRun(threadID: threadID)
        guard let store else { return }

        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            errors[threadID] = "\(engine.displayName) returned an empty answer."
        } else {
            store.replyToComment(id: threadID, body: text, author: .agent, agentName: engine.displayName)
        }

        if let sessionID = answer.sessionID {
            store.setAgentSession(threadID: threadID, engineKey: engine.rawValue, sessionID: sessionID)
        } else if usedReplay {
            // A replay started a fresh conversation and no id was captured, so
            // any stored id is stale — drop it rather than retry it next turn.
            store.setAgentSession(threadID: threadID, engineKey: engine.rawValue, sessionID: nil)
        }
    }

    private func fail(threadID: String, message: String) {
        clearRun(threadID: threadID)
        errors[threadID] = message
    }

    private func clearRun(threadID: String) {
        activeRuns[threadID] = nil
        tasks[threadID] = nil
    }

    // MARK: - Prompt assembly

    private func replayPrompt(for thread: CommentThread, imagePath: String?) -> String {
        var sections: [String] = []

        sections.append(
            """
            You are answering a reader's comment thread inside "Simple PDF", a macOS PDF reader. \
            Your entire reply is posted verbatim as the next agent message in the thread, so respond \
            with the answer only (inline markdown is fine) — no preamble.
            You are running read-only: do not create, modify, or delete any files.
            """
        )

        let anchor = thread.anchor
        var context = [
            "PDF file (absolute path, readable for extra context): \(thread.documentPath)",
            "Comment anchor: page \(anchor.page)"
        ]
        if let title = store?.displayTitle, !title.isEmpty {
            context.insert("Document: \(title)", at: 0)
        }
        if let quote = anchor.quote, !quote.isEmpty {
            context.append("Anchored quote from page \(anchor.page): \"\(quote)\"")
        }
        if anchor.kind == .region {
            if let imagePath {
                context.append(
                    "The comment is anchored to a drawn region on the page. A PNG snapshot of that region is saved at \(imagePath) — read that image file to see it."
                )
            } else {
                context.append(
                    "The comment is anchored to a drawn region on the page. Its snapshot image cannot be attached here, so rely on the page text below."
                )
            }
        }
        sections.append(context.joined(separator: "\n"))

        if let store {
            let pages = store.mcpPages(from: anchor.page - 1, to: anchor.page + 1, includeText: true)
            if !pages.isEmpty {
                var block = ["Page text around the anchor:"]
                for page in pages {
                    let chapter = page.chapter.map { " (\($0))" } ?? ""
                    block.append("--- Page \(page.page)\(chapter) ---")
                    block.append(page.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "(no extractable text)")
                }
                sections.append(block.joined(separator: "\n"))
            }
        }

        sections.append("Comment thread so far:\n\n\(Self.transcript(of: thread.messages))")
        sections.append("Reply to the reader's latest message.")

        return sections.joined(separator: "\n\n")
    }

    private func resumePrompt(for thread: CommentThread) -> String {
        """
        New activity in the same Simple PDF comment thread (page \(thread.anchor.page)). \
        Reply with the answer only — it is posted verbatim as your next message in the thread. \
        You are still read-only.

        \(Self.transcript(of: Self.messagesSinceLastAgentReply(in: thread)))
        """
    }

    private static func messagesSinceLastAgentReply(in thread: CommentThread) -> [CommentMessage] {
        if let lastAgentIndex = thread.messages.lastIndex(where: { $0.author == .agent }) {
            let tail = Array(thread.messages[thread.messages.index(after: lastAgentIndex)...])
            if !tail.isEmpty { return tail }
        }
        if let lastHuman = thread.messages.last(where: { $0.author == .human }) {
            return [lastHuman]
        }
        return Array(thread.messages.suffix(1))
    }

    private static func transcript(of messages: [CommentMessage]) -> String {
        messages
            .map { message in
                let name = message.author == .human ? "Reader" : (message.agentName ?? "Agent")
                return "[\(name)]\n\(message.body)"
            }
            .joined(separator: "\n\n")
    }

    // MARK: - Scratch directory

    /// Neutral, app-owned working directory for every run — deliberately not the
    /// PDF's folder and not a project, so the cwd carries no context.
    static func scratchDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory

        let directory = base
            .appendingPathComponent("SimplePDF", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Writes the region snapshot PNG into the scratch dir so an image-capable
    /// engine can read it by path. Returns nil for text anchors.
    private func writeRegionSnapshot(for thread: CommentThread) -> String? {
        guard thread.anchor.kind == .region,
              let base64 = thread.anchor.imagePNGBase64,
              let data = Data(base64Encoded: base64)
        else {
            return nil
        }

        let directory = Self.scratchDirectory().appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("region-\(thread.id).png")
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            return nil
        }
    }
}
