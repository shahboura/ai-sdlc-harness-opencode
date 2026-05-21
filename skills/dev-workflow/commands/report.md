# Metrics Report

> Authoritative references: [timestamp](../context/timestamp.md), [workflow-paths](../context/workflow-paths.md)

<!-- Created by: dev-workflow-plan.md [M-25] [IMPL-25-05]
     Reason: US-E02-005 — /dev-workflow report command per FR-2.2/2.3.
     CC conventions applied: CC-02.4.2 (null-safe cost/tokens), ADR-002, ADR-010. -->

**Phase**: utility (reads metrics artifacts; no FSM transitions; no agents)
**Trigger**: `/dev-workflow report [--since <YYYY-MM-DD>] [--format md|json] [--story <id>]`

---

## Arguments

| Argument | Default | Description |
|---|---|---|
| `--since <date>` | 30 days ago | Include only rows with `timestamp_utc ≥ <date>`. Format: `YYYY-MM-DD`. |
| `--format md\|json` | `md` | Output format. `md` = markdown table report; `json` = machine-readable object. |
| `--story <id>` | (all) | Per-story drill-down — show phase timeline for one story (see Step 6). |

---

## Steps

### Step 1 — Resolve paths and window

```python
from datetime import datetime, timezone, timedelta
import os

workspace = # WORKSPACE_ROOT (directory whose .claude/context/ has provider-config.md)
csv_path  = os.path.join(workspace, "ai", "_metrics-log.csv")
cost_cfg  = os.path.join(workspace, ".claude", "context", "cost-config.md")

# Parse --since (default: 30 days ago)
since_str = ARGUMENTS.get("since") or None
if since_str:
    since_dt = datetime.fromisoformat(since_str).replace(tzinfo=timezone.utc)
else:
    since_dt = datetime.now(timezone.utc) - timedelta(days=30)
    since_str = since_dt.strftime("%Y-%m-%d")
```

### Step 2 — Read `_metrics-log.csv`

Read the CSV. If the file is absent or empty, emit:
```
No metrics data found. Run `/dev-workflow metrics <work-item-id>` after completing stories.
```
and exit.

Parse all rows. Filter to rows where `timestamp_utc ≥ since_dt`. If no rows pass the filter, report the window and note "no completed stories in this period."

**Null-safe rule (CC-02.4.2):** `tokens_input`, `tokens_output`, `tokens_cache_read`, `tokens_cache_write` may be empty — treat as `None` (not 0). Cost for a story with null tokens is `"n/a"` even if `cost-config.md` has rates.

### Step 3 — Load cost rates

Read `.claude/context/cost-config.md`. Parse the per-model rate table:
```
| model | input_per_1m | output_per_1m | cache_read_per_1m | cache_write_per_1m |
```

If the file is absent or all rate cells are empty: **all cost fields render as `cost: n/a (configure cost-config.md)`** rather than `$0.00`.

Parse the `currency:` field (default `USD`).

### Step 4 — Compute aggregates

Per-story: group rows by `work_item_id`. For each story, take the row with the highest `round` value as the terminal row.

Compute:
- **wall_clock_minutes** = `cycle_time_minutes` from terminal row
- **tokens** = sum of the four token columns (null if any are null)
- **cost** = `tokens_input / 1M × input_per_1m` + equivalent for other columns (null if tokens null OR rates absent)
- **mode** = `mode` column value (`quick` / `full`)
- **rework_rounds** = `reviewer_rework_rounds`
- **coverage** = `coverage_pct`

Aggregate across the window:
- `total_stories` — count of distinct work_item_ids
- `quick_ratio` — `quick` mode count / total × 100
- `avg_cycle_time_minutes`
- `total_cost` — sum of per-story costs (null if ANY story has null tokens; report as `"cost data incomplete"`)

### Step 5 — Render output

**Markdown format** (`--format md`, default):

```
# Metrics Report — <since_str> to today

**Window**: <since_str> → <today>
**Stories**: <total_stories>  |  **Quick-mode**: <quick_ratio>%
**Avg cycle time**: <avg_cycle_time_minutes> min
**Total cost**: <total_cost or "n/a">

## Stories

| Work Item | Rounds | Cycle (min) | Tokens (in+out) | Cost | Mode | Coverage |
|---|---|---|---|---|---|---|
| <id> | <rework_rounds> | <wall_clock_minutes> | <tokens or "unavailable"> | <cost or "n/a"> | <mode> | <coverage or "—"> |
...

## Token Usage

<If all stories have null tokens:>
Token data unavailable — `metrics-token-collector.sh` fires at Stop events and
populates `.token-log.jsonl`; data appears after the next workflow run.

<If some stories have tokens:>
Partial token data (N of M stories have data).

## Cost Breakdown

<If cost-config.md is missing or rates empty:>
Cost data unavailable — edit `.claude/context/cost-config.md` to configure
model rates. See the template at `skills/init-workspace/templates/cost-config.md`.

<If rates configured but some tokens null:>
Partial cost data (only stories with token data shown).
```

**JSON format** (`--format json`):

```json
{
  "window": { "since": "<since_str>", "until": "<today>" },
  "summary": {
    "total_stories": N,
    "quick_ratio_pct": N,
    "avg_cycle_time_minutes": N,
    "total_cost": "<amount or null>"
  },
  "stories": [
    {
      "work_item_id": "...",
      "rework_rounds": N,
      "cycle_time_minutes": N,
      "tokens_input": N_or_null,
      "tokens_output": N_or_null,
      "tokens_cache_read": N_or_null,
      "tokens_cache_write": N_or_null,
      "cost": "<amount or null>",
      "mode": "quick|full",
      "coverage_pct": N_or_null
    }
  ]
}
```

### Step 6 — Per-story drill-down (`--story <id>`)

> This is US-E02-006 scope. When `--story <id>` is passed, show a per-phase timeline instead of the aggregate report.

Read all CSV rows for the story ID across all rounds. For each round, show:
- `round` — round label (0, 1..N, final)
- `timestamp_utc` — when the metrics row was recorded
- `p3_duration_minutes`, `p5_duration_minutes`, `p7_duration_minutes` — per-phase durations
- `mode` — quick or full

If the story is mid-flight (no terminal row with `round=final` or high round): note "In progress — showing data collected so far."

Format:

```
# Per-Story Report: <work_item_id>

Mode: <mode> | Coverage: <coverage_pct or "—"> | Rework rounds: <reviewer_rework_rounds>

| Round | Recorded | P3 (dev, min) | P5 (test, min) | P7 (review, min) | Tokens | Cost |
|---|---|---|---|---|---|---|
| 0 | ... | ... | ... | ... | ... | ... |
```
