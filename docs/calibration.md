# How quota calibration works

On a Claude subscription there is no per-token bill. Usage is metered against a 5-hour window and a weekly cap, and Anthropic does not publish how tokens convert to window percent. So "resuming this cold session costs $4.16" is the wrong unit for Plan users: the question is "how much of my window does it eat?"

Cachewatch answers that by measuring the conversion rate on your own account. This doc explains the mechanism, the "learning quota" indicator, and the failure modes.

## Step 1: price every turn

Every assistant turn in every session transcript carries exact token counts. Cachewatch prices each turn at API list rates (`Sources/CollectorEngine/Pricing.swift`):

| Token type | Weight |
|---|---|
| Plain input | 1x base input rate |
| Cache read | 0.1x |
| Cache write, 5m TTL | 1.25x |
| Cache write, 1h TTL | 2x |
| Output | 5x |

Example: an Opus turn ($5 per million base) that reads 200k cached tokens, writes 2k to the 1h cache, and produces 1k output costs

```
200,000 x 0.1 x $5/M  = $0.100   (reads)
  2,000 x 2.0 x $5/M  = $0.020   (1h write)
  1,000 x 5.0 x $5/M  = $0.025   (output)
                         ------
                         $0.145
```

Summing across all sessions and subagents gives a running fleet total. This is not what you pay; it is a consistent measuring stick for "how much work did the account just do."

## Step 2: pair spend with server-reported quota

Claude Code reports the window's `used_percentage` in its statusline JSON. Cachewatch samples it (merged monotonically per window, so stale renders from idle sessions cannot move it backwards) and pairs it with the fleet total.

An anchor-based accumulator turns this into intervals. The anchor holds still until, within the same window:

- used percent grew by at least 0.5 (below that is rounding noise), and
- local spend grew by at least $0.25 (below that, the quota movement mostly came from something Cachewatch cannot see).

When both clear, one interval is recorded: `(dollars spent, percent consumed)`, and the anchor moves. A window reset (new `resets_at`) replants the anchor without recording, because the percent baseline moved for reasons unrelated to spend.

## Step 3: fit, robustly

Each interval yields a ratio: dollars per percent. The estimate is the **median** of all recorded ratios (up to the last 200).

Median, not average, because the pairing has a known contamination source: your quota also burns from places Cachewatch cannot observe: claude.ai chats, other machines, other tools spawning Claude sessions, teammates on a shared plan. A contaminated interval looks like "quota jumped 4% while local spend grew $0.30" and yields an absurdly low ratio. With an average (or a ratio of sums), one such interval drags the whole fit; with a median it is just an outlier vote.

Example with five intervals:

```
$2.40 / 2.0%  = 1.20
$1.10 / 1.0%  = 1.10
$0.30 / 4.0%  = 0.075   <- claude.ai burned quota in this interval
$3.60 / 3.0%  = 1.20
$1.30 / 1.1%  = 1.18

median = 1.18 dollars per percent
```

The ratio-of-sums would have said 0.79 and inflated every estimate by 50%.

## "Learning quota"

The fit is not trusted until intervals covering at least **3 percent** of window burn have accumulated. Until then the header shows `learning quota N%` (progress toward that bar) and cold sessions display dollar estimates. Once trusted, they switch to `~N% 5h`:

```
cost to resume  = 344k tokens x $5/M x 2.0 (1h rewrite) = $3.44
fitted rate     = $1.18 per percent
display         = ~3% 5h
```

The fit persists across restarts in `state.json` and keeps refining as you work. Every accepted quota sample is also appended to `quota-history.jsonl` (30-day rolling), so a suspicious fit can be audited against the raw trajectory instead of argued about.

## Honest limitations

- **Estimates, not truth.** The real Plan formula is unpublished. If Anthropic weighs token types differently than API pricing (evidence so far is mixed), the fit absorbs the average effect but per-session estimates can skew.
- **External burn biases upward.** Contaminated intervals that survive the floors make quota look cheaper per dollar, which *over*-states resume costs. Conservative direction, but real. Heavy claude.ai use during calibration slows convergence.
- **Resolution.** The server reports used percent in coarse steps; single predictions carry roughly plus or minus 1 percent.
- **The percent figure covers the rewrite only.** The turn you send on top of it adds its own (usually small) cost.

Sanity-check the first estimates yourself: warm a cold session while nothing else is running and compare the window jump on claude.ai's usage page against the badge. That experiment is how this design got debugged in the first place.
