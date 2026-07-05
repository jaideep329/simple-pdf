import SwiftUI

/// Strip shown above the composer in `CommentThreadPanel`. The engine buttons
/// are sticky toggles: selecting one answers the thread now and keeps
/// auto-answering every message sent from the composer until deselected. Also
/// hosts the thinking/cancel state and an inline dismissible error. Only
/// mounted when `AgentCLIFeature.isEnabled`.
struct AgentAnswerBar: View {
    @ObservedObject var controller: AgentCLIController
    let thread: CommentThread

    private var selectedEngine: AgentEngineKind? {
        thread.autoAnswerEngine.flatMap(AgentEngineKind.init(rawValue:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let engine = controller.runningEngine(forThread: thread.id) {
                runningRow(engine)
            } else {
                buttonsRow
            }

            if let engine = selectedEngine, controller.runningEngine(forThread: thread.id) == nil {
                Text("New messages are answered by \(engine.displayName) automatically. Click it again to turn off.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let error = controller.error(forThread: thread.id) {
                errorRow(error)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var buttonsRow: some View {
        HStack(spacing: 8) {
            Text("Answer with")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(AgentEngineKind.allCases) { engine in
                engineButton(engine)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func engineButton(_ engine: AgentEngineKind) -> some View {
        let isSelected = selectedEngine == engine
        let button = Button {
            controller.toggleAutoAnswer(threadID: thread.id, engine: engine)
        } label: {
            Label {
                Text(engine.displayName)
                    .font(.caption)
            } icon: {
                AgentEngineIcon(engine: engine)
            }
        }

        Group {
            if isSelected {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
        .help(helpText(for: engine, isSelected: isSelected))
    }

    @ViewBuilder
    private func runningRow(_ engine: AgentEngineKind) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("\(engine.displayName) is thinking…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                controller.cancel(threadID: thread.id)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func errorRow(_ error: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.yellow)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button {
                controller.clearError(forThread: thread.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
    }

    private func helpText(for engine: AgentEngineKind, isSelected: Bool) -> String {
        if isSelected {
            return "Auto-answer with \(engine.displayName) is on for this thread — click to turn off."
        }
        var parts = [
            "Answers this thread with the local \(engine.displayName) CLI (read-only) and keeps answering new messages until turned off."
        ]
        if thread.anchor.kind == .region, !engine.supportsImages {
            parts.append("\(engine.displayName) can't see the region snapshot — it gets the page text only.")
        }
        if thread.agentSessions?[engine.rawValue] != nil {
            parts.append("Continues the previous \(engine.displayName) conversation.")
        }
        return parts.joined(separator: " ")
    }
}

/// Live draft bubble shown at the bottom of the thread's message list while an
/// engine run is active: the streamed in-progress answer (token-level for
/// Claude Code, per-event for Codex), or a placeholder until text arrives. It
/// disappears when the run ends and the real agent message is appended.
struct AgentStreamingBubble: View {
    @ObservedObject var controller: AgentCLIController
    let thread: CommentThread

    var body: some View {
        if let engine = controller.runningEngine(forThread: thread.id) {
            let partial = controller.partialAnswer(forThread: thread.id)
            let toolCalls = controller.toolCalls(forThread: thread.id)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        AgentEngineIcon(engine: engine, size: 9)
                            .foregroundStyle(.secondary)
                        Text(engine.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ProgressView()
                            .controlSize(.mini)
                    }

                    if !toolCalls.isEmpty {
                        Label(AgentToolCallBrief.format(toolCalls), systemImage: "wrench.and.screwdriver")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }

                    Group {
                        if let partial, !partial.isEmpty {
                            Text(partial)
                        } else {
                            Text("Thinking…")
                                .italic()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
                Spacer(minLength: 28)
            }
        }
    }
}
