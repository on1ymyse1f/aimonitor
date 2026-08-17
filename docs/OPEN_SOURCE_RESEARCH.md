# Open-source research

What similar tools exist, what they do well, and what AI Monitor Station does
differently. Licenses as published on each repository at review time (Aug 2026)
— re-check before reusing any code. No code was copied from any of these.

## Reviewed

### soulduse/ai-token-monitor — MIT
Lightweight tray app (Tauri, Rust) reading the same Claude Code / Codex JSONL
paths, with per-model pricing, 5h/weekly plan bars, webhooks, and an opt-in
leaderboard.
- **Useful ideas**: zero-config log discovery; tray-first design; cache-hit
  ratio visualisation.
- **Limitations**: documents only "deduplicates entries" with no specifics; no
  1h/5m cache-write price split; Rust/Tauri, not native macOS.
- **Reusable code**: MIT, but nothing taken — the formats were verified from
  live logs here instead.
- **We do differently**: schema-enforced dedup with order-independent fold;
  cache TTL price split; confidence labels on every number.

### juliantanx/aiusage — see repo for license
Node.js local-first tracker covering 20+ tools with a local web dashboard and
optional sync/leaderboard.
- **Useful ideas**: broad parser coverage; project-level breakdown; local web
  UI served on demand.
- **Limitations**: requires Node and a browser tab; quota pressure is derived,
  not read from provider data.
- **We do differently**: native SwiftUI, no runtime dependencies, quota read
  from provider-written `rate_limits`.

### niederme/ai-quota — MIT with Commons Clause (no commercial use)
Polished native macOS menu-bar app with dual-arc gauges, widgets, notifications,
and Claude usage-credit handling. Gets quota via OAuth/web sessions rather than
logs.
- **Useful ideas**: dual-window gauge language; honest "unavailable" states;
  adaptive refresh that backs off when idle.
- **Limitations**: requires signing into provider accounts (OAuth or WebKit
  sessions); Commons Clause blocks commercial reuse.
- **We do differently**: read-only, credential-free quota from logs; no sign-in
  flow at all.

### yagcioglutoprak/AIQuotaBar — see repo
Menu-bar quota app that auto-detects Claude/ChatGPT/Cursor/Copilot sessions
from installed browsers.
- **Useful ideas**: multi-browser session detection; compact menu-bar language.
- **Limitations**: reading browser cookies/sessions is brittle and invasive;
  no token accounting, only quota.
- **We do differently**: never touch browser state.

### ccusage — (web research, earlier pass)
The most-used token tracker; LiteLLM-sourced pricing, Codex support.
- **Useful ideas**: pricing registry discipline; daily bucketing.
- **Limitations**: tracks cache creation/read separately but not the two
  ephemeral TTLs (a 17.5% cost error on this machine's logs); CLI/TUI only.

### tokcat — (earlier pass)
Swift menu-bar app covering 10 clients including Cursor.
- **Useful ideas**: Cursor coverage is genuinely ahead of this build.
- **Limitations**: no documented requestId dedup or cache-TTL pricing.

### TokenEater, hamed-elfayome/Claude-Usage-Tracker, rjwalters/claude-monitor
— (earlier pass) Single-provider Claude menu-bar/CLI trackers. Useful as UI
references; none address cross-provider normalization.

## Spec-listed but not located/reviewed

`headroomlabs-ai/tokview`, `I-N-SILVA/NOTCHYLIMIT`, `658jjh/claude-usage-tracker`,
`she-llac/claude-counter` — not found in searches run for this document. If they
resurface, evaluate: dedup strategy, cache-TTL pricing, license.

## The two gaps nobody documents

Across everything reviewed, two things were never documented: **deduplication
of Claude Code's progressive streaming snapshots by `requestId`**, and the
**1-hour vs 5-minute cache-write price split**. On this machine's logs those
omissions are worth 55% (over-count) and 17.5% (under-cost) respectively —
which is why this project exists.
