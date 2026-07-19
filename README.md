<p align="center">
  <img src="assets/mascot.png" width="110" alt="Cachewatch">
</p>

<h1 align="center">Cachewatch</h1>

<p align="center">A macOS menu bar app that watches all your Claude Code sessions at once — live status, prompt-cache state with TTL countdowns, real quota usage, per-session memory, and the cost of waking a cold session.</p>

<p align="center">
  <img src="assets/screenshot.png" width="700" alt="Cachewatch fleet panel">
  <br>
  <sub>Session names in this screenshot were regenerated with Gemini to scrub work-specific project names — the layout and data are real.</sub>
</p>

## Why

Claude Code shows you one session at a time. Run several in parallel and there's no view of which ones are waiting for your input, which caches are about to expire, how much of your 5-hour and weekly quota is gone, or how much memory that session you abandoned three days ago is still holding. Cachewatch is that view, plus notifications when something needs you.

## How Claude Code caching and quota actually work

Building this required figuring out how the pieces fit. The short version, so the features below make sense:

**Prompt caching.** Every turn re-sends your entire conversation. Anthropic caches the prefix server-side so repeat turns bill cache *reads* at 0.1x the base input price instead of reprocessing everything. The cache has a TTL — 5 minutes by default on API keys, **1 hour automatically on a subscription** (main conversation only; subagents get 5m) — and every cache hit refreshes the timer for free. Which TTL applied is visible per turn in the transcript's `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` buckets, so Cachewatch reads it rather than guessing.

**Cache expiry is a cliff.** Once the TTL lapses, your next prompt pays a full-context cache *write* — 1.25x base for 5m TTL, 2x for 1h. On a 400k-token session that's a few dollars of API-equivalent cost in one keystroke. It's one-time (turn two is cached again), but it's why "should I resume or abandon this cold session?" deserves a number. Cache writes also happen when you didn't expect them: a Claude Code upgrade, model or effort switch, or MCP server change silently invalidates the prefix and pays the rewrite — the "silent cache miss."

**Quota windows.** Subscriptions meter usage in a 5-hour window (starts at your first prompt, resets 5h later) plus a weekly cap. Claude Code reports both windows' used-% and reset timestamps in the JSON it pipes to statusline scripts (`rate_limits`, with `resets_at` as epoch seconds — the docs-era format was an ISO string; Cachewatch accepts both). Two sharp edges we learned by hitting them: each session's statusline payload reflects *that session's* last API response, so idle sessions re-rendering on a timer report stale quota — the merged value must be monotonic within a window, or your quota display goes backwards; and **Anthropic does not publish how token types weigh against Plan quota**. Dollars are the wrong unit for subscribers, and nobody outside Anthropic knows the conversion — so Cachewatch measures it (see calibration below).

## Features

**Session fleet.** Discovers every live session from Claude Code's own session registry (PID-validated, since registry files linger after exit) and tails the transcript JSONLs for per-turn data. Each row: project, git branch, model, context size with a capacity bar, status dot (idle / busy / waiting), and which app hosts the session — detected by walking the process ancestry — with click-to-focus. Sessions stuck waiting for input sort to the top, and the menu bar icon flips to a count badge when any session needs you.

**Cache state, from ground truth.** Warm/cold per session with a live countdown and drain bar, computed from the last turn's timestamp plus the TTL bucket that turn actually wrote. A silent-cache-miss detector flags any turn that paid a ≥50k-token rewrite while the cache should still have been warm — the upgrade/`--resume` regressions that otherwise cost you quietly.

**Cost to resume.** Cold sessions show what the full-context rewrite will cost at your next prompt: real dollars on API billing (context × model rate × TTL write multiplier). On a subscription, see calibration.

**Quota calibration — the novel bit.** Cachewatch prices every turn across your fleet at API list rates into a cumulative spend figure, and pairs it with each server-reported used-% sample. Accumulating (Δdollars, Δpercent) intervals within a window fits your account's actual dollars-per-percent — empirically, passively, from your own usage. Once fitted (a "learning quota" indicator shows progress), cold sessions display `~N% 5h` instead of dollars: the cost of resuming expressed in the only unit that matters on a Plan. The fit persists, keeps refining as you work, and every accepted sample is logged to a rolling 30-day `quota-history.jsonl` for burn-rate analysis and auditing the fit against reality.

**Quota display that can't lie.** 5-hour and weekly bars with reset countdowns. Samples merge monotonically per window (stale idle-session renders are rejected), the display survives app restarts (last-known value, marked with its age), and when a window resets while you're away the badge flips to "reset" on local clock instead of showing a dead percentage.

**Memory accounting.** RSS of each session's full process tree — MCP servers included, which is where the surprise gigabytes hide — plus a machine-wide footer (`sessions 1.0 GB · mac 14 GB / 18 GB`, using Activity-Monitor-style used memory).

**Notifications.** Six rules, each fires once per event, survives restarts, individually toggleable:

| Alert | Fires when |
|---|---|
| Quota | 5h or 7d window crosses 80% (once per window) |
| Cache expiry | A 5m-TTL session with ≥50k context has <90s of cache left |
| Needs input | A session sits on a prompt/permission for 2+ minutes — its cache burning down while it waits |
| Turn finished | A 5+ minute busy turn completes (a completion pager for parallel agents) |
| Long idle | 6h+ idle with big context and 500MB+ RSS — close-me candidates |
| Silent cache miss | A full rewrite happened when a cache read was expected |

On notched Macs, alerts animate out of the notch (spring in, dwell, retract, with the mascot); elsewhere they fall back to standard notifications.

**Notch panel (opt-in).** The notch is an interaction zone, not a display — nothing can render inside the physical cutout, and permanent black bars around it just cover your windows. So idle means invisible: hover the notch dead zone and the fleet panel flows out beneath it; mouse away and it's gone. Toggle in the panel footer.

**Close session.** Hover a row for a confirm-gated button that terminates that Claude Code process — with the memory column telling you which ones are worth reaping.

## How it works

No API calls, no tokens spent, no accounts. Cachewatch reads what Claude Code already writes locally:

| Source | Provides |
|---|---|
| `~/.claude/sessions/*.json` | Session discovery, pid, live status |
| `~/.claude/projects/**/*.jsonl` | Per-turn tokens, cache TTL buckets, model, branch |
| Statusline forwarder (below) | Quota (`rate_limits`), cost, context %, per session |
| `ps` | Process-tree memory and host-app detection |

Everything flows into one reducer producing an immutable fleet snapshot; the UI renders snapshots. All fleet state rebuilds from disk at launch — persistence is one `state.json` (preferences, alert dedup, calibration fit, last-seen quota) plus the quota-history JSONL. Delete both for a factory reset.

## Install

Requires macOS 15+ and Swift 6 (Command Line Tools are enough to build and run).

```sh
git clone https://github.com/fyzanshaik/cachewatch && cd cachewatch
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

The script renders a compact statusline (`Opus 4.8 | ctx 73% | 5h 43% | 7d 12%`) and forwards the JSON to Cachewatch's local socket. Already have a statusline you like? Set `CACHEWATCH_NEXT_STATUSLINE` to its command and the script chains to it. If Cachewatch isn't running the forward is a silent no-op — your statusline never breaks or slows down. `refreshInterval` keeps quota fresh while sessions idle; sessions pick the setting up on restart.

## Configuration

`~/Library/Application Support/Cachewatch/state.json`:

```json
{
  "alerts": {
    "notificationsEnabled": true,
    "quota":        { "enabled": true, "thresholdPercentage": 80 },
    "cacheExpiry":  { "enabled": true, "warningSeconds": 90, "minContextTokens": 50000 },
    "longIdle":     { "enabled": true, "idleHours": 6, "minContextTokens": 100000, "minMemoryBytes": 500000000 },
    "cacheMiss":    { "enabled": true },
    "needsInput":   { "enabled": true, "afterSeconds": 120 },
    "turnFinished": { "enabled": true, "minBusySeconds": 300 }
  },
  "notchHUDEnabled": false
}
```

Missing fields decode to defaults, so upgrades never migrate.

## Caveats

- The session registry, transcript schema, and statusline JSON are undocumented Claude Code internals; they have changed without notice before and will again. Parsers are fixture-tested against real captured payloads and degrade per-field, but a Claude Code update can still break things — file an issue with a captured payload.
- The TTL countdown is a client-side expectation (last turn + TTL). Refresh-on-read is documented; guaranteed retention is not.
- Dollar figures use API list prices (`Sources/CollectorEngine/Pricing.swift`); the fitted `%` figures are estimates measured from your own account, since the Plan quota formula is unpublished.
- Quota freshness is bounded by statusline renders (per turn + `refreshInterval`). Reset countdowns and expired-window handling are pure local clock and stay correct regardless.

## Development

```sh
swift run cachewatch-tests    # test suite (plain-assertion runner; no Xcode required)
```

Engine logic lives in `Sources/CollectorEngine` (no UI imports); the app target is a thin SwiftUI shell. New data enters as a source emitting events into `FleetReducer`; new features are new derivations on the snapshot. Fixtures mirror real captured payloads, so schema drift breaks tests instead of silently breaking the app.

## License

[MIT](LICENSE). Mascot artwork from the [Claude Code Pixel illustrations](https://getillustrations.com) pack by Getillustrations.
