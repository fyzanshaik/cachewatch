<p align="center">
  <img src="assets/mascot.png" width="110" alt="Cachewatch">
</p>

<h1 align="center">Cachewatch</h1>

<p align="center">A macOS menu bar app and Linux GNOME top-bar/terminal monitor for all your Claude Code and Codex sessions: live status, context, quota, per-session memory, and Claude prompt-cache TTL.</p>

<p align="center">
  <img src="assets/screenshot.png" width="700" alt="Cachewatch fleet panel">
  <br>
  <sub>Session names in this screenshot were regenerated with Gemini to scrub work project names. The layout and data are real.</sub>
</p>

## Why

Claude Code and Codex show you one session at a time. Run several in parallel and you lose track of what is busy, which Claude caches are about to expire, how much quota is left, and how much memory that session you abandoned three days ago still holds. Cachewatch is that missing view, plus notifications when something needs you.

## Background, in 30 seconds

- Claude caches your conversation prefix server-side. Cache reads cost 0.1x the normal input price. The cache lives 5 minutes on API keys and 1 hour on subscriptions, and every hit resets the timer.
- When the cache expires, your next prompt pays a full rewrite at 1.25x to 2x input price. On a 400k-token session that is real money, or real quota.
- Subscriptions meter usage in a 5-hour window plus a weekly cap. Anthropic does not publish how tokens convert to quota percent. Cachewatch measures it on your account instead of guessing.

## Features

- **Fleet view.** Every live Claude Code and Codex session: agent, project, branch, model, context, status, memory of its full process tree including MCP servers, and last turn. macOS adds the hosting terminal app, click-to-focus, context bars, and menu bar waiting count. Linux includes a native GNOME top-bar dropdown and a live terminal table.
- **Cache state.** Claude sessions show warm or cold with a live countdown, read from the TTL buckets Claude Code actually wrote, not inferred. Detects silent cache misses too: turns that paid a full rewrite when the cache should have been warm (typically after upgrades or resume). Codex does not currently persist an equivalent TTL signal, so Cachewatch leaves its cache state unknown.
- **Cost to resume.** Cold sessions show what the rewrite will cost at your next prompt. Dollars on API billing. On a subscription it shows `~N% 5h` instead, using a conversion rate fitted from your own account: Cachewatch prices every turn at API rates and pairs that with the server-reported quota percent until the ratio converges. The fit persists and keeps improving as you work. Full mechanism, worked examples, and limitations: [docs/calibration.md](docs/calibration.md).
- **Quota.** Separate Claude and Codex windows with reset countdowns. Values merge monotonically per window so stale data from idle sessions can never make quota go backwards. On macOS, Claude quota survives restarts and every Claude sample is logged to a 30-day history file for burn-rate analysis.
- **Notifications (macOS).** Quota crossing 80%, a big cache about to die, a session stuck waiting for input, a long turn finishing, heavy idle sessions, silent cache misses. Each fires once, survives restarts, and can be disabled individually. On notched Macs they animate out of the notch.
- **Notch panel (macOS, opt-in).** Nothing is displayed at the notch by default. Turn it on and hovering the notch dead zone opens the fleet panel right there.
- **Close session (macOS).** Hover a row for a confirm-gated button that kills that Claude Code or Codex process.

## How it works

No API calls, no tokens spent. Cachewatch reads what the agents already write locally:

| Source | Provides |
|---|---|
| `~/.claude/sessions/*.json` | Session discovery, pid, live status |
| `~/.claude/projects/**/*.jsonl` | Per-turn tokens, cache TTL buckets, model, branch |
| Statusline forwarder | Quota, cost, context percent |
| Open `~/.codex/sessions/**/*.jsonl` rollouts | Live Codex sessions, status, model, context, quota |
| `ps` | Process-tree memory; hosting macOS app when available |

Codex discovery uses `lsof` to join only rollout files held open by live Codex processes, so historical sessions never appear in the fleet. One reducer turns all sources into an immutable fleet snapshot; the macOS and Linux frontends just render snapshots. Everything rebuilds from disk at launch. The macOS app's only persistent state is `state.json` (preferences, alert dedup, calibration) and the quota history file. Delete both for a factory reset.

## Install

The native menu bar app needs macOS 15+ on Apple silicon. The Linux frontends
need Swift 6, `lsof`, `ps`, and an `nc` implementation with Unix socket
support. The optional top-bar frontend supports GNOME Shell 45 through 48.

> [!IMPORTANT]
> Current public releases are ad-hoc signed and are not notarized by Apple. The
> maintainer does not currently pay for an Apple Developer Program membership,
> so macOS may require one-time approval through **System Settings > Privacy &
> Security > Open Anyway**. Do not remove quarantine attributes or disable
> Gatekeeper. See the complete [installation guide](INSTALL.md).

### Install with your coding agent

Copy this prompt into Codex, Claude Code, or another local agent:

```text
Install Cachewatch, a macOS menu bar app or Linux terminal frontend that
monitors local Claude Code and Codex sessions, context, quota, memory, alerts,
and Claude prompt-cache TTL. First fetch and read:
https://raw.githubusercontent.com/fyzanshaik/cachewatch/main/INSTALL.md

Explain what the app does, its requirements for my operating system, and every
file or setting that installation changes. On macOS, also explain the Apple
notarization disclaimer and do not bypass Gatekeeper; use Apple's Open Anyway
flow if needed. Then follow the guide exactly to install, launch, connect, and
verify it.
```

### Install manually

#### macOS

```sh
brew install --cask fyzanshaik/tap/cachewatch
open -a Cachewatch  # approve through Privacy & Security if Gatekeeper blocks it
cachewatch setup    # wires the statusline forwarder, backs up settings first
```

The cask installs the native app in `/Applications` and exposes its command-line
entry point as `cachewatch`. Cachewatch has no normal window or Dock icon; after
launch it appears on the right side of the macOS menu bar.

Or from source:

```sh
git clone https://github.com/fyzanshaik/cachewatch && cd cachewatch
swift run Cachewatch          # menu bar app
swift run Cachewatch setup    # statusline hookup
swift run Cachewatch dump     # one-shot Claude + Codex fleet table
```

For the native app bundle, open `Cachewatch.xcodeproj`, select the Cachewatch
scheme, and run it. The app target references the same `Sources/Cachewatch`
files and local `CollectorEngine` package as SwiftPM. Bundled builds use native
notifications and expose a launch-at-login toggle; bare `swift run` builds keep
the `osascript` notification fallback.

The native app archive and a standalone arm64 command-line binary are attached
to each [release](https://github.com/fyzanshaik/cachewatch/releases). Maintainer
instructions for Developer ID signing and notarization are in
[docs/releasing.md](docs/releasing.md).

#### Linux

Cachewatch currently ships on Linux from source:

```sh
# Ubuntu or Debian
sudo apt-get install lsof netcat-openbsd procps

# Fedora
sudo dnf install lsof nmap-ncat procps-ng swift-lang

git clone https://github.com/fyzanshaik/cachewatch && cd cachewatch
swift build -c release
mkdir -p ~/.local/bin
install -m 755 .build/release/Cachewatch ~/.local/bin/cachewatch
cachewatch setup
cachewatch                 # live terminal view; Ctrl-C exits
cachewatch dump            # one-shot fleet table
```

For the GNOME top-bar dropdown, the repository includes an installer that
builds the same CLI and installs the extension for the current user:

```sh
./scripts/install-gnome-extension.sh
```

If the script says GNOME Shell needs to reload, log out and back in on Wayland
(or press Alt-F2 and enter `r` on X11), then run:

```sh
gnome-extensions enable cachewatch@cneuralnetwork.github.com
```

Use Swift 6 or newer and ensure `~/.local/bin` is on `PATH`. Both Linux
frontends show the canonical fleet and quota snapshots. Linux does not
currently provide desktop notifications, terminal focusing, session
termination controls, or the macOS notch panel.

### Statusline hookup

Claude quota and cost come from the JSON Claude Code pipes to its statusline.
`cachewatch setup` wires it up on either platform. Codex support is automatic
and does not modify Codex configuration.

This installs the forwarder script to `~/.cachewatch/` and adds it to `~/.claude/settings.json` (with a backup first). Idempotent, and if you already have a statusline it gets chained, not replaced. The script also renders a useful statusline on its own: `Opus 4.8 | ctx 73% | 5h 43% | 7d 12%`. When Cachewatch is not running the forward is a no-op; your statusline never breaks or slows down. New Claude Code sessions pick it up on start.

## Configuration

The macOS app stores preferences at
`~/Library/Application Support/Cachewatch/state.json`. All alert rules have an
`enabled` flag and thresholds; missing fields fall back to defaults so upgrades
never migrate. The Linux frontends do not persist UI preferences.

## Caveats

- The Claude registry/transcript/statusline schemas and Codex rollout schema are internal interfaces. They have changed without notice before. Parsers are tested against real captured payloads and fail per-field, but an update can still break things; file an issue with a captured payload.
- The TTL countdown is a client-side expectation. Refresh-on-read is documented, guaranteed retention is not.
- Dollar figures use API list prices. Quota percent figures are estimates measured from your account, since the real formula is unpublished.

## Development

```sh
swift build
swift test
xcodebuild -project Cachewatch.xcodeproj -scheme Cachewatch \
  -destination 'platform=macOS,arch=arm64' build
```

Engine logic lives in `Sources/CollectorEngine` with no UI imports. SwiftPM
selects the thin SwiftUI shell in `Sources/Cachewatch` on macOS and the terminal
entry point in `Sources/CachewatchCLI` on Linux; the Xcode app target continues
to use the SwiftUI sources. The GNOME extension consumes the CLI's versioned
newline-delimited JSON snapshot stream and performs presentation only. New data
enters as a source emitting events into the reducer, and new features are
derivations on the snapshot.

## License

[MIT](LICENSE). Mascot artwork from the [Claude Code Pixel illustrations](https://getillustrations.com) pack by Getillustrations.
