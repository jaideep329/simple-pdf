# Agent Notes

Simple PDF hosts an in-process HTTP MCP server named `simple-pdf` when the macOS
app is running.

Discovery files:

- `~/Library/Application Support/SimplePDF/mcp-endpoint.json`
- `~/Library/Application Support/Simple PDF/mcp-endpoint.json`
- `~/Library/Application Support/TheReader/mcp-endpoint.json`
- `~/Library/Application Support/the-reader/mcp-endpoint.json`

The endpoint JSON keeps the stable minimal shape:

```json
{"url":"http://127.0.0.1:8082/mcp","token":"tr-mcp-9f47c2a8e1b6d530"}
```

Use the same directory's `mcp-discovery.json` for tool names and HTTP details,
or `mcp-codex.toml` for a Codex config snippet.

Useful MCP tools:

- `get_current_page`
- `get_page`
- `get_pages`
- `get_selection`
- `list_recent_selections`
- `list_highlights`
- `open_at_page`
- `search`
- `list_comments`
- `get_comment`
- `add_comment`
- `reply_to_comment`
- `resolve_comment`
- `reopen_comment`
