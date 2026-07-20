# Cachewatch

macOS menu bar app observing all local Claude Code sessions: fleet status, prompt-cache TTL state, quota, memory, alerts. Swift 6 (strict concurrency), macOS 15+. SwiftPM owns the engine and CLI; `Cachewatch.xcodeproj` packages the same UI sources as a native app.

## Commands

- `swift build` — build everything.
- `swift test` — the canonical Swift Testing suite in `Tests/CollectorEngineTests`.
- `swift run Cachewatch` — the menu bar app. `swift run Cachewatch dump` — one-shot fleet table, the fastest way to verify engine changes against real data.
- `xcodebuild -project Cachewatch.xcodeproj -scheme Cachewatch -destination 'platform=macOS,arch=arm64' build` — build the native `.app` target.

## Architecture (deliberate, keep it)

- `Sources/CollectorEngine` — all logic, zero UI imports. Four sources (registry scanner, transcript tailer, statusline socket listener, process-tree memory) emit `CollectorEvent`s into `FleetReducer`, a pure state machine producing the canonical `FleetSnapshot`. `Collector` (actor) owns the loop and publishes snapshots via AsyncStream.
- `Sources/Cachewatch` — thin SwiftUI shell (`MenuBarExtra` `.window` style), shared by the SwiftPM executable and Xcode app target. Renders snapshots, computes nothing except presentation. Time-derived display (countdowns, warm/cold) is a pure function of snapshot + `now` via `TimelineView`.
- New feature = new source or new derived field on the snapshot. Never a parallel pipeline.
- One persisted file: `state.json` (StateStore) — alert thresholds + fired-alert dedup keys. Everything else rebuilds from Claude Code's files on launch. Decoding must tolerate missing fields (defaults), so schema additions never migrate.

## Hard-won facts (do not re-derive from docs; docs were wrong)

- Statusline `rate_limits.*.resets_at` is **epoch seconds** live, ISO string in docs-era captures — decoder accepts both. Assume any statusline field can change shape; capture a real payload before trusting a schema.
- macOS `nc -U` does not half-close on stdin EOF: the socket listener decodes as soon as JSON parses, never waits for EOF.
- Claude Code kills the statusline script's process group on exit: the forwarder must run `nc` in the foreground.
- Subscription main sessions get 1h cache TTL (`ephemeral_1h` bucket), subagents 5m. TTL is read from transcript usage, never inferred.
- Registry files in `~/.claude/sessions/` linger after process exit — always PID-check.
- Statusline data only flows on renders (turns + `refreshInterval`); the user's settings.json has `refreshInterval: 60`.

## Conventions

- TDD: add the failing Swift Testing case first. Fixtures in `Tests/CollectorEngineTests/Fixtures/` mirror REAL captured payloads — when Claude Code changes formats, update fixtures from a fresh capture, not from documentation.
- Editing `scripts/cachewatch-statusline.sh` requires re-copying to `~/.cachewatch/` (the installed copy is what runs).
- `Pricing.swift` holds API list prices; verify against the pricing docs when touched.
- No emojis anywhere. Commits: one-line, no attribution trailers.
