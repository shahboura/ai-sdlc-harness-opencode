# Changelog

All notable changes to `ai-sdlc-harness` are documented here.

---

## [Unreleased]

### Features

- **`bash-write-guard` hook** — new `PreToolUse` guard on `Bash` that closes the loophole where shell-driven writes (redirects, `tee`, `cp`, `mv`, `install`, `dd of=…`) bypassed the existing Write/Edit guards. Blocks shell writes that target `ai/` (orchestrator/planner territory) or any sensitive file pattern. When the payload carries subagent identity, applies role-aware rules: reviewers cannot write at all; planners may only write under `ai/`.
- **Shared hook library (`scripts/_hook-lib.sh`)** — every guard hook now sources a common helper for the python probe, payload reading, dotted-path field extraction (including list-shaped `tool_response` blocks), exit helpers, and workspace-root walk-up. Removes duplicated JSON parsing across eight scripts.
- **Structural commit-arg parser (`scripts/_git_argparse.py`)** — `shlex`-based parser for `git commit` invocations replaces the old single-regex extractor. Handles `git -C <path>`, `git -c key=val`, env-var prefixes, chained commands (`cd repo && …`, `(cd repo; …)`), multiple `-m` flags, `--message=`, `-F`, `--amend`, and heredoc bodies (including `<<-TAG` tab-stripping).
- **Fail-policy inventory (`scripts/README.md`)** — every hook now declares fail-closed vs. fail-open in a single table so the contract is reviewable at a glance.
- **Orchestrator constraint #14 — Conflict-Surfacing Rule.** New rule in `skills/dev-workflow/context/orchestrator-rules.md`: when a command-file step appears to conflict with an orchestrator rule, a hook block, another command file, or discovered state, the orchestrator must stop and surface the conflict to the human — never silently drop the step, invent a workaround (`cp` into a hook-guarded path, `--no-verify`, etc.), or declare itself authoritative over either side. Triggered by a session where the orchestrator silently skipped a Phase 2 commit step by citing rule #8 as an "override" instead of surfacing the contradiction.

### Fixes

- **`validate-commit-msg` rewritten to fail closed.** The old regex-based extractor missed `git -C` commits, multiple `-m` flags, `--message=`, `-F`, `--amend`, indented heredocs, and the Phase 5 `test-harden` exception — and silently allowed anything it couldn't parse. The rewrite reconstructs the message structurally and refuses commits whose form is undetermined. Also drops the "description must start lowercase" rule that rejected legitimate proper nouns (`AWS`, `URL`, `OAuth`).
- **`tracker-transition-guard` rewritten.** Matcher broadened from `Edit`-only to `Write|Edit|MultiEdit`. The hook now applies the edit in-memory, diffs task statuses by ID, and validates every row that changed (the old hook only checked the first emoji). Whole-file `Write` is covered; metadata-only edits (Notes, Commit, Verdict, timestamps) pass through.
- **`sensitive-file-guard` rewritten.** Matcher broadened to `Write|Edit|MultiEdit|NotebookEdit`. Deny-list extracted into a shared `_sensitive_patterns.py` module (reused by `bash-write-guard`) and expanded — most notably catching `.env.local`/`.env.production` that the old `\.env$` regex missed.
- **`tracker-update-reminder` rewritten.** Fixes a `PROMPT=… echo … | python` envvar leak that broke the orchestrator-prompt task-ID fallback. Accepts the recent SDK's list-of-content-blocks `tool_response` shape. Tracker selection now matches story ID against tracker filenames (with mtime as fallback) instead of blindly taking the most recent file.
- **`agent-status-check` rewritten.** Removed the `/tmp/agent-status-debug.json` write that ran on every invocation. Presence check upgraded from "phrase appears anywhere" to "phrase near the response tail with a non-empty `Outcome:` or `Verdict:` field" — mid-prose mentions no longer satisfy the gate. Fails closed on extractable responses; fails open with a stderr warning when no response text is locatable.
- **`squash-merge-verify` rewritten.** Command detection now `shlex`-aware, handling `cd repo && git merge --squash …`, subshells, env-var prefixes, and `git -c` flags. Implicit cwd from `cd <path>` is carried into the verification. Dropped the brittle `MERGE_MSG`-file AND-condition; relies on `git diff --name-only --diff-filter=U` alone.
- **`stop-failure-recovery` cwd dependency removed.** The inline marker-writer assumed cwd was the workspace root, so a directory change before failure silently swallowed the marker. Replaced with `stop-failure-marker.sh` using the shared workspace walk-up.
- **Workflow consistency: Phase 6 / Phase 7 file moves into a code repo now use Read+Write, not `cp`.** `create-pr.md` Step 6 and Step 9, and `review-response.md` Step 9, previously called `cp ai/... <REPO_PATH>/ai/...` to move plan/tracker into the repo in workspace-separated setups. `bash-write-guard` blocks Bash writes to `/ai/` paths by design (the `ai/` tree is owned by Read/Write tool calls). The command files now use the Read + Write tools for those copies; only `git add`/`commit`/`push` remain as shell calls.
- **Workflow consistency: Phase 2 plan commit is now conditional on workspace == repo.** When the workspace is itself a git repo, the orchestrator commits the plan as before. When the workspace is separate from the code repo, the commit is skipped — the plan stays in the workspace per orchestrator rule #8 and travels into the repo at Phase 6 alongside the tracker. The previous unconditional `git add ai/plans/ && git commit` either failed or pushed the orchestrator into copying the plan into the repo (tripping `bash-write-guard`).
- **Phase 7 Step 9 creates a new tracker-update commit instead of amending HEAD.** By Phase 7 Step 9, HEAD is the most recent Phase 7 task squash-merge — not the Phase 6 tracker commit — so `commit --amend` would silently rewrite a task commit's tree with tracker content. The replacement uses a new commit on top (fast-forward, no `--force-with-lease`) and keeps the tracker's recorded task SHAs accurate (an autosquash back into the Phase 6 tracker commit would rewrite every Phase 7 task SHA above it). Also adds the previously-missing `git push` — Phase 7 fixes were never reaching the remote PR.
- **Phase 6 Step 9 force-pushes after amend.** The amend rewrites the tracker commit SHA, and `pr-creator` already pushed the branch in Step 7. The workspace-is-git-repo branch was missing `git push --force-with-lease origin <feature-branch>` (asymmetric with the workspace-not-git branch which had it). Without the push, the remote PR was stale relative to the local tracker commit.
- **Orchestrator commits now use canonical-form meta Task IDs.** The Phase 2 plan, Phase 6 tracker, and Phase 7 tracker-update commit subjects previously used story-only form (`#<STORY-ID>: …`), which `validate-commit-msg` fail-closes — the only story-only exception is the Phase 5 `test-harden` form. The subjects now use `#TPLAN`, `#TTRACKER`, and `#TPR-RESP` respectively — valid instances of the existing canonical regex, so no hook change was required. Documented in README "Branch & Commit Conventions".

### Tests

- **`tests/hooks/` pure-bash harness** — no `bats` dependency. One suite per hook, canned payloads piped through the real scripts, assertions on exit code and stderr. Suites cover `validate-commit-msg` (32 cases, including the orchestrator meta-ID forms), `bash-write-guard` (30), `tracker-transition-guard` (18), `sensitive-file-guard` (21), `tracker-update-reminder` (10), `agent-status-check` (9), `squash-merge-verify` (10), `stop-failure-recovery` (7) — 150 cases across 9 suites. Run via `tests/hooks/run.sh`.

---

## [1.1.1] — 2026-04-25

### Features

- **Dependency version detection and API-compat annotations** — `init-workspace` language-discovery Phase 2 now extracts `key_dependencies` (flat `name: version` list) from `pom.xml`, `package.json`, `go.mod`, and `pyproject.toml` (Gradle, Cargo, and Gemfile produce an empty list with a comment). The `plan-generator` reads this map in a new Step 1c and stamps each task's Notes column with `[API: <lib> v<version>]` for any task that prescribes a named library method or type, so developers verify the exact API signature before implementing. The developer's build-recovery Attempt 1 now begins with an API-compatibility check when the error looks like a version mismatch, directing the developer to the `[API:]` annotation before trying arbitrary workarounds.
- **Phase 6 autosquash before pre-PR review** — Developer commits Phase 6 reviewer-requested fixes as `fixup! <task-commit-subject>` (targeting the most recently committed task commit whose files the fix touches). After the developer completes, the orchestrator runs a non-interactive autosquash rebase (`GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash`) so the pre-PR reviewer always sees clean, consolidated history. After the rebase, the orchestrator re-derives task commit hashes from `git log` and refreshes the tracker `Commit(s)` column before it is committed in Step 6 — the rebase rewrites SHAs, so stale hashes would otherwise be persisted. Rebase failure aborts and escalates to the human with the conflict output.
- **T-TEST tracker rows for Phase 5 test hardening** — `T-TEST-<RepoName>` rows are now included in every generated tracker (one per affected repo). The orchestrator advances them through the full Pending → In Progress → In Review → Done lifecycle during Phase 5, recording the tester commit hash in `Commit(s)` and the reviewer verdict in `Reviewer Verdict`, mirroring how Phase 3 dev tasks are tracked. Workflow Metrics field names aligned to `Test hardening started` / `Test hardening completed` everywhere (orchestrator-rules, create-pr prerequisites, README). Legacy trackers without T-TEST rows continue to work — `tester-activation-guard.sh` already skips T-TEST when checking dev-task completion.

### Fixes

- **story-groom: enforce fetch → pull → scan order** — Step 3 is now an explicit hard prerequisite for Step 4: the codebase scan must not begin until fetch and pull complete for every confirmed repo. Fetch failure stops that repo entirely (no pull, no scan). Pull failure also stops the scan — the command reports and asks the user to resolve manually rather than proceeding on stale code. The "proceed on current branch" option now surfaces a staleness warning in the technical notes output. The `Important` section states "Fetch → Pull → Scan is the non-negotiable order."
- **Enforce date-prefixed naming convention for plan and tracker files** — Plan and tracker save paths now use an explicit `date +%Y-%m-%d` Bash step rather than inline shell substitution, preventing silent date-prefix drops. Orchestrators are prohibited from injecting explicit save paths into the planner — the planner always derives the canonical path from the date command output and `WORKSPACE_ROOT`.
- **Anchor plan and tracker saves to `WORKSPACE_ROOT`** — Orchestrator constraint #8 now defines `WORKSPACE_ROOT` as the directory whose `.claude/context/` holds `provider-config.md` and prohibits copying `ai/` files into any code repo before Phase 6. The plan-generator derives `WORKSPACE_ROOT` from the `.claude/context/` location before saving, replacing ambiguous relative paths that could resolve to a code-repo directory in multi-repo setups. The error-recovery block now instructs the planner to use the absolute workspace path.
- **Tester worktree must use `-b` to create a new branch** — `git worktree add` without `-b` tries to check out the feature branch directly, which Git refuses when it is already checked out in the main worktree. Both the tester agent startup protocol and the orchestrator's tester launch template now always create a fresh branch (`git worktree add <path> -b worktree/<story>-t<n>-<uuid> <feature-branch>`). Rework re-invocations navigate to the existing worktree path instead of creating a new one.

---

## [1.1.0] — 2026-04-23

### Features

- **Claude Code attribution on all outputs** — every generated document (plan, tracker, user story, technical notes, requirements summary, PR/MR body) now ends with `🤖 Generated with [Claude Code](https://claude.ai/claude-code)`.
- **Co-author trailer on every commit** — all commits produced by the harness (tester, developer, orchestrator squash-merge, plan commit, tracker commit) include `Co-Authored-By: Claude Code <noreply@anthropic.com>` in the commit body.
- **Pre-PR review report enriched** — four new sections: Change Surface file list with categories (§0), Risk & Assumptions review vs plan (§8), Open Items carried forward — `TODO`/`FIXME`/`HACK` + unanswered story questions (§9), and a ready-to-use Suggested PR Description draft (§10).
- **Pre-PR AC verification strengthened** — reviewer now performs a mandatory active code search for each acceptance criterion, locating both the implementing code and a covering test with concrete `file:line` evidence. AC table extended with separate Implementation and Test evidence columns.
- **Full contract assertions required in integration/E2E tests** — tester must assert all response body fields defined in the plan's API contract, not just HTTP status codes. Error responses must assert status code AND every error envelope field.
- **Story-groom auto-pulls latest default branch** — `/story-groom` now runs `git fetch origin` before any repo analysis and automatically pulls with `--ff-only` when behind the remote. Stops with a clear error if the pull fails rather than analysing stale code.
- **Non-git workspace support in Phase 6** — when the workspace `ai/tasks/` directory is not inside a git repo, the tracker and plan are copied into each affected repo's `ai/` directories and committed from there, so artefacts travel with the feature branch.

### Fixes

- **Path quoting in all shell snippets** — repo paths, worktree paths, and file paths in every Bash snippet are now wrapped in double quotes to handle spaces in paths (common on macOS developer machines). New orchestrator rule #13 mandates this across the harness.
- **UUID-based worktree branch names** — worktree branch suffix changed from `$(date +%s)` (collision-prone on fast consecutive launches) to an 8-character UUID (`uuidgen` with `python3` fallback).
- **PR comment thread IDs persisted in tracker** — thread IDs are written into the tracker's Notes column at planning time so reply posting in Phase 7 survives session interruptions and does not rely on in-memory state.
- **Commit convention clarified for Phase 5 test-harden commits** — `#<STORY-ID> test-harden: <desc>` (Story ID only, no Task ID) is now explicitly documented as the correct and only valid exception to the two-ID rule. Applied to reviewer Phase 0 pre-check, PR checklist, and pre-PR git hygiene section.

### Docs

- **Sequence diagram always visible** — removed the collapsed `<details>` wrapper; the Mermaid diagram now renders inline in the README.
- **Coverage scope clarified** — all coverage threshold mentions now explicitly state "on new/modified code only — do NOT go out of scope to cover pre-existing code."

---

## [1.0.0] — 2026-04-12

First public release.

### Features

- **7-phase development workflow** — Requirements → Plan → Develop → Human Approval → Test Hardening → PR Creation → PR Review Response, with human approval gates at phases 2, 4, and 6.
- **TDD pattern** — Tester commits failing tests first; Developer makes them green; Reviewer reviews the combined diff before squash-merge. Every task starts red.
- **Multi-repo support** — Parallel developer agents across repos, strictly sequential within each repo. Cross-repo boundaries resolved via contracts defined in the planning phase.
- **Phase 7: PR Review Response** — On-demand phase triggered after PR comments arrive. Reviewer classifies each comment as VALID / INVALID / PARTIAL; human selects which to address; Planner adds rework tasks and re-enters the Phase 3 loop.
- **Language-agnostic, discovery-driven** — `/init-workspace` discovers language, toolchain, build, test, and coverage commands via negotiate-and-confirm. Supports any language (frontend + backend).

### Work Item Providers

| Provider | Notes |
|----------|-------|
| Azure DevOps | Work items via MCP |
| Jira | Issues via MCP |
| GitLab | Issues via MCP |
| GitHub | Issues via MCP |
| Zoho | Mail Group Tasks via MCP |
| local-markdown | Local `.md` files — no external provider needed |

### Git / PR Providers

| Provider | Notes |
|----------|-------|
| Azure DevOps | Pull Requests via MCP |
| GitLab | Merge Requests via MCP |
| GitHub | Pull Requests via MCP |
| gh-cli | Pull Requests via `gh` CLI (no MCP required) |
| glab-cli | Merge Requests via `glab` CLI (no MCP required) |

### Guardrail Hooks

- `tracker-transition-guard` — enforces legal tracker status transitions
- `tracker-metrics-guard` — validates tracker metric fields on every write
- `tracker-update-reminder` — reminds the orchestrator to sync tracker status
- `sensitive-file-guard` — blocks writes to secrets and credentials files
- `validate-commit-msg` — enforces `#<STORY-ID> #<TASK-ID>` commit format
- `squash-merge-verify` — prevents squash-merge before Reviewer approval
- `agent-status-check` — verifies agents end responses with a `📋 AGENT STATUS` block
- `tester-activation-guard` — prevents the Developer from starting before failing tests are committed
- `stop-failure-recovery` — surfaces recovery instructions on unexpected agent stops
