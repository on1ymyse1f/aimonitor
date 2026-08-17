# Privacy

Privacy is a first-class feature of AI Monitor Station, not a policy page.

## What is read

| Collector | Reads | Never reads |
|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` — usage blocks, timestamps, model, request ids, session ids | prompt text, response text, file contents you edited |
| Codex CLI | `~/.codex/sessions/**/rollout-*.jsonl` — token counters, embedded `rate_limits`, session id and cwd from the meta line | `auth.json`, OAuth tokens, any credential |

The parser pre-filters log lines by accounting keywords (`"usage"`,
`"token_count"`) **before JSON parsing**. Content lines — the bulk of every
log — are never parsed at all.

## What is stored

One SQLite database at `~/Library/Application Support/AIMonitor/aimonitor.db`
containing token counts, costs, timestamps, model names, project slugs, session
and request ids, quota snapshots, file checkpoints, and settings.

The events table has no column for prompt or response content, by design.

## What never happens

- No telemetry, no analytics, no crash reporting
- No user account
- No network requests of any kind (there is no network code in this build)
- No credential storage (nothing is stored in Keychain because nothing needs to be)
- No browsing history collection

## Your controls

- **Retention**: 7 / 30 / 90 days (default), 1 year, or forever — in the app's
  Privacy page. Old events are deleted when retention is applied.
- **Delete everything**: one click in the Privacy page removes all events,
  quota snapshots, and checkpoints. The next sync re-reads logs from scratch.
- **Inspect**: `sqlite3 ~/Library/Application\ Support/AIMonitor/aimonitor.db` —
  the schema is plain and documented in `EventStore.swift`.
