import SwiftUI

/// Strip shown above the composer in `CommentThreadPanel`: two "answer with a
/// local CLI agent" buttons, a thinking/cancel state while a run is active, and
/// an inline dismissible error. Only mounted when `AgentCLIFeature.isEnabled`.
struct AgentAnswerBar: View {
    @ObservedObject var controller: AgentCLIController
    let thread: CommentThread

    private var hasHumanMessage: Bool {
        thread.messages.contains { $0.author == .human }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let engine = controller.runningEngine(forThread: thread.id) {
                runningRow(engine)
            } else {
                buttonsRow
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
                Button {
                    controller.answer(threadID: thread.id, using: engine)
                } label: {
                    Label(engine.displayName, systemImage: iconName(for: engine))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!hasHumanMessage)
                .help(helpText(for: engine))
            }

            Spacer()
        }

        let resumable = AgentEngineKind.allCases.filter { thread.agentSessions?[$0.rawValue] != nil }
        if !resumable.isEmpty {
            Text("Continues the \(resumable.map(\.displayName).joined(separator: " and ")) conversation for this thread.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
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

    private func iconName(for engine: AgentEngineKind) -> String {
        engine == .claudeCode ? "sparkles" : "chevron.left.forwardslash.chevron.right"
    }

    private func helpText(for engine: AgentEngineKind) -> String {
        var parts = ["Answer this thread with the local \(engine.displayName) CLI (read-only)."]
        if thread.anchor.kind == .region, !engine.supportsImages {
            parts.append("\(engine.displayName) can't see the region snapshot — it gets the page text only.")
        }
        if thread.agentSessions?[engine.rawValue] != nil {
            parts.append("Continues the previous \(engine.displayName) conversation.")
        }
        return parts.joined(separator: " ")
    }
}
