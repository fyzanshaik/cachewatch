<p align="center">
  <img src="assets/mascot.png" width="110" alt="Cachewatch">
</p>

<h1 align="center">Cachewatch</h1>

<p align="center">A macOS menu bar app that watches all your Claude Code sessions at once: live status, cache TTL countdowns, real quota usage, per-session memory, and the cost of waking a cold session.</p>

<p align="center">
  <img src="assets/screenshot.png" width="700" alt="Cachewatch fleet panel">
  <br>
  <sub>Session names in this screenshot were regenerated with Gemini to scrub work project names. The layout and data are real.</sub>
</p>

## Why

Claude Code shows you one session at a time. Run several in parallel and you lose track of which ones are waiting for input, which caches are about to expire, how much quota is left, and how much memory that session you abandoned three days ago still holds. Cachewatch is that missing view, plus notifications when something needs you.

## Background, in 30 seconds

- Claude caches your conversation prefix server-side. Cache reads cost 0.1x the normal input price. The cache lives 5 minutes on API keys and 1 hour on subscriptions, and every hit resets the timer.
- When the cache expires, your next prompt pays a full rewrite at 1.25x to 2x input price. On a 400k-token session that is real money, or real quota.
- Subscriptions meter usage in a 5-hour window plus a weekly cap. Anthropic does not publish how tokens convert to quota percent. Cachewatch measures it on your account instead of guessing.

## Features

- **Fleet view.** Every live session: project, branch, model, context fill bar, status (idle, busy, needs input), memory of its full process tree including MCP servers, and which terminal app hosts it (click to focus). Sessions waiting on you sort first and show a count in the menu bar icon.
- **Cache state.** Warm or cold with a live countdown, read from the TTL buckets Claude Code actually wrote, not inferred. Detects silent cache misses too: turns that paid a full rewrite when the cache should have been warm (typically after upgrades or resume).
- **Cost to resume.** Cold sessions show what the rewrite will cost at your next prompt. Dollars on API billing. On a subscription it shows `~N% 5h` instead, using a conversion rate fitted from your own account: Cachewatch prices every turn at API rates and pairs that with the server-reported quota percent until the ratio converges. The fit persists and keeps improving as you work.
- **Quota.** 5-hour and weekly bars with reset countdowns. Values merge monotonically per window so stale data from idle sessions can never make your quota go backwards. Survives restarts, and every sample is logged to a 30-day history file for burn-rate analysis.
- **Notifications.** Quota crossing 80%, a big cache about to die, a session stuck waiting for input, a long turn finishing, heavy idle sessions, silent cache misses. Each fires once, survives restarts, and can be disabled individually. On notched Macs they animate out of the notch.
- **Notch panel, opt-in.** Nothing is displayed at the notch by default. Turn it on and hovering the notch dead zone opens the fleet panel right there.
- **Close session.** Hover a row for a confirm-gated button that kills that Claude Code process.

## How it works

No API calls, no tokens spent. Cachewatch reads what Claude Code already writes locally:

| Source | Provides |
|---|---|
| `~/.claude/sessions/*.json` | Session discovery, pid, live status |
| `~/.claude/projects/**/*.jsonl` | Per-turn tokens, cache TTL buckets, model, branch |
| Statusline forwarder | Quota, cost, context percent |
| `ps` | Process-tree memory, host app |

One reducer turns all of it into an immutable fleet snapshot; the UI just renders snapshots. Everything rebuilds from disk at launch. The only persistent state is `state.json` (preferences, alert dedup, calibration) and the quota history file. Delete both for a factory reset.

## Install

Needs macOS 15+ and Swift 6. Command Line Tools are enough, no Xcode required.

```sh
git clone https://github.com/fyzanshaik/cachewatch && cd cachewatch
swift run Cachewatch          # menu bar app
swift run Cachewatch dump     # one-shot fleet table in the terminal
```

### Statusline hookup

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

The script also renders a useful statusline (`Opus 4.8 | ctx 73% | 5h 43% | 7d 12%`). If you already have one, set `CACHEWATCH_NEXT_STATUSLINE` to its command and the script chains to it. When Cachewatch is not running the forward is a no-op; your statusline never breaks or slows down.

## Configuration

`~/Library/Application Support/Cachewatch/state.json`. All alert rules have an `enabled` flag and thresholds; missing fields fall back to defaults so upgrades never migrate. See the Features list for what each rule does.

## Caveats

- The session registry, transcript schema, and statusline JSON are undocumented Claude Code internals. They have changed without notice before. Parsers are tested against real captured payloads and fail per-field, but an update can still break things; file an issue with a captured payload.
- The TTL countdown is a client-side expectation. Refresh-on-read is documented, guaranteed retention is not.
- Dollar figures use API list prices. Quota percent figures are estimates measured from your account, since the real formula is unpublished.

## Development

```sh
swift run cachewatch-tests
```

Engine logic lives in `Sources/CollectorEngine` with no UI imports; the app target is a thin SwiftUI shell. New data enters as a source emitting events into the reducer, and new features are derivations on the snapshot.

## License

[MIT](LICENSE). Mascot artwork from the [Claude Code Pixel illustrations](https://getillustrations.com) pack by Getillustrations.
