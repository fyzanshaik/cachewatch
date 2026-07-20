# Install Cachewatch

Cachewatch is a macOS menu bar app that monitors all local Claude Code sessions:
live state, prompt-cache TTL, quota, memory, and actionable alerts. It reads
Claude Code's existing local files and statusline data. It does not call an AI
API or spend tokens.

## Before installing

Cachewatch currently requires:

- Apple silicon (`arm64`)
- macOS 15 or newer
- Homebrew
- Claude Code

> [!IMPORTANT]
> Current public releases are ad-hoc signed and are not notarized by Apple. The
> maintainer does not currently pay for an Apple Developer Program membership.
> macOS Gatekeeper may therefore block the first launch. Review the source and
> release provenance before installing, and use Apple's **Open Anyway** flow if
> you trust the app. Do not remove quarantine attributes or disable Gatekeeper.

## Install with Homebrew

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

After Cachewatch has launched successfully, run:

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
configuration.

## Verify

```sh
pgrep -fl Cachewatch
cachewatch dump
```

The first command should show the running app. The second should print the
locally discovered Claude Code session fleet. An empty fleet is normal when no
Claude Code sessions are running.

## Install with a coding agent

Copy the prompt below into Codex, Claude Code, or another local coding agent:

```text
Install Cachewatch, a macOS menu bar app that monitors local Claude Code
sessions, prompt-cache TTL, quota, memory, and alerts.

First fetch and read the canonical installation guide:
https://raw.githubusercontent.com/fyzanshaik/cachewatch/main/INSTALL.md

Before changing anything, explain to me:
1. what Cachewatch does and what local data it reads;
2. the macOS, architecture, Homebrew, and Claude Code requirements;
3. the current ad-hoc-signing and Apple notarization disclaimer; and
4. every file or setting the installation and `cachewatch setup` will change.

Then install it by following that guide exactly. Do not remove quarantine
attributes, disable Gatekeeper, or bypass macOS security controls. If Gatekeeper
blocks the app, pause and guide me through System Settings > Privacy & Security
> Open Anyway. Launch the app before running `cachewatch setup`, restart any
existing Claude Code sessions, and verify both the Cachewatch process and
`cachewatch dump`. Report what succeeded and anything that still needs me.
```
