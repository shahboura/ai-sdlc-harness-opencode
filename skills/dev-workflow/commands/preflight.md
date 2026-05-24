# Pre-Flight: Branch Creation + Plan Commit

> Authoritative references: [timestamp](../context/timestamp.md), [naming-templates](../context/naming-templates.md)

> Naming-config (M-15 IMPL-15-04): branch templates are read from `.claude/context/naming-config.md` per CC-01.8 — never hardcoded. The `naming-templates.md` reference above declares the placeholder DSL; this file's branch-creation steps use the rendered template from `naming-config.md`.

<!-- Changed by: dev-workflow-plan.md [M-11] [IMPL-11-01]
     Reason: Add canonical-spec header per CC-07.3.
     CC conventions applied: CC-07.3. -->

**Phase**: Pre-flight (runs between Phase 2 and Phase 3)
**Actor**: Orchestrator (not delegated to an agent)

## Prerequisites

- Phase 2 complete — plan and tracker exist at `<WORKSPACE_ROOT>/ai/<YYYY-MM-DD>-<work-item-id>/{plan,tracker}.md` (canonical M-14 layout per [workflow-paths](../context/workflow-paths.md)) OR at the legacy `<WORKSPACE_ROOT>/ai/plans/<id>.md` + `<WORKSPACE_ROOT>/ai/tasks/<id>.md` (deprecated; supported during the migration window).
- Plan approved at HUMAN GATE #1.
- The tracker's `## Repo Status` section is populated by the Planner (per `plan-generator/SKILL.md` Step 7).

If the prerequisites aren't met, surface to the human with a precise error message — the recovery path differs by failure mode:

| Discovered state | Error to surface | Recovery |
|------------------|------------------|----------|
| No tracker file matches `ai/*-<story-id>/tracker.md` (new) OR `ai/tasks/*<story-id>*` (legacy) | `Preflight: no tracker found for story <id> — run /dev-workflow plan <id> first to produce the plan and tracker.` | Run `/dev-workflow plan <id>` |
| Tracker exists but has no `## Repo Status` section | `Preflight: tracker for story <id> exists but has no \`## Repo Status\` section — Planner likely failed mid-write. Re-run /dev-workflow plan <id> to regenerate.` | Re-run `/dev-workflow plan <id>` |
| Tracker exists with `## Repo Status`, but at least one named repo isn't in `repos-paths.md` | `Preflight: tracker references repo \`<name>\` which is not in \`.claude/context/repos-paths.md\`. Run /init-workspace to add it, or correct the plan.` | Run `/init-workspace` (add the repo) or correct the plan |

Do **NOT** fall back to "create branches in every known repo as a safe default" in any of these cases — that was the pre-B2 workaround and produced orphan branches on every run.

## Steps

### 1. Read Repo Configuration and the Tracker's Repo Status

Read the repo registry files and the just-approved tracker:

```bash
cat .claude/context/repos-paths.md
cat .claude/context/repos-metadata.md
# Tracker resolution per M-14 workflow-paths.md — new canonical layout first; legacy fallback.
TRACKER=$(ls -t ai/*-${STORY_ID}/tracker.md 2>/dev/null | head -1)
[ -z "$TRACKER" ] && TRACKER=$(ls -t ai/tasks/*${STORY_ID}*.md 2>/dev/null | head -1)
echo "$TRACKER"
```

Parse:
- `repos-paths.md` → map of `repo-name → local-path`
- `repos-metadata.md` → map of `repo-name → Default Branch`
- Tracker's `## Repo Status` section → the list of repos this story actually affects

The Repo Status table is the **canonical source** for which repos this story touches. The orchestrator MUST iterate over Repo Status, not over every entry in `repos-paths.md` — the latter creates branches in repos the plan never named, leaving orphans on disk and on the remote.

### 2. Create Feature Branch in Each Affected Repo

For each repo in the tracker's Repo Status section, detect the default branch, pull latest, and create the feature branch:

```bash
# For each affected repo:
REPO_PATH="<local-path-from-repos-paths.md>"
DEFAULT_BRANCH="<Default Branch from repos-metadata.md, or from Repo Status>"

# Detect default branch (fallback if not in metadata)
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git -C "$REPO_PATH" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH=$(git -C "$REPO_PATH" remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}')
  fi
  DEFAULT_BRANCH=${DEFAULT_BRANCH:-master}
fi

# Defensive uncommitted-changes check (SKILL.md → Workspace Branch Sync ran at entry,
# but a human edit or a direct-phase invocation can leave the repo dirty by the time
# preflight runs). Refuse to switch branches silently — surface the 3-choice prompt.
CURRENT=$(git -C "$REPO_PATH" branch --show-current)
DIRTY=$([ -n "$(git -C "$REPO_PATH" status --porcelain)" ] && echo yes || echo no)
if [ "$CURRENT" != "$DEFAULT_BRANCH" ] && [ "$DIRTY" = "yes" ]; then
  # Emit the same prompt format as SKILL.md → Workspace Branch Sync → Uncommitted-changes prompt
  # and wait. Do NOT silently checkout — uncommitted work would be at risk.
  EMIT_UNCOMMITTED_PROMPT_AND_WAIT  # see SKILL.md for the verbatim format
fi

# Pull latest and create feature branch
git -C "$REPO_PATH" checkout "$DEFAULT_BRANCH" && git -C "$REPO_PATH" pull --ff-only origin "$DEFAULT_BRANCH"
git -C "$REPO_PATH" checkout -b "<team-name>/feature/<story-id>-<slug>"
```

Use the convention:
```
<team-name>/feature/<story-id>-<slug>
```

- `<team-name>`: from arguments (no default — must be provided or configured in `provider-config.md`)
- `<story-id>`: the work item / issue ID
- `<slug>`: short kebab-case description derived from the story title (the same slug the Planner used in the plan filename)

The **same branch name** is used across all repos for consistency.

### 3. Commit the Plan (single-repo workspace-is-git-repo case only)

This step moved from `commands/plan.md` to here so the plan commit lands on the newly-created feature branch instead of on the default branch.

First, resolve the per-workflow directory and check whether the workspace `ai/` directory is itself inside a git repository:

```bash
# Resolve per-workflow dir per workflow-paths.md (new) or fall back to ai/plans/ (legacy).
WORKFLOW_DIR=$(ls -td ai/*-${STORY_ID}/ 2>/dev/null | head -1)
if [ -n "$WORKFLOW_DIR" ]; then
    PLAN_FILE="${WORKFLOW_DIR}plan.md"
    git -C "$WORKFLOW_DIR" rev-parse --is-inside-work-tree 2>/dev/null
else
    PLAN_FILE=$(ls -t ai/plans/*${STORY_ID}*.md 2>/dev/null | head -1)
    git -C ai/plans/ rev-parse --is-inside-work-tree 2>/dev/null
fi
```

**If the workspace IS a git repo** (exits 0 — workspace == repo, single-repo case):

The workspace IS a code repo, so Step 2 just checked out the feature branch in the workspace itself. The uncommitted plan / tracker files created in Phase 2 came along with the `git checkout -b` (uncommitted changes carry across checkouts). Now commit **only the plan file** (the tracker stays uncommitted per orchestrator rule #8):

```bash
# New layout: commit the whole per-workflow directory's plan; tracker stays uncommitted.
# Legacy layout: commit only ai/plans/ — tracker in ai/tasks/ stays uncommitted.
git add "$PLAN_FILE"
git commit -m "$(cat <<'EOF'
#<STORY-ID> #TPLAN: add approved implementation plan

Co-Authored-By: Claude Code <noreply@anthropic.com>
EOF
)"
```

**If the workspace is NOT a git repo** (exits non-zero — workspace-separated case):

**Skip this step entirely.** The plan stays at `<WORKSPACE_ROOT>/ai/<YYYY-MM-DD>-<work-item-id>/plan.md` (new) or `<WORKSPACE_ROOT>/ai/plans/<id>.md` (legacy) per orchestrator rule #8 and travels into each affected repo alongside the tracker and test outline in Phase 6 (`commands/create-pr.md` Step 6 Case B).

Do NOT `cp` or otherwise copy the plan into a code repo at this phase — rule #8 forbids it, and the `bash-write-guard` hook will block any Bash write to `/ai/` paths by design. If a command file step appears to conflict with rule #8, surface the conflict to the human per the Conflict-Surfacing Rule in `context/orchestrator-rules.md` rather than inventing a workaround.

### 4. Confirm

Report per-repo branch status to the human:

```
Branches created:
  AuthService     → backend/feature/12345-add-subscriptions  (from main)
  BillingService  → backend/feature/12345-add-subscriptions  (from main)
  ApiGateway      → backend/feature/12345-add-subscriptions  (from main)

Plan commit: <committed on backend/feature/12345-add-subscriptions | deferred to Phase 6 (workspace not a git repo)>
```

If any repo fails (e.g., uncommitted changes, branch already exists), report the error and ask the human how to proceed.

### Backward Compatibility

If only one repo is involved (single-repo story), this behaves identically to multi-repo — one branch is created in one repo, and the plan commit (single-repo workspace-is-git-repo case) lands on that one branch.

### Behaviour Change vs Pre-B2

Pre-B2, preflight ran before Phase 1 and created branches in **every** repo listed in `repos-paths.md` as a "safe default" because no plan existed yet. That produced orphan branches in unaffected repos every single run.

Post-B2, preflight runs after Phase 2 and reads the plan's Repo Status section, creating branches in exactly the affected repos. If you run `/dev-workflow preflight <story-id>` standalone (direct phase mode) before Phase 2 has completed, this step stops with an error pointing at `commands/plan.md` rather than guessing.

## Next Phase

Proceed to **Phase 3: Develop** — read and execute `commands/develop.md`.
