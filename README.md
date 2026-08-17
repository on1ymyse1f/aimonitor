# aimonitor

Local usage monitor for AI coding tools. Reads logs the tools already write, and
states how much each number is worth.

Every figure carries a confidence marker:

| Marker | Meaning |
|---|---|
| `exact` | Read from the provider's own accounting, no lossy arithmetic, every record had a provider-assigned identity to fold on. |
| `est.` | Reconstructed from logs. The specific caveat is printed next to it. |
| `n/a` | Not derivable from anything on this machine. Reported as absent — never as zero, because a zero is a claim. |

## Run it

```bash
swift build
swift run aimonitor-probe    # confirm the log formats still match the parsers
swift run aimonitor          # the report
swift run aimonitor --since 7
swift run aimonitor --json
```

The menu-bar front end (`swift run aimonitor-menubar`) puts the tightest quota
and the reconstructed cost in the status bar, with the breakdown in its menu.

**Run the probe first.** A parser that finds nothing reports zero, and zero looks
like a light usage day rather than a broken parser. The probe prints the *key
paths* present in the real logs — never values — so format drift is visible
before any number is trusted.

## What each provider gives up

| | Tokens | Quota | API-equivalent cost | Amount billed |
|---|---|---|---|---|
| Claude Code | est. (never exact — see below) | n/a | est. | n/a |
| Codex CLI | exact / est. | exact | n/a | n/a |
| Cursor | n/a | n/a | n/a | n/a |

**Claude Code tokens are never labelled exact.** `input_tokens` in these
transcripts is very small — 77% of requests report ≤ 2 — because Claude Code
caches aggressively: each turn's new content is written to cache and counted under
`cache_creation`, leaving only a residual as plain input. Measured on the
reference logs, fresh input totals 95.9K against 7.98M cache-write tokens, and
the field is constant across every snapshot of a request (360/360), so it is not
a value that later fills in. That reading makes the totals complete. But
[claude-code#28197](https://github.com/anthropics/claude-code/issues/28197)
describes the same field as a streaming placeholder that never receives its final
count, which would mean some real input is unaccounted for. Local logs cannot
settle which reading is right, so the total stays an estimate. Any error is
bounded by the fresh-input term — the smallest component of the total.

**Codex needs no credentials.** Codex embeds a `rate_limits` object inside the
`token_count` events it already writes to `~/.codex/sessions/**/rollout-*.jsonl`
— used percentage, window size, and reset time. Reading `auth.json`, refreshing
an OAuth token, or risking the user's live CLI session is unnecessary for the
headline numbers, so none of that is done.

**Cursor is deliberately absent.** It does not write per-request token accounting
locally in a form comparable to the other two; its usage history sits behind a
team admin API. A Cursor row would be a number that means something different
from its neighbours, so it reports `unavailable` with the reason instead.

**Codex cost is absent.** Only Anthropic rates are verified and shipped. A
guessed OpenAI rate would still add up, so there is no Codex cost figure.

## The format traps

Both log formats mislead a naive reader, in different ways. Each trap below is
covered by a named test.

**1. Codex counters are cumulative per session.** `total_token_usage` accumulates
across the session, so summing the snapshots overcounts quadratically. The
collector reads the final snapshot, or sums per-event deltas when a time window
is requested. Deltas are immune to the duplicate `token_count` events this format
emits, because a duplicate repeats an identical cumulative value and so
contributes zero.

**2. The two providers disagree about "input tokens".** Codex's `input_tokens` is
*inclusive* of `cached_input_tokens` (verified: `input + output == total`, and
`cached <= input`). Claude Code's is *exclusive* — cache reads live in a separate
field. Summing the raw fields would add a number that includes cache reads to one
that excludes them. Both collectors normalize into `TokenBreakdown`, where
`uncachedInput` never includes cache reads for either provider.

**3. Claude Code repeats one request across several records.** Records sharing a
`requestId` are progressive snapshots of one streaming message: input and cache
figures hold steady while output grows (2 → 783 tokens observed). On the logs this
was built against, 690 of 1261 records were such repeats — summing lines
over-reported by more than half. The fold keeps the *largest* snapshot rather than
the last, which makes the total independent of the order files are traversed in.

**4. Cache writes have two prices.** `cache_creation` splits into
`ephemeral_1h_input_tokens` and `ephemeral_5m_input_tokens`, billing at 2× and
1.25× the input rate. Live data here is 92% 1h. Collapsing them into the flat
`cache_creation_input_tokens` field and applying 1.25× understated the cost of
this machine's history by **$53.09 on $303.88** — 17.5%.

**5. Reasoning tokens are a subset of output, not an addition.** They are carried
for visibility and excluded from every sum.

**6. Codex reports cache writes with no TTL.** Rather than filing them under 5m
and pricing them at 1.25×, they land in `cacheWriteUnspecified` and any cost
resting on them is disclosed.

## Cost is not a bill

`apiEquivalentCostUSD` is the list price of equivalent API usage. A subscription
plan does not bill per token, so it is a comparison figure, not an invoice. The
amount actually billed is not derivable from local logs and always reports `n/a`.

Web search and web fetch requests bill per request rather than per token. They are
counted and disclosed but excluded from the cost figure, for the same reason
Codex has no cost: no verified per-request rate ships here.

Unpriced models (including `<synthetic>`, which is locally generated) have their
tokens counted and their cost excluded, and are named in the report.

## The logs move while you read them

An agent session appends usage records as it works, so two runs seconds apart
legitimately differ — during development, one run's record count grew from 1261
to 1285 in three minutes. To compare runs, freeze the logs and point the tool at
the copy:

```bash
cp -R ~/.claude/projects /tmp/snap-claude
cp -R ~/.codex/sessions  /tmp/snap-codex
swift run aimonitor --claude-root /tmp/snap-claude --codex-root /tmp/snap-codex
```

## Verification

- 31 tests, one per trap above, `swift test`.
- Both collectors were cross-checked against independent Python reimplementations
  over the same real logs. Claude Code agreed digit for digit
  (150,408,007 billable-equivalent tokens, $303.88, 571 unique requests from 1261
  records); Codex agreed digit for digit (16,675,098,630 billable-equivalent, one
  counter reset across 115 sessions).
- Cost golden values were computed independently before being asserted in Swift.
- The windowed-vs-whole subset invariant was confirmed against a frozen snapshot.

## Layout

```
Sources/AIMonitorCore/
  Confidence.swift          the exact / est. / n/a contract, worst-wins combining
  Models.swift              TokenBreakdown, QuotaWindow, ProviderReport, ScanStats
  Pricing.swift             verified Anthropic rates, cache multipliers, fast mode
  JSONL.swift               streaming reader + drift-tolerant accessors
  CodexCollector.swift      cumulative counters, quota from rate_limits
  ClaudeCodeCollector.swift streaming-snapshot fold, cache TTL split, cost
  Aggregator.swift          provider composition; Cursor's unavailable-with-reason
  Report.swift              text and JSON rendering
Sources/aimonitor/          CLI
Sources/aimonitor-probe/    format probe (key paths only, no values)
Sources/aimonitor-menubar/  status-bar front end
```

## Not built

Proxy interception, browser-extension collection, and a process-level collector
are not here. The dedup and normalization layer is built and tested now precisely
so those can land later without silently changing every historical number.
