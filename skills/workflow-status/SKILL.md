---
name: workflow-status
description: "Display current workflow status dashboard — read-only overview of story progress, task states, branch info, and worktree status"
allowed-tools: Bash, Read, Grep, Glob
---

# /workflow-status — Workflow Status Dashboard

**Usage:** `/workflow-status`

This is a **read-only** skill. It does NOT modify any files — it only reads and displays information.

## Instructions

When invoked, gather and display a structured dashboard of the current workflow state. Follow these steps exactly:

### Step 1: Identify Active Tracker

<!-- Updated by: dev-workflow-plan.md [M-14] [IMPL-14-02]
     Reason: Scan both the new canonical layout (`ai/<YYYY-MM-DD>-<work-item-id>/tracker.md`)
     and the legacy layout (`ai/tasks/*.md`) during the migration window per CC-05.7.
     CC conventions applied: CC-05.7, CC-04.3. -->

> Authoritative reference: [workflow-paths](../dev-workflow/context/workflow-paths.md)

Resolve the most recent tracker by scanning both layouts (new canonical first; legacy fallback):

```bash
# New canonical layout: ai/<YYYY-MM-DD>-<work-item-id>/tracker.md
ls -t ai/*/tracker.md 2>/dev/null | head -5

# Legacy layout (deprecated; supported during migration window)
ls -t ai/tasks/*.md 2>/dev/null | head -5
```

Read the most recent file from whichever set has matches. If neither has any, report: "No active workflow found. Use `/dev-workflow <Work-Item-ID>` to start one."

### Step 2: Extract Story Metadata

From the tracker path, extract:
- **Story ID** — from the per-workflow directory name (`ai/<YYYY-MM-DD>-<story-id>/tracker.md`) OR from the legacy filename (`<date>_<story-id>_<slug>.md`).
- **Date started** — from the directory's date prefix (new) or the filename's date prefix (legacy).
- **Slug** (brief description) — derived from the story title (new layout) or embedded in the filename (legacy).

### Step 3: Read the Tracker (Section-Aware)

Read the full tracker file. A tracker has **up to three task-row sections**, all
sharing the same column schema:

| Section | Heading | Owner | Created in |
|---------|---------|-------|------------|
| Main table | (no heading — the first table after the title) | Planner | Phase 2 |
| PR-response amendments | `## Amendments (PR Review Round <N>)` | Planner | Phase 7 |
| Ad-hoc batches | `## Ad-hoc Tasks (Batch <N>)` | Planner | Inter-gate (handle-request) |

There can be **zero or more** Amendments / Ad-hoc sections — one heading per round
or batch, monotonically numbered. Identify each section by its heading; do not lump
every table row in the file together. The "main table" is the rows between the
title and the first `## ` heading (or end-of-file, whichever comes first).

For each section, extract:
- All task rows (ID, **Repo**, description, status, **Notes**)
- Count tasks by status: ⏳ Pending, 🔧 In Progress, 🔄 In Review, ✅ Done

Build a per-section tally and a global tally. The phase-detection rules in Step 4
key off the **main table** plus any active Amendment / Ad-hoc section. The dashboard
in Step 7 renders each section as its own group.

The `## Deferred Requests` table, if present, is **not** a task-row section — it
records OUT_OF_SCOPE / PLAN_CONFLICT / WITHDRAWN ad-hoc requests that did not
become tasks. Display it as a separate informational block in Step 7 but exclude
it from all tallies and phase-detection rules.

### Step 4: Determine Current Phase

Phase detection is **multi-valued by construction**. The workflow can be in
multiple phases at once — e.g. the main table is mid-Phase 3 in repo A while
an Ad-Hoc Batch is in flight in repo B. A single-valued classification ("Phase
3" or "Inter-gate" but never both) would lose signal.

Build the phase string by collecting **every applicable phase** from the table
below, then joining them with ` + `. The order of joining is fixed (main-table
phase first, then Amendments, then Ad-hoc) so the rendered string is
deterministic across runs.

| Detector | Emits |
|----------|-------|
| No dev tasks exist in the main table | `Phase 1-2: Planning` |
| Any main-table task 🔧 or 🔄 | `Phase 3: Development Loop` |
| All main-table dev tasks ✅, no T-TEST-* row, `Human approval (impl)` metric not set | `Phase 4: Human Approval` |
| All main-table dev tasks ✅, T-TEST-* row 🔧 or 🔄, `PR created` metric **not** set | `Phase 5: Testing` |
| All main-table dev tasks ✅, T-TEST-* row 🔧 or 🔄, `PR created` metric **set** | `Phase 5: Re-hardening (post-Phase-7 / post-Gate-3 batch)` — the original Phase 5 already completed (PR was open); a Phase 7 amendment or post-Phase-5 ad-hoc batch landed and re-triggered T-TEST per `commands/review-response.md` Step 8b / `commands/handle-request.md` Step 7b. Renders distinctly from first-time Phase 5 so the reader knows the PR is already open and the re-hardening is gating new code added since |
| All main-table tasks ✅ (including T-TEST), `PR created` metric not set | `Phase 6: PR Creation` |
| `PR created` metric set, no Amendment / Ad-hoc batches in flight | `Phase 6: PR Open` (terminal idle state) |
| Any Amendment row 🔧, 🔄, or ⏳ (Pending) | `Phase 7: PR Review Response (Round <N>)` — `<N>` is the highest active round |
| Any Ad-hoc Batch row 🔧, 🔄, or ⏳ (Pending) | `Inter-gate: Ad-Hoc Request Handling (Batch <N>)` — `<N>` is the highest active batch |
| `## Pending Requests` section exists and has at least one row | `Inter-gate: Ad-Hoc Request Handling (in triage)` — the orchestrator is mid-triage for one or more `[AHR-<n>]` (Step 1–5 of `handle-request.md`); no ad-hoc tasks exist yet but the workflow is not idle |
| Every section is fully ✅ (main + every Amendment + every Ad-hoc batch), `PR created` metric set | `Done` |

**Examples:**
- Main table mid-Phase 3, no Amendments, no Ad-hoc batches → `Phase 3: Development Loop`
- Main table all ✅, T-TEST-AuthService 🔧 In Progress, Ad-hoc Batch 1 has a row 🔄 In Review → `Phase 5: Testing + Inter-gate: Ad-Hoc Request Handling (Batch 1)`
- Main table all ✅, T-TEST-AuthService 🔧 In Progress, Ad-hoc Batch 1 row just appended ⏳ Pending → `Phase 5: Testing + Inter-gate: Ad-Hoc Request Handling (Batch 1)` *(the detector fires on ⏳ Pending rows too; closes the window between Planner append and lane pickup)*
- Main table all ✅, no Ad-hoc rows yet, `## Pending Requests` has an `[AHR-1]` mid-triage → `Phase 4: Human Approval + Inter-gate: Ad-Hoc Request Handling (in triage)`
- Main table all ✅, `PR created` set, Amendment Round 1 has a row 🔧 In Progress → `Phase 6: PR Open + Phase 7: PR Review Response (Round 1)`
- Main table all ✅, `PR created` set, every Amendment / Ad-hoc Batch row ✅ Done, `T-TEST-AuthService` row just transitioned ✅ → 🔧 (B3 re-trigger) → `Phase 5: Re-hardening (post-Phase-7 / post-Gate-3 batch) + Phase 6: PR Open` *(distinguishes the re-trigger from first-time Phase 5 — the `PR created` set flag is the deciding signal)*
- All sections fully ✅, `## Pending Requests` empty, `PR created` set → `Done`

When determining phase, **ignore** task rows in inactive Amendment / Ad-hoc
sections (every row in that section is ✅ Done) — those represent prior completed
batches, not in-flight work. They contribute to the `Done` detector but never
to the per-section in-flight detectors.

### Step 5: Git Status (Multi-Repo)

Read `.claude/context/repos-paths.md` to get repo paths.

If the tracker has a **Repo Status** section, gather git context per-repo:

```bash
# For each affected repo:
git -C <repo-path> rev-parse --abbrev-ref HEAD
git -C <repo-path> log --oneline -3
git -C <repo-path> worktree list
git -C <repo-path> status --porcelain | head -5
```

For single-repo stories or legacy trackers, use the current directory:
```bash
git rev-parse --abbrev-ref HEAD
git log --oneline -3
git worktree list
git status --porcelain | head -10
```

### Step 6: Locate Plan File

```bash
# Prefer new canonical layout (per-workflow directory carries plan.md alongside tracker.md)
ls -t ai/*/plan.md 2>/dev/null | head -1
# Legacy fallback
ls -t ai/plans/*.md 2>/dev/null | head -1
```

### Step 7: Present Dashboard

Format the output as follows:

```
╔══════════════════════════════════════════════════════════════╗
║                 📊 WORKFLOW STATUS DASHBOARD                 ║
╚══════════════════════════════════════════════════════════════╝

📌 Story:    #<STORY-ID> — <slug>
📅 Started:  <date>
🔄 Phase:    <current phase>
🔀 Branch:   <current branch>

─── Task Progress ─────────────────────────────────────────────
  ✅ Done:        X / Y
  🔧 In Progress: X / Y
  🔄 In Review:   X / Y
  ⏳ Pending:     X / Y
  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Progress:       [████████░░] XX%

─── Task Details ──────────────────────────────────────────────
  ▸ Main
    T1  | AuthService     | <description>      | ✅ Done
    T2  | AuthService     | <description>      | 🔧 In Progress
    T3  | BillingService  | <description>      | ⏳ Pending
    ...
  (Repo column shown for multi-repo stories)

  ▸ Amendments (PR Review Round 1)   ← omit block entirely if no such section
    T6  | AuthService     | <description>      | ✅ Done

  ▸ Ad-hoc Tasks (Batch 1)            ← omit block entirely if no such section
    T7  | AuthService     | <description>      | 🔄 In Review
    T8  | AuthService     | <description>      | ⏳ Pending

─── Deferred Requests ─────────────────────────────────────────  ← omit if no such section
  [AHR-2] OUT_OF_SCOPE → DEFERRED_AS_NEW_STORY (2026-05-15 14:22 UTC)
    "Add dark mode to the drawer"
  [AHR-3] PLAN_CONFLICT → WITHDRAWN (2026-05-15 16:10 UTC)
    "Use click-outside-only dismissal" (conflicts with plan §Design Decisions)

─── Per-Repo Git Context ──────────────────────────────────────
  📦 AuthService (/home/dev/repos/auth-service)
    Branch:    backend/feature/12345-slug
    Worktree:  <active worktree path or "None">
    Last commit: <hash> <message>
    Uncommitted: <count> file(s) or "Clean"

  📦 BillingService (/home/dev/repos/billing-service)
    Branch:    backend/feature/12345-slug
    Worktree:  <active worktree path or "None">
    Last commit: <hash> <message>
    Uncommitted: <count> file(s) or "Clean"
  (Single-repo stories show one repo section)

─── Files ─────────────────────────────────────────────────────
  📄 Tracker: <path>
  📝 Plan:    <path>
───────────────────────────────────────────────────────────────
```

### Important Notes

- This skill is **read-only** — do NOT modify any files.
- If multiple tracker files exist, show the most recent one.
- If the user asks follow-up questions about specific tasks, read the tracker for details.
- The progress bar should visually represent the percentage of ✅ Done tasks out of total tasks.
