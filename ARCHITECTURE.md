# Architecture

AI Monitor Station is a Swift package with one library (`AIMonitorCore`) and
four front ends (`aimonitor` CLI, `aimonitor-probe`, `aimonitor-menubar`,
`aimonitor-app`). No external dependencies; SQLite comes from the system — the
SDK's `SQLite3` module on macOS, libsqlite3 on Linux and winsqlite3 on Windows
through the `CSQLite` system-library target. The library, the CLI and the probe
build on all three; the two GUI front ends are AppKit / SwiftUI and the
manifest includes them on macOS only.

## Windows front end

`Windows/AIMonitor.Windows` is a .NET WinForms tray app with a WebView2
dashboard. It contains no accounting logic. It starts `aimonitor agent` as a
child process and talks to it in JSON lines over stdin/stdout:

```
AIMonitor.exe ──stdin: {"cmd":…}──▶ aimonitor agent ── MonitorAgent ─▶ SyncEngine / EventStore
       ▲                                   │
       └──stdout: snapshot / notification ─┘    UISnapshot: every string the macOS
                                                 views show, already formatted
```

`MonitorAgent` is the macOS menu bar's and dashboard's loop without AppKit:
stat-gated sync every 15 s, the opt-in quota fetches with the same 15-minute
floor, and notifications at 80/90/100%. `UISnapshot` formats with the same
rules as the SwiftUI views (`StoreReport.compact`, `resetDescription`, the
pace text, day labels), so the Windows page only lays text out. The agent has
no socket; it exits when its stdin closes.

## Layers

```
Collectors ──▶ Normalization ──▶ SyncEngine ──▶ SQLite ──▶ StoreReport ──▶ UI
 (per-tool)    (TokenBreakdown)   (checkpoints)  (events)    (read models)
```

### Collectors

Independent and optional. Each knows one log format and nothing else. A failing
collector throws per file and the file is counted in `filesFailed`; it cannot
break the other collector. Adding a tool means adding one file that emits
`AIEvent`s — the store, dedup, analytics, and UI need no changes.

### Normalization

`TokenBreakdown` is the single place where provider conventions are reconciled:
Codex's inclusive `input_tokens` vs Claude Code's exclusive one, the two cache
TTL price classes, TTL-less writes, and reasoning-as-subset-of-output. Sums of
mixed-provider raw fields would be meaningless; sums of `TokenBreakdown` are not.

### The event model

`AIEvent` carries accounting only: timestamp, provider, model, session, project,
token breakdown, cost (nullable — never guessed), confidence. `source` is
`local_log` today; `api_proxy`, `browser`, `provider_usage`, `process`, and
`local_model` are reserved so future collectors land in the same pipeline.

### Dedup, enforced by the schema

- Claude Code events key on `requestId` (falling back to message id, then to a
  positional id). Streaming snapshots share the key; the store keeps the largest
  by `billable`, so totals are independent of insertion order.
- Codex events are per-event **deltas** with positional ids
  (`codex:<file>@<byteOffset>`) and `INSERT OR IGNORE` — replaying a log is a
  no-op by construction.

### Checkpoints and restart safety

Per file: `(size, offset, state)` committed in the **same transaction** as the
events it produced. A crash mid-file replays that file, and dedup makes the
replay harmless. Codex's cumulative counters resume from the snapshot stored in
`state`. A file that shrank is re-parsed from zero (rotation).

### Quota history and burn rate

Quota snapshots are appended (consecutive duplicates skipped), giving the
burn-rate engine a time series. A projection requires: ≥2 observations inside
the current window, a minimum observation spread scaled to the window size, a
positive observed burn, and exhaustion before reset. Otherwise silence.

### Deviation from the suggested repo layout

The spec sketched a directory-per-concern layout (`macOS/`, `Core/`,
`Collectors/…`). This build uses a single SwiftPM library with one file per
concern instead — the same boundaries at a fraction of the ceremony, and one
`swift build` produces everything. If the proxy and browser extension land, the
extension gets its own top-level `BrowserExtension/` directory (it is not Swift).

## Why no cloud anything

All state is one file: `~/Library/Application Support/AIMonitor/aimonitor.db`
(`%LOCALAPPDATA%\AIMonitor\aimonitor.db` on Windows).
There is no account, no sync, no network code path at all in this build.
