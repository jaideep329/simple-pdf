# Simple PDF — Project Context

Native macOS PDF reader for studying technical books/papers, built so you read +
annotate in the app while your **coding agent** (Codex / Claude Code) reads and
answers over an in-process **MCP server**. Thesis: the reader is a **capture +
navigation** surface; the **agent** does the reasoning (with full context via
MCP); **Obsidian** is the long-term memory. The app is not a chat client and
does not embed an LLM.

- Repo folder: `the-reader`; GitHub: `jaideep329/simple-pdf` (private).
- App display name **Simple PDF**, executable `SimplePDF`, bundle id
  `com.jaideepsingh.simplepdf`.
- SwiftUI + AppKit + PDFKit. Deploy target **macOS 13**; developed/run on macOS 26
  (Liquid Glass APIs are availability-gated to `macOS 26`).
- Git author: `Jaideep <jaideep329@gmail.com>`.

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
- **14 tools**: `get_current_page`, `get_page`, `get_pages`, `get_selection`,
  `list_recent_selections`, `list_highlights`, `open_at_page`, `search`,
  `list_comments`, `get_comment` (returns thread + anchored page text; region
  anchors also return a PNG **image block**), `add_comment`, `reply_to_comment`,
  `resolve_comment`, `reopen_comment`. `list_comments` strips the base64 image.

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
  Liquid Glass segmented switcher with a sliding selected pill.
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

## Known gaps / open items

- ⌘Z undo relies on `pdfView.undoManager`; verify it actually fires (PDFView
  responder can be finicky). Fallback would be a dedicated undo manager / Edit
  menu command.
- Permission allowlist (Claude Code) for the user's read-only CLI commands was
  discussed but not applied (belongs in user settings, not this repo).
- Next planned work is the **experimental agent-CLI feature** — see `plan.md`.
