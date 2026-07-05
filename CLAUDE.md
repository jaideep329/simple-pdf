# Simple PDF — Project Context

Native macOS PDF reader for studying technical books/papers, built so you read +
annotate in the app while your **coding agent** (Codex / Claude Code) reads and
answers over an in-process **MCP server**. Thesis: the reader is a **capture +
navigation** surface; the **agent** does the reasoning (with full context via
MCP); **Obsidian** is the long-term memory. The app is not a chat client and
does not embed an LLM.

- Repo folder: `the-reader`; GitHub: `jaideep329/simple-pdf`.
- App display name **Simple PDF**, executable `SimplePDF`, bundle id
  `com.jaideepsingh.simplepdf`.
- SwiftUI + AppKit + PDFKit. Deploy target **macOS 13**; developed/run on macOS 26
  (Liquid Glass APIs are availability-gated to `macOS 26`).

## Build / run / install

- `swift build` — compile (SwiftPM). Package name `SimplePDF`.
- `./script/build_and_run.sh` — debug build → `.app` bundle → launch.
- `./script/package_dmg.sh` — release `.app` + DMG in `dist/` (ad-hoc signed).
- `./script/install_app.sh` — build DMG, quit running app, install to
  `/Applications/Simple PDF.app`, strip quarantine, verify signature. **This is
  how changes get tested** (there's no unit test suite; verification is by
  running the app + `curl` against the MCP server).
- App config in `script/app_config.sh`. Not sandboxed (no entitlements) — this is
  deliberate: it enables the loopback MCP server, free file access, and
  subprocess spawning.

## Dependency

- `modelcontextprotocol/swift-sdk` **0.12.1** (product `MCP`). Pulls SwiftNIO,
  swift-log, etc. transitively (used by the SDK, not directly by us).

## Source files (`Sources/TheReader/`)

- **`TheReaderApp.swift`** — `@main` App; window + menu commands (Open, Copy
  Quote/Link/Highlight/Add Note shortcuts, zoom). Injects `ReaderStore`.
- **`ReaderStore.swift`** — the core `ObservableObject`. Owns the `PDFDocument`,
  view state, recent files, outline, text selection + timestamped selection
  history, highlights/notes actions, **comment threads** (in-memory + persisted),
  undo registration, MCP data methods, and starts the MCP server. Also defines
  the Sendable DTOs (`MCPPageInfo`, `MCPHighlight`, `MCPSearchHit`, `NoteItem`,
  `SelectionEntry`, `AnnotationPlacement`).
- **`ReaderDocumentView.swift`** — top-level `NavigationSplitView`. Left =
  `SidebarView` (tabbed: Contents / Highlights / Notes / Comments + search, with
  a Liquid Glass `GlassTabSwitcher`); detail = PDF + optional trailing
  `CommentThreadPanel`. Toolbar (Open, page indicator, Add Note, region-comment
  toggle, zoom). Row views + `Color(hex:)` helper live here.
- **`PDFReaderView.swift`** — `NSViewRepresentable` wrapping `ReaderPDFView`
  (`PDFView` subclass). Selection popover (SwiftUI in `NSHostingView`), sticky
  note editor, **region-drag → PNG snapshot**, **on-page comment markers**,
  cursor handling. Coordinator observes selection/scale/page/scroll and
  repositions overlays.
- **`PDFDocumentStateStore.swift`** — per-document view state (page, zoom),
  recent PDFs, security-scoped bookmarks, in `UserDefaults`. `documentKey` =
  `SHA256(path)` prefix — the sharding key reused elsewhere.
- **`CommentStore.swift`** — comment model (`CommentThread`, `CommentMessage`,
  `CommentAnchor` [text|region, page, quote, bounds, region PNG base64],
  `CommentStatus`, `CommentAuthor`) + **sidecar JSON store** keyed by document
  SHA at `~/Library/Application Support/SimplePDF/comments/<key>.json`. The PDF
  is never mutated by comments.
- **`CommentThreadPanel.swift`** — trailing SwiftUI panel for one thread: anchor
  preview (quote or region image), you↔agent message bubbles (markdown),
  composer, resolve/close.
- **`MCPService.swift`** — in-process MCP server + `ReaderMCPBridge`
  (`@MainActor`) + the `Network.framework` loopback HTTP listener.
- **`AgentCLI/`** — isolated "answer a comment
  thread with a local CLI agent" module, all gated behind
  `AgentCLIFeature.isEnabled` (in `AgentCLI.swift`):
  - `AgentCLI.swift` — feature flag, `AgentEngineKind` (claude-code | codex;
    rawValue is the session-map key), `AgentAnswer`, `AgentCLIError`.
  - `AgentCLIProcess.swift` — subprocess runner: captures the login-shell PATH
    once (`zsh -l`), resolves the CLI binary, runs with timeout (SIGTERM →
    SIGKILL), Task-cancellation → SIGTERM, stdin = /dev/null so prompts fail
    fast instead of hanging. Optional `onStdoutLine` callback streams complete
    stdout lines as they arrive (readabilityHandler + line splitting).
  - `AgentEngines.swift` — `AgentEngine` protocol (with an `onPartial`
    streaming callback) + `ClaudeCodeEngine` (`claude -p … --output-format
    stream-json --include-partial-messages --verbose`, read-only via
    `--allowedTools Read,Glob,Grep` + disallow list, `--resume <id>`;
    `ClaudeStreamParser` accumulates `content_block_delta` text — reset at
    `message_start` so tool-use turns don't stick — and captures the final
    `result` event) and `CodexEngine` (`codex exec [resume <id>] --json
    --skip-git-repo-check -c 'sandbox_mode="read-only"'`; `CodexStreamParser`
    streams per-event — `agent_message[_delta]` / `item.completed`; final
    parse tolerates old `msg.*` and new `thread.started`/`item.completed`
    shapes; session id best-effort). Both parsers also collect **tool-call
    names** (Claude: `tool_use` blocks in completed assistant events, MCP as
    `mcp__server__tool`; Codex: shell / web search / `server: tool`,
    normalized) → `AgentAnswer.toolCalls`, streamed live via `onToolCall`.
  - `AgentCLIController.swift` — ObservableObject owned by `ReaderStore` (only
    when flag on): builds prompts (thread transcript + anchor page ±1 text via
    `mcpPages` + PDF path + MCP-first guidance; region PNG written to the
    scratch dir for Claude only), one run per thread, resume-else-replay with
    fallback (a failed resume replays the stored thread and drops the stale
    id), appends the answer via `replyToComment(author: .agent)`. **Sticky
    auto-answer**: `toggleAutoAnswer` persists an engine per thread;
    `ReaderStore.addHumanReply` → `humanReplyAdded` auto-runs it on every
    composer send (a reply landing mid-run queues exactly one follow-up run).
    Scratch cwd for all runs: `~/Library/Application Support/SimplePDF/agent/`.
  - Agents get PDF context **MCP-first**: `SimplePDFMCP` (in `AgentCLI.swift`)
    lists the server's read-only vs mutating tools; the prompt says MCP-first,
    PDF path as fallback. Claude gets the server attached explicitly via
    `--mcp-config` + `--strict-mcp-config` (it's not in user scope) with only
    read-only `mcp__simple-pdf__*` tools allowed, under a true read-only tool
    allowlist. **Codex runs with the sandbox OFF by explicit user decision**:
    codex 0.141 cancels every MCP tool call ("user cancelled MCP tool call")
    under any sandbox except `danger-full-access` — verified empirically
    (approval_policy=never, guardian off, workspace-write+network_access, and
    a stdio `mcp-remote` bridge all still cancel). Working MCP was chosen over
    sandbox enforcement, so `CodexEngine` passes
    `-c sandbox_mode="danger-full-access" -c approval_policy="never"` and
    Codex's read-only behavior is enforced **only by prompt instruction**. To
    revert: restore `sandbox_mode="read-only"` in `CodexEngine` and flip
    `AgentEngineKind.supportsMCP` back to Claude-only (comments at both sites).
  - `AgentAnswerBar.swift` — strip above the composer in `CommentThreadPanel`:
    sticky engine toggle buttons (select once → every sent message is
    auto-answered by that engine; click again to turn off), thinking + Cancel
    state, inline dismissible error. Also `AgentStreamingBubble`: a live draft
    bubble in the message list fed by `AgentCLIController.partialAnswers`
    (token-level for Claude, chunk-level for Codex), replaced by the real
    agent message when the run finishes.
  - `AgentEngineIcons.swift` — Claude/OpenAI brand marks as embedded SVG
    strings rendered via `NSImage` template images (the bundle script copies
    only the bare binary, so `Bundle.module` resources can't be used).
  - Data model: `CommentThread.agentSessions: [String: String]?` (engine →
    session id), `CommentThread.autoAnswerEngine: String?` (sticky engine),
    and `CommentMessage.toolCalls: [String]?` (names of tools used to produce
    an agent answer — rendered via `AgentToolCallBrief` as e.g.
    "Read ×2 · Highlights" under the message bubble and live in the draft
    bubble; the reader's own server prefix is dropped and its tool names get
    friendly labels, other servers render as "server: Tool"); all
    decode-optional so old sidecar files load.
- Comment threads can be **deleted permanently** (trash button + confirmation
  in `CommentThreadPanel`; `ReaderStore.deleteComment` also cancels any
  in-flight agent run) in addition to resolve/reopen.

## Storage model

- **Highlights & sticky notes** → standard PDF annotations written into the file
  (debounced `document.write`).
- **Comments** → sidecar JSON keyed by doc SHA (not in the PDF).
- **View state / recents / bookmarks** → `UserDefaults`.

## MCP server (shipped)

- In-process, **`StatelessHTTPServerTransport`** + a hand-rolled
  `Network.framework` HTTP/1.1 listener on **`127.0.0.1:8082`** (no SwiftNIO
  listener; the SDK only ships the transport). Server name **`simple-pdf`**.
- Auth: constant hardcoded bearer token **`tr-mcp-9f47c2a8e1b6d530`** +
  `OriginValidator.localhost`. **Idempotent `initialize`** (registered after
  `server.start`) so fresh Codex turns can handshake.
- Started from `ReaderStore.init`. Writes discovery files (`mcp-endpoint.json`,
  `mcp-discovery.json`, `mcp-codex.toml`) under several App Support dirs.
- Configured in `~/.codex/config.toml` as `[mcp_servers.simple-pdf]`.
- **15 tools**: `get_current_page`, `get_page`, `get_pages`, `get_selection`,
  `list_recent_selections`, `list_highlights`, `list_notes` (sticky notes —
  added so all three annotation kinds are agent-visible), `open_at_page`,
  `search`, `list_comments`, `get_comment` (returns thread + anchored page
  text; region anchors also return a PNG **image block**), `add_comment`,
  `reply_to_comment`, `resolve_comment`, `reopen_comment`. `list_comments`
  strips the base64 image.

## Features shipped

- **Selection popover** (Liquid Glass, in `NSHostingView`): Highlight · Copy
  Quote · Copy Link · Comment. Hover highlight, pointing-hand cursor. (The three
  copy/highlight actions were removed from the top toolbar.)
- **Timestamped selection history** (~100) → `get_selection` / "latest selection".
- **Highlights & sticky notes** (create, drag notes, inline note editor).
- **Comments**: text- or region-anchored threads; region drag captures a PNG.
  Ongoing you↔agent threads in a trailing panel; agent answers via MCP appear
  live. On-page markers (green when resolved) jump to a thread.
- **Tabbed sidebar** (Contents / Highlights / Notes / Comments) + search;
  Liquid Glass segmented switcher with a sliding selected pill. The search
  field filters the active tab's list; on **Contents** it additionally runs a
  debounced **full-text search of the book** (same `mcpSearch` engine as the
  MCP `search` tool) shown as an "In the book" section — rows jump to the page
  (they do not select/highlight the match on arrival yet).
- **Answer with a local CLI agent** (experimental, `AgentCLIFeature.isEnabled`):
  per-thread sticky engine buttons (Claude Code / Codex brand icons — select
  once, every composer message is auto-answered; click again to turn off),
  streamed draft bubble (token-level Claude, chunk-level Codex) with a live
  tool-call brief, per-engine session resume with replay fallback, cancel +
  5-minute timeout, inline errors, and a humanized tool-call brief persisted
  under each agent answer.
- **Comment deletion** (trash + confirmation in the thread panel) alongside
  resolve/reopen; deletion cancels any in-flight agent run.
- **Chat-style bubbles**: human messages right-aligned, content-hugging, flat
  accent + white text; agent messages left, gray; continuous corners with a
  4pt sender-side tail (macOS 13.3+ `UnevenRoundedRectangle`, plain rounded
  fallback).
- **Undo (⌘Z)** for adding highlights and notes (reversible ops on the PDF
  view's undo manager). Sticky-note typing undo is the text view's own.
- **Reply notifications**: agent replies mark threads unread → dock badge count +
  dock bounce when backgrounded + sidebar "New reply" badge; cleared on open.
- Per-document restore (page/zoom), recents, deep links (`simplepdf://open`),
  security-scoped bookmarks.

## Conventions / decisions

- **No OCR, ever** (scanned/image-only PDFs out of scope).
- Liquid Glass (`glassEffect`, `.buttonStyle(.glass)`, `pointerStyle`) gated
  behind `if #available(macOS 26.0, *)` with material/`borderless` fallbacks.
- Comment **`type`** (note/question) was intentionally dropped — every thread is
  just a comment.
- Highlight id = `SHA256(pageIndex + bounds)`; comment ids = UUID.
- MCP payloads are compact JSON returned as tool text; region images as image
  blocks.
- Sidebar highlights/notes are **cached against `annotationsRevision`**
  (`ReaderStore.sidebarHighlights/sidebarNotes`): the uncached walk extracts
  text per highlight (~80ms main-thread on a 370-page book) and these
  accessors are hit from SwiftUI `body` on every sidebar render.

## Known gaps / open items

- ⌘Z undo relies on `pdfView.undoManager`; verify it actually fires (PDFView
  responder can be finicky). Fallback would be a dedicated undo manager / Edit
  menu command.
- Permission allowlist (Claude Code) for the user's read-only CLI commands was
  discussed but not applied (belongs in user settings, not this repo).
- Agent-CLI trade-offs & caveats (module details above; original plan.md was
  implemented and removed):
  - **Codex runs unsandboxed** (`danger-full-access` + `approval_policy=never`)
    by explicit user decision so its MCP calls work; its read-only behavior is
    prompt-enforced only. Claude Code remains genuinely read-only (tool
    allowlist). Revert path documented at both code sites.
  - Codex session-id capture is best-effort → silently falls back to
    replaying the thread; Codex streaming is chunk-level and its tool-call
    log lags to call completion.
  - The streaming draft bubble does not auto-scroll the message list.
  - Codex-only regions: the anchor PNG goes to Claude only; Codex gets page
    text and a note in the prompt/help.
  - Runs are capped at 5 minutes (SIGTERM→SIGKILL); one run per thread at a
    time (a mid-run reply queues exactly one follow-up).
  - Sidebar "In the book" search results jump to the page but don't select
    the matched text on arrival.
