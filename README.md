# Simple PDF

A small native macOS study app for reading selectable-text PDFs, highlighting passages, adding PDF sticky notes, and copying cited quotes.

## Run

```sh
./script/build_and_run.sh
```

## Build an installable DMG

```sh
./script/package_dmg.sh
```

The generated disk image is written to `dist/Simple PDF-0.1.0.dmg`. It contains
`Simple PDF.app` and an Applications shortcut for normal drag-to-install use.
The local package is ad-hoc signed for personal installation, but it is not
Developer ID signed or notarized for public internet distribution.

## Install the latest build

```sh
./script/install_app.sh
```

This packages the latest release DMG, mounts it, replaces
`/Applications/Simple PDF.app`, verifies the installed app signature, and
detaches the DMG.

## Agent MCP discovery

When the app is running, it hosts a local HTTP MCP server named `simple-pdf` at
`http://127.0.0.1:8082/mcp`. The server exposes live reader state and commands:
`get_current_page`, `get_page`, `get_selection`, `list_recent_selections`,
`list_highlights`, `open_at_page`, and `search` — plus comment tools
(`list_comments`, `get_comment`, `add_comment`, `reply_to_comment`,
`resolve_comment`, `reopen_comment`) for the agent to read and answer the
threads you attach to passages.

On startup the app writes discovery files under all of these Application Support
directories so agents can find it by either app name or repo name:

- `~/Library/Application Support/SimplePDF/`
- `~/Library/Application Support/Simple PDF/`
- `~/Library/Application Support/TheReader/`
- `~/Library/Application Support/the-reader/`

Each directory contains:

- `mcp-endpoint.json` with the stable minimal `{ "url", "token" }` contract.
- `mcp-discovery.json` with server name, transport, auth header, protocol
  version, tools, and notes.
- `mcp-codex.toml` with a ready-to-copy Codex MCP config snippet.

## Current scope

- Open selectable-text PDFs with PDFKit.
- Select text in the PDF and copy it as a cited Markdown quote with chapter/page context when available.
- Select text and copy a Markdown link that reopens Simple PDF to the PDF page and searches for the selected text.
- Zoom, scroll, and move around the PDF using PDFKit controls and gestures.
- Navigate the PDF's built-in outline/bookmarks from a native sidebar when the PDF provides one.
- Highlight the active PDF selection and save the annotation into the opened PDF.
- Add inline sticky PDF notes that collapse to a small note icon and reopen when clicked.
- Reopen recent PDFs directly from local app state.
- Restore the last page and zoom mode for each PDF without writing that viewer state into the PDF.
- Store file bookmarks for opened PDFs so protected folders such as Downloads do not need repeated manual approval after the app has stable access.

## Storage Model

The PDF is the source of truth for document annotations. Highlights and sticky notes
are written as standard PDF annotations on the opened file. The app keeps only
viewer state, such as recent files, last page, and zoom mode, in local preferences.

OCR and Raindrop integration are intentionally out of scope for this first pass.
