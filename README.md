# Cachewatch

A macOS menu bar app that watches all your Claude Code sessions at once: live status, prompt-cache state with TTL countdowns, real quota usage, per-session memory, and the cost of waking a cold session — with notifications when something needs you.

Claude Code shows you one session at a time. If you run several in parallel, there is no view of which ones are waiting for input, which caches are about to expire, how much of your 5-hour/weekly quota is gone, or how much RAM that session you abandoned three days ago is still holding. Cachewatch is that view.

## What it shows

- **Session fleet** — every live session: project, git branch, model, status (idle / busy / **needs input**), ordered with input-starved sessions on top. The menu bar icon shows a count when sessions are waiting on you.
- **Cache state** — warm/cold per session with a live countdown to TTL expiry, read from the transcript's actual `ephemeral_5m` / `ephemeral_1h` cache buckets, not guessed.
- **Cost to resume** — cold sessions show the estimated price of the full-context rewrite your next prompt will pay (real dollars on API billing; a quota-weight proxy on a subscription).
- **Quota** — the server-reported 5-hour and weekly utilization with reset countdowns, from Claude Code's own statusline data. When a window resets while you're idle, the badge flips to "reset" on its own.
- **Memory** — RSS of each session's full process tree, MCP servers included.
- **Notifications** — quota crossing 80%, a big 5-minute-TTL cache about to die, heavy sessions idle for 6+ hours, and silent cache misses (a turn that paid a full rewrite when the cache should have been warm — the classic `--resume`/upgrade regression). Each fires once, survives app restarts, and each rule can be disabled.
- **Close session** — hover a row for a confirm-gated button that terminates that Claude Code process.

## How it works

No API calls, no tokens spent, no accounts. Cachewatch reads what Claude Code already writes locally:

| Source | Provides |
|---|---|
| `~/.claude/sessions/*.json` | Session discovery, pid, live status (PID-validated) |
| `~/.claude/projects/**/*.jsonl` | Per-turn tokens, cache read/write with TTL buckets, model, branch |
| Statusline forwarder (below) | Quota (`rate_limits`), cost, context %, per session |
| `ps` | Process-tree memory |

Everything flows into one reducer that produces an immutable fleet snapshot; the UI renders snapshots. State on disk is a single `state.json` (thresholds, fired-alert dedup) — delete it for a factory reset.

## Install

Requires macOS 15+ and Swift 6 (Command Line Tools are enough to build and run).

```sh
git clone <repo-url> cachewatch && cd cachewatch
swift run Cachewatch          # menu bar app
swift run Cachewatch dump     # one-shot fleet table in the terminal
```

### Statusline hookup (for quota/cost data)

Quota and cost come from the JSON Claude Code pipes to its statusline. Install the forwarder:

```sh
mkdir -p ~/.cachewatch && cp scripts/cachewatch-statusline.sh ~/.cachewatch/ && chmod +x ~/.cachewatch/cachewatch-statusline.sh
```

Then in `~/.claude/settings.json`:

```json
"statusLine": {
  "type": "command",
  "command": "~/.cachewatch/cachewatch-statusline.sh",
  "refreshInterval": 60
}
```

The script renders a compact statusline (`Opus 4.8 | ctx 73% | 5h 43% | 7d 12%`) and forwards the JSON to Cachewatch's local socket. If you already have a statusline you like, set `CACHEWATCH_NEXT_STATUSLINE` to its command and the script chains to it. If Cachewatch isn't running, forwarding is a silent no-op — your statusline never breaks or slows down. `refreshInterval` keeps the data fresh while sessions are idle; sessions pick the setting up on restart.

## Configuration

`~/Library/Application Support/Cachewatch/state.json`:

```json
{
  "alerts": {
    "notificationsEnabled": true,
    "quota":       { "enabled": true, "thresholdPercentage": 80 },
    "cacheExpiry": { "enabled": true, "warningSeconds": 90, "minContextTokens": 50000 },
    "longIdle":    { "enabled": true, "idleHours": 6, "minContextTokens": 100000, "minMemoryBytes": 500000000 },
    "cacheMiss":   { "enabled": true }
  }
}
```

## Caveats

- Session registry, transcript schema, and statusline JSON are undocumented Claude Code internals; they have changed without notice before and will again. Parsers are fixture-tested against real captured payloads and degrade per-field, but a Claude Code update can still break things — file an issue with a captured payload.
- The TTL countdown is a client-side expectation (last turn + TTL). The server documents refresh-on-read but not guaranteed retention; early eviction is possible.
- Cost figures use API list prices (`Sources/CollectorEngine/Pricing.swift`). On a subscription they are a proxy for quota weight, not money — Anthropic does not publish how token types weigh against Plan limits.
- Quota freshness is bounded by statusline renders (per turn + `refreshInterval` tick). The reset countdown and expired-window handling are pure local clock and stay correct regardless.

## Development

```sh
swift run cachewatch-tests    # test suite (plain-assertion runner; no Xcode required)
```

Engine logic lives in `Sources/CollectorEngine` (no UI imports); the app target is a thin SwiftUI shell. New data enters as a source emitting events into `FleetReducer`; new features are new derivations on the snapshot. Tests are fixture-based — fixtures mirror real captured payloads, so schema drift breaks tests instead of silently breaking the app.
