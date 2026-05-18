---
name: pr-creator
description: >
  Create a Pull Request / Merge Request after all tasks and tests are approved.
  Assembles PR summary from the task tracker, validates branch naming, and
  creates the PR/MR via the configured git provider. Links back to the work item
  via the work item provider. Supports ADO, GitLab, GitHub, and Jira.
  Used during Phase 6 of the workflow.
allowed-tools: Bash, Read, Grep, Glob, mcp__azure-devops__*, mcp__jira__*, mcp__gitlab__*, mcp__github__*
argument-hint: "[Work-Item-ID] [team-name] [repo-name]"
---

# PR Creator (Provider-Agnostic)

## Purpose

Create a Pull Request (or Merge Request) after all development tasks and tests have been
approved by the Reviewer Agent. Links the PR/MR back to the work item in the configured
provider.

## Inputs

- `$ARGUMENTS[0]` — Work Item / Issue ID
- `$ARGUMENTS[1]` — Team name (for branch naming)
- `$ARGUMENTS[2]` — (Optional) Repo name. When provided, operates on a specific repo
  from `repos-paths.md`. When omitted, operates on the current working directory (legacy mode).

## Provider Resolution

1. **Read `.claude/context/provider-config.md`** to determine:
   - The **git provider** (ado, gitlab, github) — for PR/MR creation
   - The **work item provider** (ado, jira, gitlab, github) — for linking
2. **Read the git provider adapter** from `skills/providers/<git-provider>/pull-requests.md`
   (or `merge-requests.md` for GitLab).
3. **If work item provider differs from git provider**, also read the work item provider's
   `pull-requests.md` adapter for the linking step (e.g., `providers/jira/pull-requests.md`
   for adding a remote link in Jira after creating a GitLab MR).

## Pre-Flight Checks

<!-- Updated by: dev-workflow-plan.md [M-14] [IMPL-14-02]
     Reason: Read both layouts per CC-05.7 / workflow-paths.md.
     CC conventions applied: CC-05.7, CC-04.3. -->

1. **Read the tracker** for `$ARGUMENTS[0]`. Prefer the new canonical layout (`ai/*-<work-item-id>/tracker.md` — one tracker per per-workflow directory per [workflow-paths](../dev-workflow/context/workflow-paths.md)); fall back to the legacy layout (`ai/tasks/*<id>*.md`) during the migration window.
2. **Verify** every task (including T-TEST / T-TEST-\<RepoName\>) has status ✅ Done.
3. If any task is not done, **STOP** and report which tasks remain.
4. **If repo name provided** (`$ARGUMENTS[2]`): read `.claude/context/repos-paths.md`
   to resolve the repo name to a local path. All git commands below use `git -C <repo-path>`.
5. **Read `.claude/context/repos-metadata.md`** and resolve the **Default Branch** for the
   repo. Pass this as `<default-branch>` into every step below — do NOT assume `main`.

## Context Block (read from caller)

The orchestrator (`create-pr.md` Step 7) passes a PR_MODE context block. Read it before
Step 0:

```
PR_MODE: <standard | draft>
```

- `standard` (default) — open a normal, review-ready PR.
- `draft` — open the PR in draft state. The harness's internal Phase 6 review has already
  passed; `draft` signals to the team that external review / merge is intentionally
  deferred (e.g. waiting on a dependent PR in another repo, or on out-of-band sign-off).

If the context block is absent, treat as `standard`.

## Steps

### 0. Idempotency Check (Find Existing PR for the Branch)

Before any `git push`, query the git provider for an open PR/MR on this branch via the
adapter's `pr.find_for_branch` capability
(see `skills/providers/<git-provider>/pr-comments.md` for the canonical primitive — it is
shared between Phase 6 and Phase 7).

```bash
# GitHub example (gh-cli / github adapters):
gh pr list \
  --repo <owner>/<repo> \
  --head <feature-branch> \
  --state open \
  --json number,url,isDraft \
  --limit 1
```

If the adapter declares `pr.find_for_branch: ❌` (the provider has no path to look up by
branch), record `Idempotency check: skipped (capability unavailable)` and proceed to
Step 1 — the workflow falls back to the provider's natural rejection of duplicate PRs
on push.

**If an open PR/MR is returned:**

Present to the human:

```
## Existing PR/MR Detected

An open <PR | MR> already exists for branch `<feature-branch>`:
- URL: <url>
- Number: #<number>
- State: <open | draft>

Options:
  [1] Reuse — record the existing URL in the tracker and skip PR creation (push will
      still happen below if local commits are ahead of remote).
  [2] Fail — stop this invocation. Manual investigation needed (e.g. close the existing
      PR or force-push intentionally).

What would you like to do?
```

Wait for the response. **Do not** auto-pick; the human picks because the existing PR may
carry review comments, reviewers, or CI runs the orchestrator can't see. On `[1]`, skip
Step 6 entirely and proceed to Step 7 with the existing PR's metadata. On `[2]`, exit
without making any changes.

**Output contract — `Reuse:` flag.** When this skill returns to the caller (typically
`commands/create-pr.md` Step 7), it MUST report whether the PR was newly created or
reused, so the caller can take the right Step 9 path. The skill (run inline in the
orchestrator session, not as a subagent) has no `📋 AGENT STATUS` analogue, so the
output contract is a **literal terminator block** the orchestrator-side parser can grep
against deterministically. Emit it as the last thing the skill prints, exactly as shown
below — no surrounding prose, no leading bullets, no code-fence wrapping:

```
--- PR CREATOR RESULT ---
Reuse: <true | false>
PR URL: <url>
PR Number: <number>
PR State: <open | draft>
```

The `--- PR CREATOR RESULT ---` line is the parser anchor. The four fields below it are
fixed-name, one-per-line. Empty values for unknown fields are not allowed — surface a
specific value or skip the field (and the caller treats the absence as a parse error).

`Reuse: true` is set whenever Step 0 detected an existing PR and the human picked `[1]`.
`Reuse: false` is set in every other case (no existing PR found, or `pr.find_for_branch`
declared `❌`). The flag is consumed by `commands/create-pr.md` Step 9 to decide between
the amend+force-push path (create) and the fresh-commit+fast-forward path (reuse) — see
that file for the rationale.

### 1. Validate Branch Name

Verify the branch in the target repo follows the convention:
```
$ARGUMENTS[1]/feature/$ARGUMENTS[0]-<brief-slug>
```

If a repo name is provided, check via `git -C <repo-path> rev-parse --abbrev-ref HEAD`.
If not on the correct branch, report the issue.

### 2. Gather Summary Data

From the task tracker and git log, collect:
- Story / Issue ID and title
- **Repo name** (if multi-repo, include which repo this PR covers)
- List of completed tasks for this repo (filter by Repo column) with commit hashes
- Number of files changed (`git -C <repo-path> diff --stat` against default branch)
- Test coverage percentage on new/modified code only (from the latest run of the repo's configured test command, per `language-config.md`)

### 3. Present Summary to Human

Display:
```markdown
## PR Summary — <ID-DISPLAY>: <Title>

### Tasks Completed
| Task | Title | Commits |
|------|-------|---------|
| T1 | ... | `abc123` |
| T2 | ... | `def456` |
| T-TEST | ... | `ghi789` |

### Stats
- Files changed: X
- Test coverage (new/modified code): XX%
- Plan: ai/plans/...

### Proposed PR/MR
- **Title**: <ID-DISPLAY>: <summary>
- **Source**: <team>/feature/<id>-<slug>
- **Target**: <default-branch>
- **Provider**: <git-provider>
```

Where `<ID-DISPLAY>` follows the work item provider's format:
- ADO: `#12345`
- Jira: `PROJ-123`
- GitLab: `#123`
- GitHub: `#123`

### 4. Pre-Push Preflight Summary (non-interactive)

The authoritative human gate for PR creation is **GATE #3 in `commands/create-pr.md` Step 5** — it has already cleared by the time this skill runs (the orchestrator only invokes pr-creator on `PR_MODE: standard` / `PR_MODE: draft`). Do **not** re-prompt the human here; a second gate creates two-prompt fatigue, erodes the signal value of GATE #3, and the harness's pattern is one gate per decision.

Instead, emit a terse non-blocking preflight line so the human can sanity-check what is about to fire — then proceed directly to Step 5:

```
## pr-creator preflight — about to push and create
- Repo: <repo-name> (<repo-path>)
- Push target: origin
- Branch: <feature-branch>
- Target: <default-branch>
- PR mode: <standard | draft>
- Idempotency: <create | reuse PR/MR #<id>>
```

The preflight line is informational only; the orchestrator does not wait for input.

> **Note for direct `/pr-creator` invocations** (outside the `/dev-workflow create-pr` pipeline): the caller is responsible for sequencing its own human gate before invoking this skill — pr-creator is non-interactive by design. The two callers in tree are `commands/create-pr.md` Step 7 (gated by GATE #3) and tooling tests; both satisfy this contract.

### 5. Push Branch to Remote

Push the feature branch to the remote so the PR/MR can reference it:

```bash
git -C <repo-path> push -u origin $(git -C <repo-path> rev-parse --abbrev-ref HEAD)
```

Verify the push succeeded before proceeding. If it fails, report the error and stop.

**Note:** `git push` is not pre-approved — the user will be prompted to confirm.

#### Auth-failure copy

If `git push` fails with an authentication error (HTTP 401/403, "Permission denied",
`could not read Username`, `gh: not authenticated`), surface this to the human verbatim:

```
PR creation blocked by an authentication failure on `git push`.

The git provider's adapter at `skills/providers/<git-provider>/pull-requests.md`
documents the auth prerequisites — re-check the **Prerequisites** section. Common
fixes:
  - GitHub (gh-cli / github): run `gh auth status`; re-authenticate via `gh auth login`
    if the session has expired.
  - ADO / GitLab MCP: confirm the configured PAT has not been revoked or rotated.

Re-run `/dev-workflow create-pr <story>` after the auth is restored. The
idempotency check in Step 0 will pick up where this run left off (no duplicate
PR will be created).
```

### 6. Create the PR / MR

Use the **git provider adapter** for the exact tool and parameters. If Step 0 returned an
existing PR and the human chose `[1] Reuse`, **skip this step entirely** and pass the
existing URL/number forward to Step 7.

**Draft mode:** when `PR_MODE: draft` was passed by the orchestrator, set the draft flag
on the create call as documented per adapter below. The PR/MR is still created and the
work-item link in Step 7 still fires — only the review state changes.

#### ADO
```
mcp__azure-devops__repo_create_pull_request(
  repositoryId=<repo-name>,
  project=<project>,
  sourceRefName="refs/heads/<branch>",     # ADO requires refs/heads/ prefix
  targetRefName="refs/heads/<default>",
  title="<ID-DISPLAY>: <summary>",
  description=<PR-body>,
  isDraft=<true if PR_MODE=draft else false>
)
```

#### GitLab
```
mcp__gitlab__create_merge_request(
  projectId=<project-path>,
  sourceBranch="<branch>",                 # No prefix needed
  targetBranch="<default>",
  title="<ID-DISPLAY>: <summary>",
  description=<MR-body>,                   # Include "Closes #IID" if GitLab is also WI provider
  removeSourceBranch=true,
  draft=<true if PR_MODE=draft else false>
)
```

GitLab also accepts a leading `Draft:` prefix in the title as an alternative — the
`draft` parameter is the canonical path.

#### GitHub
```
mcp__github__create_pull_request(
  owner=<owner>,
  repo=<repo>,
  head="<branch>",                         # No prefix needed
  base="<default>",
  title="<ID-DISPLAY>: <summary>",
  body=<PR-body>,                          # Include "Closes #NUMBER" if GitHub is also WI provider
  draft=<true if PR_MODE=draft else false>
)
```

#### GitLab CLI (`glab-cli`)
```bash
glab mr create \
  --repo <group>/<project> \
  --source-branch <branch> \
  --target-branch <default> \
  --title "<ID-DISPLAY>: <summary>" \
  --description "<MR-body>" \
  --remove-source-branch \
  [--draft]   # include only when PR_MODE: draft
# MR URL is printed to stdout — capture and record it in the tracker
```

No MCP server required. Bare branch names (no `refs/heads/` prefix).
Include `Closes #IID` in `--description` if GitLab Issues is the work item provider.

#### GitHub CLI (`gh-cli`)
```bash
gh pr create \
  --repo <owner>/<repo> \
  --head <branch> \
  --base <default> \
  --title "<ID-DISPLAY>: <summary>" \
  --body "<PR-body>" \
  [--draft]   # include only when PR_MODE: draft
# PR URL is printed to stdout — capture and record it in the tracker
```

No MCP server required. Bare branch names (no `refs/heads/` prefix).
Include `Closes #NUMBER` in `--body` if GitHub Issues is the work item provider.

### 7. Link PR/MR to Work Item

The linking mechanism depends on the **combination** of work item provider and git provider:

| Work Item Provider | Git Provider | Linking Method |
|-------------------|-------------|----------------|
| ADO | ADO | `wit_link_work_item_to_pull_request` (native) |
| Jira | GitLab | Add `Jira: PROJ-123` in MR description + `mcp__jira__add_remote_link` |
| Jira | GitHub | Include `PROJ-123` in PR title for smart commits + `mcp__jira__add_remote_link` |
| GitLab | GitLab | `Closes #IID` in MR description (auto-link) |
| GitHub | GitHub | `Closes #NUMBER` in PR body (auto-link) |
| Jira | ADO | `mcp__jira__add_remote_link` with ADO PR URL |
| GitLab | GitHub | `Closes owner/repo#IID` cross-reference |
| GitHub | GitLab | `Closes group/project#NUMBER` cross-reference |

**CLI git providers (`gh-cli`, `glab-cli`)** — use the same linking mechanism as their MCP-backed equivalents. The CLI is just an alternate transport for the same underlying provider:

- `gh-cli` ≡ `GitHub` for linking — when `gh-cli` is the git provider, apply every row above that has `GitHub` in the *Git Provider* column. The keyword (`Closes #NUMBER` / `Closes owner/repo#NUMBER`) lands in the PR body via `gh pr create --body`, behaving identically to the MCP path.
- `glab-cli` ≡ `GitLab` for linking — same substitution. The keyword lands in the MR description via `glab mr create --description`.

The PR-creation commands themselves differ between the MCP and CLI transports (see [Section 6](#6-create-prmr-for-each-affected-repo) — `gh pr create` / `glab mr create` vs the MCP `mcp__github__create_pull_request` / `mcp__gitlab__create_merge_request`), but the linking keyword and its consumer are unchanged.

**If work item provider ≠ git provider:**
1. Create the PR/MR via the git provider (Step 6).
2. Use the work item provider's pull-requests adapter to link back.
3. As fallback, add a comment on the work item with the PR/MR URL.

### 8. Update Tracker

Add PR/MR link to the tracker file and mark workflow as complete.

## PR/MR Title Convention

Adapts based on work item provider's ID format:
- **ADO**: `#<STORY-ID>: <summary>` / `#<STORY-ID>: <summary> [<RepoName>]`
- **Jira**: `<ISSUE-KEY>: <summary>` / `<ISSUE-KEY>: <summary> [<RepoName>]`
- **GitLab**: `#<IID>: <summary>` / `#<IID>: <summary> [<RepoName>]`
- **GitHub**: `#<NUMBER>: <summary>` / `#<NUMBER>: <summary> [<RepoName>]`

## Rules

- **Never create a PR/MR without human approval.**
- PR/MR title MUST include the Work Item / Issue ID.
- All commits in the PR must reference the Story/Issue ID and Task ID.
- Verify no merge commits from default branch — rebase if needed.
- Always read the provider adapter for exact tool names and parameters before making MCP calls.
- Every PR/MR body MUST end with the attribution footer:
  ```
  ---
  🤖 Generated with [Claude Code](https://claude.ai/claude-code)
  ```
