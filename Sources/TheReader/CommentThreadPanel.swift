import AppKit
import SwiftUI

/// Trailing panel showing one comment thread: its anchor (quoted text or region
/// image), the ongoing message history (you ↔ agent), and a composer to add more
/// replies. Updates live as the agent posts replies over MCP.
struct CommentThreadPanel: View {
    @EnvironmentObject private var store: ReaderStore
    @State private var draft = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        if let thread = store.activeCommentThread {
            VStack(spacing: 0) {
                header(thread)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        anchorPreview(thread)

                        if thread.messages.isEmpty {
                            Text("Add your comment below — your coding agent can read and reply to it from the simple-pdf MCP server.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(thread.messages) { message in
                            messageRow(message)
                        }

                        if AgentCLIFeature.isEnabled, let agentCLI = store.agentCLI {
                            AgentStreamingBubble(controller: agentCLI, thread: thread)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                Divider()
                if AgentCLIFeature.isEnabled, let agentCLI = store.agentCLI {
                    AgentAnswerBar(controller: agentCLI, thread: thread)
                    Divider()
                }
                composer(thread)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(_ thread: CommentThread) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Comment")
                    .font(.headline)
                Text("Page \(thread.anchor.page)\(thread.status == .resolved ? "  ·  Resolved" : "")")
                    .font(.caption)
                    .foregroundStyle(thread.status == .resolved ? Color.green : Color.secondary)
            }

            Spacer()

            Button {
                store.setCommentStatus(id: thread.id, status: thread.status == .resolved ? .open : .resolved)
            } label: {
                Image(systemName: thread.status == .resolved ? "arrow.uturn.backward.circle" : "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .help(thread.status == .resolved ? "Reopen" : "Resolve")

            Button {
                isConfirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this comment thread")
            .confirmationDialog(
                "Delete this comment thread?",
                isPresented: $isConfirmingDelete
            ) {
                Button("Delete", role: .destructive) {
                    store.deleteComment(id: thread.id)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The thread and all of its messages are removed permanently. This cannot be undone.")
            }

            Button {
                store.closeActiveComment()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Anchor preview

    @ViewBuilder
    private func anchorPreview(_ thread: CommentThread) -> some View {
        if thread.anchor.kind == .region,
           let base64 = thread.anchor.imagePNGBase64,
           let data = Data(base64Encoded: base64),
           let image = NSImage(data: data) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Region on page \(thread.anchor.page)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
        } else if let quote = thread.anchor.quote, !quote.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Quoted from page \(thread.anchor.page)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(quote)
                    .font(.callout)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(Rectangle().frame(width: 3).foregroundStyle(.tint), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Message

    @ViewBuilder
    private func messageRow(_ message: CommentMessage) -> some View {
        let isHuman = message.author == .human
        HStack {
            if isHuman { Spacer(minLength: 28) }
            VStack(alignment: isHuman ? .trailing : .leading, spacing: 2) {
                Text(isHuman ? "You" : (message.agentName ?? "Agent"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(markdown(message.body))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        isHuman ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
            }
            if !isHuman { Spacer(minLength: 28) }
        }
    }

    private func markdown(_ string: String) -> AttributedString {
        (try? AttributedString(
            markdown: string,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(string)
    }

    // MARK: - Composer

    @ViewBuilder
    private func composer(_ thread: CommentThread) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Comment…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(8)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { send(thread) }

            Button {
                send(thread)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    private func send(_ thread: CommentThread) {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        store.addHumanReply(threadID: thread.id, body: body)
        draft = ""
    }
}
