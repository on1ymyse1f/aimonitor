# Security

## Threat model

AI Monitor Station reads local AI tool logs and writes one local SQLite file.
The assets at risk are: your usage history, your provider credentials, and the
integrity of the tools being monitored.

## What this build does

- **No network listener.** There is no local server, proxy, or IPC endpoint in
  this build, so there is nothing to bind to 127.0.0.1, nothing to
  authenticate, and nothing for a malicious webpage to forge events against.
  When the proxy and browser-extension collectors are added, they must bind to
  loopback only, authenticate extension messages with a per-install secret, and
  validate every payload — those requirements are recorded here so they are
  designed-in, not bolted on.
- **No credential access.** Codex quota data is read from the logs Codex
  already writes (`rate_limits` inside `token_count` events). `auth.json` is
  never opened; no OAuth flow is triggered; active CLI sessions cannot be
  invalidated by this tool.
- **No MITM, no root certificates, no traffic decryption.** Usage accounting
  comes from logs, not from intercepting TLS.
- **SQL injection**: all queries use prepared statements with bound parameters.
- **Log parsing is defensive**: malformed lines are skipped (logs truncate
  mid-write when a tool exits), unknown fields are tolerated, and one bad file
  increments `filesFailed` instead of crashing the sync.
- **Least privilege**: the app needs no Accessibility permission, no Full Disk
  Access, no admin rights — it reads two directories the user owns and writes
  one directory in Application Support.

## Supply chain

Zero external dependencies. The only linked library is the system `libsqlite3`.
There is nothing to audit upstream of this repository except Swift itself.

## If you find a vulnerability

Open an issue or contact the maintainer directly. Do not post token values or
log contents — the probe (`aimonitor-probe`) prints key paths only, which is
usually enough to describe a format problem.
