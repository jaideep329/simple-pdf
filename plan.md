# Simple PDF — Plan

The reader is a **capture + navigation** surface. **Codex / Claude** do the
reasoning (with full repo/vault/web context, via the MCP server). **Obsidian**
is the memory. The app feeds and is driven by the agent — it is not a chat
client and does not embed an LLM.

> This supersedes the original "two features, no in-app search/notes" scope. We
> are now intentionally adding an annotations **sidebar with search** and a
> **comments** system, because comments live in-app and need a home.

---

## Shipped

- **Selection popover** — SwiftUI / Liquid Glass toolbar hosted in
  `PDFReaderView.swift`, anchored to the selection: **Highlight · Copy Quote ·
  Copy Link**. Hover highlight (glass), pointing-hand cursor via
  `.pointerStyle(.link)`, "Copied" confirmation. (These three actions were
  removed from the top toolbar.)
- **Selection history** — timestamped, ~100 entries on `ReaderStore`
  (`SelectionEntry`), powering "latest selection" over MCP.
- **In-process MCP server `simple-pdf`** — loopback HTTP on `127.0.0.1:8082`,
  `StatelessHTTPServerTransport` + a `Network.framework` listener (no SwiftNIO),
  hardcoded constant bearer token `tr-mcp-9f47c2a8e1b6d530`, **idempotent
  `initialize`** (so fresh Codex turns can handshake). Discovery files written
  under several Application Support dirs + a Codex config snippet.
  Built against `modelcontextprotocol/swift-sdk` 0.12.1.
- **Shipped MCP tools**: `get_current_page`, `get_page`, `get_selection`,
  `list_recent_selections`, `list_highlights`, `open_at_page`, `search`.
- Server name is `simple-pdf` in app, Codex config, README, and AGENTS.md.

Client config (already wired in `~/.codex/config.toml`):

```toml
[mcp_servers.simple-pdf]
url = "http://127.0.0.1:8082/mcp"
http_headers = { Authorization = "Bearer tr-mcp-9f47c2a8e1b6d530" }
```

---

## To build

### Feature A — Comments (text- or region-anchored, agent-answered)

The keystone. Select **text** *or* drag a **region** → attach a comment thread.
An **Ask** action creates a `question`-type comment. The coding agent reads open
comments over MCP and replies **in-thread** (and can resolve / add new ones).
"Ask" is just the front door to comments — there is no embedded LLM; answers
come from the external agent with full context.

**Anchors:**
- *Text*: `page + quote + bounds`; reuse the existing deep-link quote matching to
  re-locate on reopen.
- *Region*: `page + rect`, plus a cropped **PNG (base64)** so a multimodal agent
  sees the figure / equation / table. (This replaces any standalone
  "region → image" tool — a region is simply a comment anchor.)

**Storage — sidecar, not in the PDF.** Persist threads in a JSON (or SQLite)
store keyed by the document SHA, mirroring the existing view-state store
(`PDFDocumentStateStore` `documentKey`, `PDFDocumentStateStore.swift:157`).
Highlights/notes stay as PDF annotations (portable); comments are richer,
threaded, and agent-writable, and we avoid rewriting the whole PDF on every edit.

**Thread shape:**

```
CommentThread {
  id (uuid), documentPath,
  anchor: { kind: text|region, page, quote?, bounds, imagePNGBase64? },
  type: note|question, status: open|resolved,
  createdAt, updatedAt,
  messages: [ { id, author: human|agent, agentName?, body (markdown), createdAt } ]
}
```

**UX:**
- Add **Comment** and **Ask** actions to the selection popover. Add a
  **region-drag** gesture to `ReaderPDFView` (modifier-drag or a toolbar toggle)
  to draw a rectangle anchor.
- Threads show as margin markers and in the Comments sidebar tab; a **badge**
  appears on threads with an unread agent reply; a subtle notification fires when
  the agent replies (it works async).
- Resolve / reopen. Optional later: export a resolved thread to an Obsidian
  literature note.

**MCP endpoints (add to `MCPService.swift`):**
- `list_comments(status?, page?, limit?)` → threads with anchor + full message
  history, newest-first. Region anchors include the image (base64 or a ref).
- `get_comment(id)` → one thread + surrounding page text (+ region image).
- `reply_to_comment(id, body)` → agent posts a reply; app updates live + persists.
- `resolve_comment(id)` / `reopen_comment(id)`.
- `add_comment(page, quote?|bounds?, body, type?)` → agent can start a thread.

**The loop** (PR-review-style, low friction): one instruction in Codex/Claude —
"answer my open comments" — and the agent calls `list_comments(status: open)`,
answers each via `reply_to_comment`, and resolves. You fire questions while
reading without breaking stride and triage answers later.

### Feature B — Annotations sidebar (4 tabs + search)

Grow the current Contents-only sidebar into a tabbed inspector (top navigation
tabs inside the sidebar):

- **Contents** — the existing PDF outline (`PDFOutlineSidebar` in
  `ReaderDocumentView.swift`), moved into a tab.
- **Highlights** — every highlight, click to jump; filter by color.
- **Notes** — the sticky PDF notes (Text annotations) the app already supports.
- **Comments** — comment threads with open/resolved filter and unread-reply
  badges, click to jump.

A **search field** at the top of the sidebar filters the active tab by text
(annotation/comment bodies + quotes; section titles for Contents). This is
**navigation / triage**, not cross-document knowledge search — that stays with
the agent + Obsidian. (In-document text find / ⌘F is a separate, optional add.)

Data: reuse the highlight/note enumerations already built for MCP
(`mcpHighlights`, sticky notes) + the comment store.

### Feature C — `get_pages` range MCP tool

`get_pages(from, to, includeText?)` → page infos for an inclusive 1-based range,
so the agent can pull a whole chapter/section in one call to summarize. Builds on
the shipped `get_page`; cap the range to keep payloads sane.

---

## Decisions / notes

- **No OCR, ever.** Scanned / image-only PDFs are explicitly out of scope.
- **Region select = comment anchor**, not a separate "send to agent" flow. The
  cropped image rides along in `list_comments` / `get_comment`.
- **"Ask" creates a comment**; no embedded in-app LLM. (Revisit an optional
  instant "quick answer" mode only if agent round-trip latency becomes annoying.)
- **Highlight id** = `SHA256(pageIndex + bounds)` (already used by
  `list_highlights`). Comment ids = UUID in the sidecar.
- **MCP**: port `8082`, constant hardcoded token, name `simple-pdf`.

## Sequencing

1. Comment data model + sidecar store + the MCP endpoints
   (`list/get/reply/resolve/add`).
2. Comment UX — popover **Comment** + **Ask** actions, region-drag gesture,
   margin markers, reply badge + notification.
3. Annotations sidebar — 4 tabs + search, folding in the existing outline.
4. `get_pages` range tool.

## Open question

- **MCP port override** in Preferences vs. hardcoding `8082` (cosmetic).

## Sources

- Codex MCP config: <https://developers.openai.com/codex/config-reference>
- Swift SDK: <https://github.com/modelcontextprotocol/swift-sdk>
