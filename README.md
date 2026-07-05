# Simple PDF

A native macOS PDF reader for studying technical books and papers — built on
the idea that **the reader is a capture + navigation surface, and your coding
agent does the reasoning**. You read, highlight, and comment in the app; your
agent (Claude Code, Codex, or anything that speaks MCP) reads the same book
through an in-process **MCP server** and answers your questions right inside
the comment threads.

No embedded LLM, no chat client, no cloud. The app talks to agents you already
run locally.

## Features

- **Read & annotate**: highlights and sticky notes are written into the PDF as
  standard annotations; per-document page/zoom restore; recents; deep links
  (`simplepdf://open?path=…&page=…&quote=…`); cited-quote and deep-link copy
  from the selection popover.
- **Comment threads**: anchor a comment to selected text or a drawn region
  (region drags capture a PNG snapshot). Threads live in a sidecar JSON file —
  the PDF itself is never modified by comments. On-page markers jump to
  threads; agent replies badge the dock and mark threads unread.
- **MCP server** (in-process, loopback HTTP): 15 tools covering page text,
  search, selections, highlights, sticky notes, and full comment-thread
  read/write, so an agent can both *see* what you're reading and *reply* in
  your threads.
- **Answer with a local CLI agent** (experimental): buttons in each comment
  thread run Claude Code or Codex headless, stream the answer live into a
  draft bubble (token-level for Claude), resume per-thread sessions, and show
  a brief of the tools each answer used. Select an engine once and every
  message you send in that thread is answered automatically.
- **Sidebar**: Contents / Highlights / Notes / Comments tabs; the Contents tab
  searches chapter titles *and* the full book text.
- Liquid Glass UI on macOS 26, with graceful fallbacks down to macOS 13.

## Requirements

- macOS 13+ (the Liquid Glass visuals need macOS 26; everything works without)
- A Swift 5.9+ toolchain (Xcode or command-line tools)
- Optional, for the agent-answer buttons: [Claude Code](https://claude.com/claude-code)
  (`claude`) and/or [Codex](https://github.com/openai/codex) (`codex`)
  installed and signed in

## Build & run

```sh
swift build                  # compile
./script/build_and_run.sh    # debug build → .app bundle → launch
./script/package_dmg.sh      # release .app + DMG in dist/ (ad-hoc signed)
./script/install_app.sh      # build the DMG and install to /Applications
```

There is no unit-test suite; verification is running the app and hitting the
MCP server with `curl`. The DMG is ad-hoc signed for personal use — it is not
Developer ID signed or notarized for public distribution.

## Connecting your agent

The app hosts MCP at `http://127.0.0.1:8082/mcp` (server name `simple-pdf`)
whenever it is running.

**Claude Code**

```sh
claude mcp add --scope user --transport http simple-pdf http://127.0.0.1:8082/mcp \
  --header "Authorization: Bearer tr-mcp-9f47c2a8e1b6d530"
```

**Codex** — add to `~/.codex/config.toml` (the app also writes a ready-made
snippet to `~/Library/Application Support/SimplePDF/mcp-codex.toml`):

```toml
[mcp_servers.simple-pdf]
url = "http://127.0.0.1:8082/mcp"
http_headers = { Authorization = "Bearer tr-mcp-9f47c2a8e1b6d530" }
```

**Any other MCP client**: discovery files with the URL + token are written
under `~/Library/Application Support/SimplePDF/` (`mcp-endpoint.json`,
`mcp-discovery.json`) — see `AGENTS.md`.

### Tools

`get_current_page`, `get_page`, `get_pages`, `get_selection`,
`list_recent_selections`, `list_highlights`, `list_notes`, `search`,
`open_at_page`, `list_comments`, `get_comment` (region anchors return the
snapshot as an image block), `add_comment`, `reply_to_comment`,
`resolve_comment`, `reopen_comment`.

## Security notes — read before exposing anything

- The MCP server binds to **loopback only** and validates a bearer token, but
  the token is a **fixed constant compiled into the app** (visible in this
  repo and in the discovery files). It keeps casual local processes out; it is
  not real authentication — treat any local process as able to reach the
  server, and don't port-forward it.
- The app is **not sandboxed** by design: the loopback listener, free file
  access, and spawning agent CLIs depend on that.
- The in-app **Claude Code** runs are constrained to a read-only tool
  allowlist. The in-app **Codex** runs deliberately disable Codex's sandbox
  (`danger-full-access`, approvals off) because Codex cancels all MCP tool
  calls under any restricted sandbox — for Codex, "read-only" is enforced only
  by prompt instructions. If that trade-off isn't acceptable, don't use the
  Codex button (revert instructions are in
  `Sources/TheReader/AgentCLI/AgentEngines.swift`).

## Storage

| What | Where |
| --- | --- |
| Highlights & sticky notes | PDF annotations in the file itself (debounced save) |
| Comment threads | `~/Library/Application Support/SimplePDF/comments/<sha>.json` |
| View state, recents, bookmarks | `UserDefaults` |
| Agent scratch dir (cwd for CLI runs, region PNGs) | `~/Library/Application Support/SimplePDF/agent/` |

## Limitations

- Selectable-text PDFs only — **no OCR**; scanned/image-only PDFs are out of
  scope.
- Sidebar full-text search jumps to the page but doesn't select the match yet.
- Codex specifics: session resume is best-effort (falls back to replaying the
  thread), streaming is chunk-level, and region snapshots go to Claude only.
- Agent runs cap at 5 minutes, one per thread at a time.

## Architecture

SwiftUI + AppKit + PDFKit, one SwiftPM executable target. `ReaderStore` is the
central `ObservableObject`; `MCPService` hosts the MCP server over a
hand-rolled `Network.framework` HTTP/1.1 listener (using the official
[swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)'s stateless
transport); `AgentCLI/` is the isolated, feature-flagged agent-answer module.
`CLAUDE.md` documents the full layout, conventions, and trade-offs.

## License

[MIT](LICENSE)
