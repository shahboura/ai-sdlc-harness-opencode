---
name: dev-workflow
description: >
  Master orchestrator for the AI-driven development workflow. Use when
  starting a new User Story / Issue implementation. Coordinates the Planner, Developer,
  Reviewer, and Tester agents through all 7 phases with human approval gates.
  Supports multiple work item providers (ADO, Jira, GitLab, GitHub, Zoho, local-markdown) and git providers
  (ADO, GitLab, GitHub, gh-cli, glab-cli) via provider adapters. Supports multi-repo stories with
  parallel developer agents across repos while maintaining sequential execution
  within each repo.
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Agent, mcp__azure-devops__*, mcp__jira__*, mcp__gitlab__*, mcp__github__*, mcp__zoho__*
argument-hint: "[command] <Work-Item-ID> [project-name] [team-name]"
---

# AI-Driven Development Workflow

## Provider Resolution

Before executing any command, **read `.claude/context/provider-config.md`** to determine
the active work item and git providers. All MCP tool calls throughout the workflow are
resolved through the provider adapters in `skills/providers/<provider>/`.

## Workspace State (P0 Gate — IMPL-02-03 / CC-05.4)

<!-- Changed by: dev-workflow-plan.md [M-02] [IMPL-02-03]
     Reason: Make `.claude/context/state.md` a read-on-startup file and refuse P1 entry without `Bootstrap completed` per GAP-12.
     CC conventions applied: CC-05.4 (phase boundary enforcement). -->

Before executing **any** command, also **read `.claude/context/state.md`**. The orchestrator MUST:

1. Verify the file exists. If absent → refuse to proceed and instruct the user to run `/init-workspace`. **Do not attempt to delegate `/init-workspace` to a sub-agent** (`/init-workspace` is a human-only command per its hard constraint).
2. Verify a `Bootstrap completed:` line is present with a `YYYY-MM-DD HH:MM UTC` timestamp. If absent → refuse to proceed and surface:
   > `❌ Bootstrap incomplete — run /init-workspace before /dev-workflow.`
3. On successful boot, update `Workflow active:` and `Last metric stamp:` lines as each phase fires (see `agents/shared/tracker-field-schema.md` for the canonical metric labels).

This is the **P0 → P1 boundary gate** declared in the phase spec. The check is structural — never bypassed.

## v1.x Layout Detection (v2.0 migration gate)

<!-- Created by: README v2.0 release notes
     Reason: Workspaces created against the v1.x harness use `ai/plans/<id>.md` +
     `ai/tasks/<id>.md`. The v2.0 harness writes only to the per-workflow
     `ai/<YYYY-MM-DD>-<work-item-id>/` layout (CC-05.7). If the orchestrator
     enters a v1.x workspace it would silently start a parallel layout, leaving
     the user with two divergent state trees. The gate below refuses that
     mixed state. -->

After the state.md check passes (and before any phase command file runs), check for the v1.x layout:

```
test -d ai/plans/ -o -d ai/tasks/
```

If either directory exists AND contains at least one `.md` file:

```
find ai/plans/ -maxdepth 1 -name "*.md" 2>/dev/null | head -1
find ai/tasks/ -maxdepth 1 -name "*.md" 2>/dev/null | head -1
```

→ Refuse to proceed with this exact message:

> `❌ v1.x layout detected — run /dev-workflow migrate before proceeding.`
>
> `   Found legacy artifacts under ai/plans/ and/or ai/tasks/. v2.0 writes`
> `   workflow artifacts to ai/<YYYY-MM-DD>-<work-item-id>/ (per CC-05.7).`
> `   The migrate command moves your existing stories into the new layout`
> `   non-destructively. Re-run /dev-workflow <id> after migration.`

The single exception is the migrate command itself — `/dev-workflow migrate` must be allowed to run even when the v1.x layout is present (that's its entire purpose). Detect this by inspecting the first positional argument:

- If `argv[1] == "migrate"` → skip the v1.x refusal and proceed into `commands/migrate.md`.
- Otherwise → refuse as above.

This gate is **structural** — never bypassed by phase argument, story ID prefix, or `--force` flag. The two layouts cannot coexist; users must migrate first.

## Workspace Branch Sync (workflow-entry precondition)

<!-- Created: ensures the workspace is on a known clean state (default branch + latest pulled)
     before planning runs. Closes the gap where Phase 1 / Phase 2 ran against whatever branch the
     workspace happened to be on, producing plans against stale state. Feature branches are still
     created only after Plan Approval (Phase 2.5 preflight) for the repos the plan named — this
     section only ensures the *default* branch is current.
     Constraint: never switch a branch silently when uncommitted changes are present; always
     surface a 3-choice prompt and wait. -->

After the state.md and v1.x layout checks pass, but before executing any phase command, ensure every repo in `.claude/context/repos-paths.md` is on its default branch with the latest pulled. This is the workspace's "known clean state" precondition — Phase 1 (story fetch) and Phase 2 (plan generation) run against this state. Feature branches are still created later, in Phase 2.5 preflight, only for the repos the plan named.

### When to run

| Condition | Action |
|-----------|--------|
| First positional argument is `migrate` | **Skip** — migrate operates on workspace files only. |
| First positional argument is `resume` | **Skip** — resume reads existing state; never touches branches. |
| First positional argument is `hotfix` | **Skip** — hotfix has its own branch-creation semantics in `commands/hotfix.md`. |
| No tracker exists for `<STORY_ID>` | **Run sync** — fresh workflow. |
| Tracker exists, `Plan approved` is `—` (unset) | **Run sync** — pre-Plan-Approval. |
| Tracker exists, `Plan approved` is a timestamp | **Skip** — past Phase 2.5; feature branches are in play and switching to default would orphan in-progress work. |

Tracker resolution follows `commands/preflight.md` Step 1 (new canonical layout first, legacy fallback). When neither layout exists for `<STORY_ID>`, treat as "no tracker" and run sync.

### Procedure (per repo)

For each `<repo-name>: <repo-path>` in `.claude/context/repos-paths.md`:

```bash
REPO_PATH="<from repos-paths.md>"
DEFAULT_BRANCH="<from repos-metadata.md — Default Branch column>"

# Fall back to symbolic-ref if metadata is silent.
if [ -z "$DEFAULT_BRANCH" ]; then
  DEFAULT_BRANCH=$(git -C "$REPO_PATH" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  DEFAULT_BRANCH=${DEFAULT_BRANCH:-main}
fi

CURRENT=$(git -C "$REPO_PATH" branch --show-current)
DIRTY=$([ -n "$(git -C "$REPO_PATH" status --porcelain)" ] && echo yes || echo no)

if [ "$CURRENT" = "$DEFAULT_BRANCH" ]; then
  # Already on default — fetch + fast-forward pull only.
  git -C "$REPO_PATH" fetch origin "$DEFAULT_BRANCH"
  git -C "$REPO_PATH" pull --ff-only origin "$DEFAULT_BRANCH"
elif [ "$DIRTY" = "yes" ]; then
  # Different branch + uncommitted changes — MUST prompt; see below.
  EMIT_UNCOMMITTED_PROMPT_AND_WAIT
else
  git -C "$REPO_PATH" checkout "$DEFAULT_BRANCH"
  git -C "$REPO_PATH" fetch origin "$DEFAULT_BRANCH"
  git -C "$REPO_PATH" pull --ff-only origin "$DEFAULT_BRANCH"
fi
```

### Uncommitted-changes prompt (mandatory)

When the per-repo procedure hits the `DIRTY=yes` + non-default-branch case, the orchestrator MUST emit this prompt verbatim (substituting the bracketed values) and wait for an explicit response. **Never silently switch a branch when uncommitted changes are present.**

```
⚠ Workspace Branch Sync — uncommitted changes detected

  Repo: <repo-name>
  Path: <repo-path>
  Current branch: <CURRENT>
  Default branch: <DEFAULT_BRANCH>
  Uncommitted file(s): <N>

  Switching to <DEFAULT_BRANCH> may put these changes at risk if they
  conflict with the target branch.

  Options:
    [a] Stash → switch → pull. The orchestrator runs:
          git -C "<repo-path>" stash push -u -m "dev-workflow pre-sync <story-id>"
          git -C "<repo-path>" checkout <DEFAULT_BRANCH>
          git -C "<repo-path>" pull --ff-only origin <DEFAULT_BRANCH>
        The stash is NOT auto-popped. After the workflow completes you can
        `git -C "<repo-path>" stash list` and `stash pop` selectively.

    [b] Skip this repo's sync. Leave the repo on <CURRENT> as-is.
        ⚠️ If <repo-name> ends up in the plan's Repo Status section, Phase
        2.5 preflight will refuse to create the feature branch from a
        non-default starting state and the workflow will stall.

    [c] Abort the workflow. The orchestrator exits cleanly; you can commit /
        stash / discard manually, then re-run /dev-workflow <story-id>.

Reply with [a], [b], or [c].
```

The orchestrator does NOT infer a default. If the reply does not parse as `[a]`, `[b]`, or `[c]`, re-render the prompt with a one-line preamble:

```
⚠️ Could not parse: "<verbatim reply>". Expected [a], [b], or [c]. Please reply again.
```

If multiple repos hit the prompt, ask **one at a time** in the order they appear in `repos-paths.md`. Do NOT batch the prompts — each repo is an independent decision and batching obscures the per-repo state.

### Pull failures

| Failure | Detection | Response |
|---------|-----------|----------|
| Non-fast-forward | `git pull --ff-only` exits non-zero with "Not possible to fast-forward" | Surface the divergence with `git -C "<repo-path>" log --oneline origin/<DEFAULT_BRANCH>..HEAD`; do NOT force-pull, do NOT rebase, do NOT discard. Wait for human direction. |
| No upstream configured | `git pull` reports "There is no tracking information" | Warn the human; proceed with local default-branch state. The plan may be based on stale code — note this in the workflow context. |
| Auth failure | `git pull` reports network / credential error | Warn the human; proceed with local default-branch state. Suggest running `git fetch` manually after fixing auth, then re-running. |

### Skip recap (when sync is bypassed)

When the when-to-run table says **Skip**, no `git` operations run and no prompt is emitted. The skip path is silent.

### Direct phase mode

Workspace Branch Sync runs at workflow ENTRY regardless of whether the user invoked the full pipeline (no command) or a specific phase (e.g. `/dev-workflow plan <id>`). The when-to-run table handles the resume case — if `Plan approved` is already a timestamp, sync is automatically skipped. This is the correct behaviour: `develop`, `test`, `create-pr`, `review-response`, and `reconcile` all operate on the feature branch, and forcing a default-branch switch would undo Phase 2.5's work.

## Usage

```
/dev-workflow <Work-Item-ID> [project-name] [team-name]            # Full pipeline
/dev-workflow <command> <Work-Item-ID> [project-name] [team-name]   # Specific phase
/dev-workflow request <Work-Item-ID> "<request text>"               # Ad-hoc request mid-flow
```

**Examples:**
- `/dev-workflow 123456 MyProject backend` (ADO)
- `/dev-workflow PROJ-123 PROJ backend` (Jira)
- `/dev-workflow 42 mygroup/myproject backend` (GitLab)
- `/dev-workflow plan 123456` (specific phase)
- `/dev-workflow request 123456 "the drawer doesn't close on Escape"` (ad-hoc mid-flow)

## Argument Parsing

Parse `$ARGUMENTS`:

- **First token**: If it looks like a work item ID (numeric, or matches Jira key pattern
  like `PROJ-123`), treat as Story/Issue ID and run the **full pipeline**.
  If it matches a command name, use that command (**direct phase mode**).
- **Story/Issue ID** (required): The Work Item ID (format depends on provider).
- **Project name** (optional): Defaults from `provider-config.md`.
- **Team name** (optional): Defaults from `provider-config.md` if configured, otherwise must be provided.

Pass all three values to downstream commands and agents.

## Commands

<!-- Changed by: dev-workflow-plan.md [M-11] [IMPL-11-03]
     Reason: Declare that command files are execution scripts per CC-07.3 — each command
     file is the orchestrator's step-by-step actions for its phase.
     CC conventions applied: CC-07.3. -->

> Each `commands/*.md` file is the **canonical execution script** for its phase — Trigger, Preconditions, Steps, Artifacts, and Failure Modes are all declared inline in the command file. There is no external phase-contract document.

| Command | File | Phase | Description |
|---------|------|-------|-------------|
| `requirements` | `commands/requirements.md` | 1 | Requirements Ingestion |
| `plan` | `commands/plan.md` | 2 | Planning & Approval |
| `quick` | `commands/quick.md` | Q | Quick Mode (fast-path: Developer + Reviewer only; no Planner/Tester per CC-05.8) |
| `preflight` | `commands/preflight.md` | 2.5 | Branch creation (only in repos the plan named) + plan commit |
| `develop` | `commands/develop.md` | 3 | Development Loop |
| `approve-impl` | `commands/approve-impl.md` | 4 | Human Approval of Implementation |
| `test` | `commands/test.md` | 5 | Test Implementation |
| `security-review` | `commands/security-review.md` | 5.5 | Static Security Review |
| `create-pr` | `commands/create-pr.md` | 6 | PR Creation |
| `review-response` | `commands/review-response.md` | 7 | PR Review Response |
| `reconcile` | `commands/reconcile.md` | 8 | Post-Merge Reconciliation |
| `resume` | `commands/resume.md` | R | Workflow State Recovery |
| `metrics` | `commands/metrics.md` | 9 | Metrics & Observability |
| `report` | `commands/report.md` | utility | Aggregate metrics report (--since, --format md\|json, --story) |
| `hotfix` | `commands/hotfix.md` | re-entry | Hotfix / Rollback Re-Entry |
| `request` | `commands/handle-request.md` | inter-gate | Ad-Hoc Request Handling |
| `migrate` | `commands/migrate.md` | utility | One-time v1.x → v2.0 workspace migration |

If the first token doesn't match a command name and isn't numeric, show this usage table and stop.

## Orchestrator Rules

**Before executing any command**, read `context/orchestrator-rules.md`. These rules apply to
ALL phases and cannot be overridden by individual commands.

## Full Pipeline Mode

When no command is specified (first argument is the Story ID), execute all commands in sequence:

1. `requirements` → 2. `plan` → 3. `preflight` → 4. `develop` → 5. `approve-impl` → 6. `test` → 7. `security-review` → 8. `create-pr`

**Why preflight runs after plan**: the Planner identifies which repos are actually affected by the story in Phase 2's Repo Status section. Running preflight before that would force creating feature branches in every known repo as a safe default (wasteful and produces orphan branches), or guessing — both bad. With preflight after plan, the orchestrator creates branches in exactly the repos the plan names. The plan commit moves into preflight too (single-repo workspace-is-git-repo case only), so it lands on the just-created feature branch rather than the default branch.

**Why security-review (P5.5) runs between test (P5) and create-pr (P6)**: SAST + dependency scanning is cheapest right after tests pass (full source tree is on the feature branch, all production code is in place, the tracker is still mutable). Running it pre-PR catches medium+ severity findings before the PR opens, so the reviewer's pre-PR holistic review at Phase 6 doesn't waste cycles on issues an automated scanner would flag. The phase has its own gate (#2.5) when findings ≥ medium severity — the human picks `waive` / `fix-now` / `defer`; the workflow only proceeds to `create-pr` once the gate clears. See `commands/security-review.md`.

After `create-pr` completes, `review-response` is **not** run automatically — it is triggered
on demand (via direct phase mode) once PR review comments arrive from human reviewers.

The `request` command is also **on-demand** — it is invoked when the human submits an ad-hoc
change request between approval gates (at GATE #2 / GATE #3 instead of `APPROVED`, or
mid-phase via `/dev-workflow request <id> "..."`). It triages each request against the
approved plan, creates new tasks under a separate `## Ad-hoc Tasks (Batch <N>)` heading for
in-scope items, and re-enters the Phase 3 TDD loop scoped to those tasks. See
`commands/handle-request.md`.

Read each command file **as you reach that phase**. Do not pre-load all command files — load
one at a time to conserve context.

After each command completes, proceed to the next automatically (unless a human gate blocks).

## Direct Phase Mode

When a command is specified, read its command file and execute it. Each command file states
its own prerequisites — verify them before proceeding.

This mode is useful for:
- **Resuming** a workflow after a session interruption
- **Re-running** a specific phase (e.g., re-running tests after manual fixes)
- **Debugging** a single phase in isolation
