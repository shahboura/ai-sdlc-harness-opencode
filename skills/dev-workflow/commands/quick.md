# Phase Q: Quick Mode

> Authoritative references: [timestamp](../context/timestamp.md), [workflow-paths](../context/workflow-paths.md), [agent-response](../context/agent-response.md)

<!-- Created by: dev-workflow-plan.md [M-25] [IMPL-25-02]
     Reason: US-E01-004 — Q-phase command contract per CC-05.8 fast-path invariants.
     CC conventions applied: CC-05.8, CC-05.1, CC-01.8, ADR-001, ADR-011. -->

**Phase**: Q
**Actor**: Orchestrator (guard + routing) → Developer agent → Reviewer agent → Orchestrator (PR)
**Trigger**: `/dev-workflow quick "<description>" [--repo <name>]`

Quick mode is a **constrained fast path** for sub-15-minute, low-risk changes. It skips Requirements (P1), Planning (P2), and Test Hardening (P5). All hooks, the FSM, the commit contract, and the audit trail remain in force per CC-05.8.

---

## Prerequisites

- P0 workspace bootstrap complete (`.claude/context/` exists; `naming-config.md`, `repos-paths.md`, `language-config.md` present).
- `.claude/context/quick-mode-config.md` present (written by `/init-workspace`). If absent, use the shipped defaults from `scripts/quick-mode-classify.py`.
- **No active full-pipeline workflow** for the same work item (quick mode cannot run alongside an open Phase 3–8 workflow for the same story).

---

## Step 1 — Classify change

Run the classifier to get a `(RiskTier, ChangeStats)` pair:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/quick-mode-classify.py" \
    --diff - \
    --config .claude/context/quick-mode-config.md
```

If no diff is staged, pass the free-text description as a synthetic diff placeholder (classifier returns `RiskTier.low` for non-diff input — guard still runs). Capture the JSON output.

---

## Step 2 — Guard check (QPhaseGuard)

Invoke `scripts/q_phase_guard.py`:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/q_phase_guard.py" \
    --diff - \
    --config .claude/context/quick-mode-config.md
```

Parse the JSON response:
- `"allowed": true` → proceed to Step 3.
- `"allowed": false` → **halt immediately**. Emit the `reason` field to the human. Do NOT write a tracker. Do NOT create a branch. The human must restart with `/dev-workflow plan <work-item-id>`.

The guard also enforces invariant **I-3**: if the diff touches a security-sensitive path, it aborts regardless of LOC count.

---

## Step 3 — Create minimal tracker

Derive paths:

```bash
TODAY=$(date -u +%Y-%m-%d)
STORY_ID=$(echo "$ARGUMENTS" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g' | cut -c1-40)
WORKFLOW_DIR="$WORKSPACE_ROOT/ai/${TODAY}-quick-${STORY_ID}"
mkdir -p "$WORKFLOW_DIR"
```

Write `$WORKFLOW_DIR/tracker.md` with this exact structure:

```markdown
# Task Tracker — Quick Mode: <description> (<date>)
Mode: quick

| Task ID | Repo | Title | Status | Reviewer Verdict | Commit(s) | Notes |
|---------|------|-------|--------|------------------|-----------|-------|
| T1 | <repo> | <description> | ⏳ Pending | — | — | test-required: false · quick-mode: true |

## Workflow Metrics

| Metric | Value |
|--------|-------|
| **Workflow started** | <!-- date -u +"%Y-%m-%d %H:%M UTC" --> |
| **Quick-mode completed** | — |
```

Rules:
- `Mode: quick` MUST appear in the tracker front-matter (before the task table).
- `test-required: false` and `quick-mode: true` MUST appear in T1's Notes column.
- No plan.md, no test-outline.md — quick mode has neither.
- Set `Workflow started` metric to `date -u +"%Y-%m-%d %H:%M UTC"` output.

---

## Step 4 — Branch and worktree

Reuse the P2.5 branch-creation logic:

```bash
BRANCH_NAME=$(python3 -c "
import re, sys
tmpl = open('.claude/context/naming-config.md').read()
# Extract branch_format line; default: feature/<story_id>-<slug>
m = re.search(r'branch_format:\s*(.+)', tmpl)
fmt = m.group(1).strip() if m else 'feature/\${story_id}-\${slug}'
story_id = sys.argv[1]; slug = sys.argv[2]
print(fmt.replace('\${story_id}', story_id).replace('\${slug}', slug[:20]))
" "$STORY_ID" "$(echo "$ARGUMENTS" | tr ' ' '-' | tr -cd 'a-zA-Z0-9-' | cut -c1-20)")
git -C "<repo-path>" checkout -b "$BRANCH_NAME"
```

Sensitive-file `PreToolUse` hook is armed from this point on every write.

---

## Step 5 — Developer phase

Invoke **@ai-sdlc-developer**:

> **IMPORTANT**: Before invoking, call `QPhaseGuard.refuse_agent('ai-sdlc-tester')` internally — quick mode never invokes the Tester. The guard call is conceptual (not a subprocess call); just ensure no Tester invocation is issued.

```
@ai-sdlc-developer
QUICK MODE — no plan file. Implement this change directly from the description.

DESCRIPTION: <verbatim description from /dev-workflow quick argument>

REPO: <repo-name>
REPO PATH: <repo-path>
BRANCH: <branch-name>
LANGUAGE CONTEXT: <contents of language-config.md for this repo>

CONSTRAINTS (CC-05.8 / quick-mode invariants):
- test-required: false — do NOT write new tests.
- No Planner, no Tester — this is a direct implement-and-commit flow.
- Commit footer MUST end with: Quick-Mode: true
- Commit subject: <standard format per naming-config.md commit_format>
- Build must pass (zero warnings if zero_warning_support applies).
- Sensitive-file guard is active on every write.
```

Parse the Developer's `📋 AGENT STATUS`. If `Outcome: FAILED` or `Build result: FAILED`, route to clean abort (Step 7b — CHANGES/ABANDON path).

Update tracker:
- T1 Status → 🔄 In Review
- Record `Commit(s)` from Developer status block.

---

## Step 6 — Reviewer phase (Phase 0+B)

> **Phase 0+B note (OQ-A1)**: Quick mode has no plan artifact. The Reviewer runs Phase 0 (Ownership & Convention Pre-Check) and Phase B (Code Quality Review) only. Phase A (Spec Compliance) is **skipped** — there is no approved plan to check against. The description text is the functional spec.

Invoke **@ai-sdlc-reviewer**:

```
@ai-sdlc-reviewer
QUICK MODE review — Phase 0+B only (no Phase A spec compliance).

DESCRIPTION (functional intent): <verbatim description>

REPO: <repo-name>
REPO PATH: <repo-path>
WORKTREE / BRANCH: <branch-name>
COMMIT: <commit hash from Developer>
LANGUAGE CONTEXT: <contents of language-config.md for this repo>

PHASE 0 — Run the Ownership & Convention Pre-Check as normal.
PHASE A — SKIP. There is no plan file. Do not attempt to check spec compliance.
PHASE B — Run Code Quality Review: build verification, coding conventions,
  SOLID/DRY/YAGNI, security, no dead code. Use the DESCRIPTION above as the
  functional intent. Issue [R<n>] and [T<n>] comments as usual.

Do NOT invoke the Planner. Do NOT add any test tasks.
```

Parse Reviewer `📋 AGENT STATUS`. On `Verdict: CHANGES_REQUESTED` → Step 7b (clean abort). On `Verdict: APPROVED` → Step 7a (GATE #3).

---

## Step 7a — GATE #3 (human approval)

Present the Reviewer's Phase B output to the human:

```
Quick-mode review complete.

Verdict: APPROVED

<paste Reviewer's full Phase B assessment>

Reply APPROVED to create the PR, or CHANGES to abort.
```

On `APPROVED` (canonical matcher per `orchestrator-rules.md` → *Human Approval Signal*):
1. Create PR via the configured git provider (read `provider-config.md`).
2. Update tracker: T1 → ✅ Done; `Quick-mode completed <ts>` metric stamped.
3. Trigger P9 metrics: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/metrics_collector.py" "$WORKFLOW_DIR" --round 0` (the `--round` flag is required — argparse rejects positional round labels).

## Step 7b — Clean abort

On CHANGES, ABANDON, or Reviewer `CHANGES_REQUESTED`:
1. Remove worktree: `git -C "<repo-path>" worktree remove "<worktree-path>"`
2. Delete branch: `git -C "<repo-path>" branch -D "<branch-name>"`
3. Archive tracker: rename `tracker.md` → `tracker.aborted.md`.
4. Inform human: "Quick-mode aborted. Re-run with `/dev-workflow quick` after fixing, or use `/dev-workflow plan` for a full pipeline."

---

## Invariants (CC-05.8 — non-negotiable)

These cannot be bypassed regardless of human instruction:

1. **No Planner invocation.** `QPhaseGuard.refuse_agent('ai-sdlc-planner')` — always blocked.
2. **No Tester invocation.** `QPhaseGuard.refuse_agent('ai-sdlc-tester')` — always blocked.
3. **No mid-flow upgrade.** If the human asks to switch to full mode mid-flow, call `QPhaseGuard.refuse_upgrade()` and emit the abort instructions.
4. **Security paths abort.** The guard check at Step 2 handles this; do not skip it.
5. **Quick-Mode: true commit footer.** Every Developer commit in quick mode MUST carry this footer. If the Developer omits it, surface as a `[R<n>]` CRITICAL finding — it must be re-committed.
