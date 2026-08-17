# aimonitor — AI Monitor Station

Local-first usage monitor for AI coding tools on macOS. Reads the logs your
tools already write, keeps a private SQLite history, and answers: how much AI
am I using, what would it cost at API list price, and how much quota is left.

Every figure carries a confidence marker:

| Marker | Meaning |
|---|---|
| `exact` | Read from the provider's own accounting, no lossy arithmetic, every record had a provider-assigned identity to fold on. |
| `est.` | Reconstructed from logs. The specific caveat is printed next to it. |
| `n/a` | Not derivable from anything on this machine. Reported as absent — never as zero, because a zero is a claim. |

## Run it

```bash
swift build -c release

# one-shot report (full scan, the independently-verified path)
swift run aimonitor
swift run aimonitor --since 7
swift run aimonitor --json

# persistent mode
swift run aimonitor-menubar   # menu bar: syncs when logs change, reads SQLite
swift run aimonitor-app       # SwiftUI dashboard: today, usage, flow, quotas, timeline, models, privacy
```

The menu bar app is the steady state: it fingerprints the log directories every
15 s (stat calls only), syncs incrementally when they change, and renders from
SQLite in milliseconds. A full historical scan happens once ever; after that,
only new bytes are parsed.

**Run the probe first** (`swift run aimonitor-probe`) — it prints the key paths
present in your real logs (never values) so format drift is visible before any
number is trusted.

## Architecture

```
~/.claude/projects/**/*.jsonl ─┐
                               ├─ Collectors ─ Normalization ─ SyncEngine ─▶ SQLite ─▶ StoreReport ─▶ menu bar / dashboard
~/.codex/sessions/**/rollout ──┘   (needles,    (TokenBreakdown,  (checkpoints,   (events, quota_      (read-only
                                    no content   provider-neutral  atomic per file, snapshots,         queries)
                                    parsing)     confidence)       restart-safe)    settings)
```

- **AIEvent** — the normalized record. Accounting and metadata only; prompt and
  response text never enter the pipeline.
- **Dedup is enforced by the schema**: Claude Code's progressive snapshots share
  a `requestId` and the store keeps the largest; Codex delta events carry
  positional ids that make replays no-ops.
- **Checkpoints** make collection restart-safe: per-file offset + the Codex
  session's last cumulative snapshot, committed atomically with the events.
- **Burn-rate engine** projects quota exhaustion from observed snapshots, only
  with enough observation spread; no prediction is shown otherwise.
- See [ARCHITECTURE.md](ARCHITECTURE.md), [PRIVACY.md](PRIVACY.md),
  [SECURITY.md](SECURITY.md), [docs/OPEN_SOURCE_RESEARCH.md](docs/OPEN_SOURCE_RESEARCH.md).

## What each provider gives up

| | Tokens | Quota | API-equivalent cost | Amount billed |
|---|---|---|---|---|
| Claude Code | est. (never exact — see below) | n/a | est. | n/a |
| Codex CLI | exact / est. | exact (from logs) | n/a | n/a |
| Cursor | n/a | n/a | n/a | n/a |

**Claude Code tokens are never labelled exact.** `input_tokens` in these
transcripts is a tiny residual (77% of requests report ≤ 2) because new content
lands in `cache_creation`; upstream (anthropics/claude-code#28197) disputes the
field's meaning. The reading that makes totals complete can't be proven from
local logs, so the figure stays `estimated` permanently.

**Codex needs no credentials.** `rate_limits` rides inside the `token_count`
events in `~/.codex/sessions/**/rollout-*.jsonl`. `auth.json` and OAuth refresh
are never touched.

**Codex cost is absent.** No verified OpenAI rate card ships here; a guessed
rate would still add up, so there is no Codex cost figure.

**Cursor is deliberately absent** — it writes no comparable local accounting;
a number that means something different from its neighbours is worse than none.

## The format traps (each has a named test)

1. **Codex counters are cumulative per session** — summing snapshots overcounts
   quadratically; the collector folds deltas, immune to duplicate events.
2. **The providers disagree about "input tokens"** — Codex's is inclusive of
   cache reads, Claude Code's exclusive. Both normalize into `TokenBreakdown`.
3. **Claude Code repeats one request across several records** — progressive
   streaming snapshots (2 → 783 tokens within one id). The fold keeps the
   largest, order-independent, enforced in SQL.
4. **Cache writes have two prices** — 1h TTL bills at 2×, 5m at 1.25×.
   Collapsing them understated this machine's cost by 17.5%.
5. **Reasoning tokens are a subset of output** — carried for visibility,
   excluded from every sum.
6. **Codex cache writes have no TTL** — recorded as `unspecified`, and any cost
   resting on them says so.

## Cost is not a bill

`apiEquivalentCostUSD` is list price of equivalent API usage — a comparison
figure, not an invoice. Actually-billed is not derivable from local logs and
always reports `n/a`.

## Verification

- 48 tests, one per trap plus store/dedup/incremental/burn-rate suites.
- Both collectors were cross-checked against independent Python
  reimplementations over the same real logs — digit-for-digit agreement.
- The incremental store path was cross-checked against the full-scan report on
  a frozen snapshot of the real logs: **identical for every field of both
  providers** (Claude 165,651,473 tokens; Codex 16,675,098,630).
- An earlier "window exceeds whole" paradox turned out to be the logs growing
  while being read; `--claude-root/--codex-root` accept frozen snapshots for
  reproducible comparisons.

## Performance

| | before | after |
|---|---|---|
| Full scan, 2.4 GB logs (release) | 37 s, 4.05 GB peak RSS | 24 s, **144 MB** peak RSS |
| Steady-state menu-bar refresh | full rescan every 60 s | **0.03 s** when unchanged; parses only new bytes when changed |

Two changes made this: a chunk-level `autoreleasepool` (Foundation objects from
`JSONSerialization` otherwise pile up until process exit), and substring needle
filtering that skips content lines before JSON parsing. Checkpoints make the
steady state independent of history size.

## Layout

```
Sources/AIMonitorCore/
  Confidence.swift          exact / est. / n/a contract, worst-wins combining
  Models.swift              TokenBreakdown, QuotaWindow, ProviderReport
  Pricing.swift             verified Anthropic rates, cache multipliers
  JSONL.swift               streaming reader: needles, offsets, autoreleasepool
  CodexCollector.swift      cumulative counters, quota from rate_limits
  ClaudeCodeCollector.swift streaming-snapshot fold, cache TTL split, cost
  Aggregator.swift          provider composition; Cursor unavailable-with-reason
  Report.swift              text and JSON rendering
  AIEvent.swift             the normalized event record
  Database.swift            minimal SQLite wrapper (WAL)
  EventStore.swift          schema, migrations, dedup, checkpoints, analytics
  SyncEngine.swift          incremental, restart-safe log → store sync
  BurnRate.swift            quota exhaustion projection (or silence)
  StoreReport.swift         read models for menu bar + dashboard
Sources/aimonitor/          CLI (full scan; --sync for the store path)
Sources/aimonitor-probe/    format probe (key paths only, no values)
Sources/aimonitor-menubar/  status-bar app, store-backed
Sources/aimonitor-app/      SwiftUI dashboard: today / usage / flow / quota /
                            timeline / models / privacy
Tests/                      48 tests incl. fixtures per trap
```

## Not built (deliberately)

Browser extension, local API proxy, and a process-level collector are not here.
The `source` field, dedup, and normalization layer exist precisely so those can
land later without silently changing historical numbers. There is no network
listener, no keychain use, and no telemetry anywhere in this build.
