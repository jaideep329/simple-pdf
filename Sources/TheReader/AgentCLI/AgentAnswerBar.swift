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
