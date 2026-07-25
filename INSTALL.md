# Install Cachewatch

Cachewatch monitors local Claude Code and Codex sessions: live state, context,
quota, memory, and Claude prompt-cache TTL. The macOS app also provides
actionable alerts. It runs as a macOS menu bar app or a Linux terminal
frontend. It reads the agents' existing local files and status data. It does
not call an AI API or spend tokens.

## Before installing

Cachewatch requires Claude Code and/or Codex plus one of these platforms:

- Apple silicon (`arm64`), macOS 15 or newer, and Homebrew for the native app;
  or
- 64-bit Linux, Swift 6 or newer, `lsof`, `ps`, and an `nc` implementation with
  Unix socket support for the terminal frontend.

> [!IMPORTANT]
> Current public releases are ad-hoc signed and are not notarized by Apple. The
> maintainer does not currently pay for an Apple Developer Program membership.
> macOS Gatekeeper may therefore block the first launch. Review the source and
> release provenance before installing, and use Apple's **Open Anyway** flow if
> you trust the app. Do not remove quarantine attributes or disable Gatekeeper.
> This warning applies to the macOS release.

## Install on Linux

Install runtime dependencies and build from source. Install Swift 6 or newer
using the package provided for your distribution first.

```sh
# Ubuntu or Debian
sudo apt-get install lsof netcat-openbsd procps

# Fedora
sudo dnf install lsof nmap-ncat procps-ng swift-lang

git clone https://github.com/fyzanshaik/cachewatch
cd cachewatch
swift build -c release
mkdir -p ~/.local/bin
install -m 755 .build/release/Cachewatch ~/.local/bin/cachewatch
```

Ensure `~/.local/bin` is on `PATH`, then configure and start Cachewatch:

```sh
cachewatch setup
cachewatch
```

With no command, the Linux executable renders a live fleet table until Ctrl-C.
Use `cachewatch dump` for a one-shot table. The Linux frontend does not
currently send desktop notifications or provide macOS-only focus, close, and
notch controls.

## Install on macOS with Homebrew

Install the native app and its `cachewatch` command:

```sh
brew install --cask fyzanshaik/tap/cachewatch
```

Attempt the first launch before running setup:

```sh
open -a Cachewatch
```

If macOS blocks it:

1. Open **System Settings > Privacy & Security**.
2. Scroll to **Security** and find the message about Cachewatch.
3. Click **Open Anyway**, authenticate, and confirm **Open**.
4. Run `open -a Cachewatch` again if it does not launch automatically.

Cachewatch is menu-bar-only: it has no Dock icon or normal app window. After it
launches, look for its icon on the right side of the macOS menu bar.

## Connect Claude Code

On macOS, launch Cachewatch successfully before setup. On Linux, start the live
terminal view after setup. Configure either platform with:

```sh
cachewatch setup
```

This command:

- installs `~/.cachewatch/cachewatch-statusline.sh`;
- backs up `~/.claude/settings.json` as
  `settings.json.bak-cachewatch-<timestamp>` before changing it;
- adds Cachewatch's local statusline forwarder;
- preserves and chains an existing statusline command; and
- is safe to run again.

Restart existing Claude Code sessions so they load the updated statusline
configuration. On Linux, keep `cachewatch` running when you want live
statusline quota updates.

Codex needs no setup. Cachewatch discovers rollout files held open by live
Codex processes and never modifies `~/.codex/config.toml`.

## Verify

```sh
cachewatch dump
```

The command should print the locally discovered Claude Code and Codex fleet.
An empty fleet is normal when neither agent has a live session. On macOS,
`pgrep -fl Cachewatch` also verifies that the menu bar app is running.

## Install with a coding agent

Copy the prompt below into Codex, Claude Code, or another local coding agent:

```text
Install Cachewatch, a macOS menu bar app or Linux terminal frontend that
monitors local Claude Code and Codex sessions, context, quota, memory, alerts,
and Claude prompt-cache TTL.

First fetch and read the canonical installation guide:
https://raw.githubusercontent.com/fyzanshaik/cachewatch/main/INSTALL.md

Before changing anything, explain to me:
1. what Cachewatch does and what local data it reads;
2. the requirements for my operating system and supported agents;
3. the current ad-hoc-signing and Apple notarization disclaimer; and
4. every file or setting the installation and `cachewatch setup` will change.

Then install it by following that guide exactly. On macOS, do not remove
quarantine attributes, disable Gatekeeper, or bypass security controls. If
Gatekeeper blocks the app, pause and guide me through System Settings > Privacy
& Security > Open Anyway. Launch the macOS app before setup. On Linux, build
the terminal frontend from source and start its live view after setup. Restart
any existing Claude Code sessions, run `cachewatch dump`, and report what
succeeded and anything that still needs me.
```
