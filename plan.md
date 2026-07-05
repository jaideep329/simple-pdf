# Plan — Answer comments with a local coding agent (experimental)

> Build on branch **`experimental/agent-cli`**. This is opt-in/experimental and
> must be **cleanly separable** (isolated module + feature flag) so it can be
> added or removed without touching or slowing the rest of the app. Read
> `CLAUDE.md` first for the shipped state.

## Goal

In each comment thread, add an inline way to answer using a **local CLI agent** —
**Claude Code** or **Codex** — instead of (or in addition to) the MCP pull flow.
Two buttons in the thread panel: **Answer with Claude Code** / **Answer with
Codex**. Each thread keeps a per-engine **session id**. Running an engine spawns
the local CLI headless + read-only, streams a "thinking…" state, and appends the
**final answer as an agent message** in the thread (reusing the existing thread
UI). One conversation per thread.

## Confirmed decisions (do exactly these — no extra variants)

1. **Both engines** from the start: Claude Code and Codex.
2. **Read-only** always (no writes, no approvals — must not hang on a prompt).
3. **Working directory = a dedicated neutral scratch dir the app owns**
   (`~/Library/Application Support/SimplePDF/agent/`), the **same for all runs** —
   NOT the PDF's folder, NOT a project. Create it on first use. Rationale: a
   process always has a cwd; "projectless" just means the folder carries no
   context, so we keep a clean neutral home and put content in the prompt.
4. **Prompt carries the content**: the comment thread messages so far + the
   **anchored page text** (+ the region **PNG for Claude only**) + the PDF's
   **absolute path and page number** (so the agent can reference/read it in
   read-only mode if needed). For "whole chapter" asks, include a wider page
   range via the existing `mcpPages`.
5. **Session strategy (single behavior, with fallback):**
   - If a valid session id exists for `(thread, engine)` → **resume** (send only
     the new message).
   - Else → **replay the stored thread** as the prompt (we already persist the
     thread; that IS our history — no new storage).
   - Store only the **session id per engine** on the thread; never the raw
     transcript. Claude resumes reliably; Codex is best-effort (capture may fail
     → replay).
6. **Final answer appended as an agent message** in the thread (with a
   thinking/running state). Do **not** render the raw CLI transcript.
7. **Engine chosen per answer**; the thread records which engine produced each
   answer. Region PNG → Claude only; Codex gets page text (note it in the UI).
8. **Isolated module + feature flag**, background spawn, off the hot path.
9. **CLI must be installed + authenticated.** Spawn via a login shell to get
   PATH; if `claude`/`codex` is missing or unauthenticated, show a clear error
   **in the thread**, don't hang.
10. **One run per thread at a time** (disable buttons while running), with
    **cancel** and a **timeout**.

## CLI specifics (verified)

**Claude Code (clean fit):**
- `claude -p "<prompt>" --output-format json` → JSON incl. `result` and
  `session_id`. `-p` skips the workspace-trust dialog.
- Set your own id with `--session-id <uuid>`; resume with `--resume <id>`.
- Read-only: restrict permissions (e.g. `--permission-mode plan`, or an allowlist
  that grants no writes/exec). Confirm exact read-only flag when implementing.
- Region image: pass the PNG as a file path referenced in the prompt (write the
  snapshot to the scratch dir first).

**Codex (fiddlier):**
- `codex exec "<prompt>"` non-interactive; `codex exec resume <SESSION_ID>
  "<prompt>"` to resume; `--json` → JSONL event stream (parse the final
  assistant message).
- Read-only via config override: `-c 'sandbox_mode="read-only"'` (note:
  `exec resume` rejects `-s`/`-C`; use `-c`).
- **Session-id capture is unreliable** in non-interactive mode
  (openai/codex#3817). Best-effort: parse it from the `--json` stream or the
  rollout file under `~/.codex/sessions/`; if we can't get one, fall back to
  replay next turn.
- The neutral scratch dir may be "untrusted"; read-only `exec` should still run —
  if it balks, add that one dir to trusted config.

## Suggested shape (keep it small)

- **Module**: `Sources/TheReader/AgentCLI/`
  - `AgentEngine` protocol: `answer(prompt, sessionId?, workingDir, imagePath?) ->
    (text, newSessionId?)` streaming progress; plus `isAvailable`.
  - `ClaudeCodeEngine`, `CodexEngine` implementing it (subprocess via `Process`,
    login shell, read-only flags, JSON/JSONL parsing).
  - `AgentRunner` / coordinator: builds the prompt from a `CommentThread` +
    anchored page text/image, runs on a background queue, timeout + cancel,
    reports state, and calls back to append the answer via
    `ReaderStore.replyToComment(..., author: .agent, agentName: "Claude Code" |
    "Codex")`.
  - A **feature flag** (build config or a simple constant) gating all of it.
- **Data model**: extend `CommentThread` minimally with a per-engine session map,
  e.g. `agentSessions: [String: String]` (engine → sessionId). Backward-compatible
  (decode-optional) so existing sidecar files still load.
- **Prompt building**: reuse `ReaderStore.mcpPageInfo` / `mcpPages` for page text
  and the thread's messages; write region PNG to the scratch dir for Claude.
- **UI**: in `CommentThreadPanel`, add the two answer buttons + a running/cancel
  state + inline error. Attribute the resulting agent message to the engine.

## Sequencing

1. Module skeleton + feature flag + `Process` runner (login shell, read-only,
   timeout, cancel) with `isAvailable` checks.
2. `ClaudeCodeEngine` (settable `--session-id`, JSON result) end-to-end: button →
   run → append answer → store session id.
3. `CodexEngine` (`exec` / `exec resume`, `--json`, read-only override,
   best-effort id capture → replay fallback).
4. Prompt assembly (thread + page text + PDF path/page; region PNG for Claude).
5. Thread-panel UI: buttons, thinking/cancel state, per-engine session display,
   error surfacing.

## Risks / watch-outs

- Read-only enforcement + no interactive approval (else the subprocess hangs).
- Codex session-id capture; degrade to replay gracefully.
- Latency (seconds–minutes): never block the UI; stream/cancel/timeout.
- PATH/auth: handle missing or logged-out CLIs with an in-thread error.
- Keep it fully isolated so it can be reverted with no impact on the core app.
