# Getting Started · v2.0

This is the 10-minute path from "I just heard about this" to "the harness is implementing my first user story." For the full spec read [CLAUDE.md](CLAUDE.md). For the comprehensive reference see [README.md](README.md).

## What you're about to do

Install a Claude Code plugin, run a one-time workspace setup that scans your local repos and writes context files, then kick off `/dev-workflow` against a real work item. The harness pauses at **five human gates** along the way — those are where you make decisions, not the agents.

## Before you start

You need:

- **Claude Code** installed ([claude.ai/code](https://claude.ai/code))
- **Git** on your PATH
- **Python 3** on your PATH (the guard hooks use it — `python3 --version` should print something)
- **Your target repos already cloned locally**, each on its default branch and up to date. The harness does not clone them for you.
- **Optional**: an MCP server or CLI for your work-item / git provider (ADO, Jira, GitHub, GitLab, Zoho). If you have nothing set up, pick `local-markdown` during `/init-workspace` and you'll be running in under a minute.

## Install

Three commands inside Claude Code:

```
/plugin marketplace add MostAshraf/ai-sdlc-harness
/plugin install ai-sdlc-harness@ai-sdlc-harness
/reload-plugins
```

After the reload, `/init-workspace`, `/story-workflow`, and `/dev-workflow` are available as slash commands.

## Step 1 — Initialize the workspace (one time)

> **Important: run `/init-workspace` from an empty folder.**
> Create a dedicated folder somewhere on your machine (e.g. `~/ai-sdlc-workspace/`) and `cd` into it before starting Claude Code. That folder becomes your *harness workspace* — it's where `.claude/context/` gets written and where every later `/dev-workflow` run is invoked from. Your actual application repos live elsewhere on disk and get referenced by path during the next step.
>
> Do **not** run `/init-workspace` inside one of your application repos. The harness workspace and your code repos are separate things on purpose: it keeps the generated context files out of your project's git history and lets one workspace coordinate work across multiple repos.

```
/init-workspace
```

This is interactive. You'll be asked to:

1. **Pick a work-item provider** — where your stories live. ADO, Jira, GitHub, GitLab, Zoho, or `local-markdown` (a folder of `.md` files, no external system needed).
2. **Pick a git provider** — where your code and PRs live. ADO, GitHub, GitLab, or one of the CLI options (`gh-cli`, `glab-cli`) that skip the MCP setup.
3. **Point at your local repos** — the harness will scan each one, detect language and toolchain, and ask you to confirm anything ambiguous. This is the only step that takes real time; expect 2–5 minutes per repo on first run.
4. **Confirm the naming-config** — branch/commit/path patterns get written to `.claude/context/naming-config.md` and consumed at runtime. Override them later without code changes.
5. **Approve a Bash permissions proposal** — the harness lists exactly which build/test/lint commands it needs to run per repo, you approve, and that list becomes the allowlist for every agent.

Everything generated lives under `.claude/context/` and is git-ignored. Each developer generates their own.

If you only want to try the harness without wiring up a real provider, pick `local-markdown` and point it at any folder. You'll be able to create a story as a markdown file and run the full workflow against it.

## Step 2 — Run your first workflow

Pick a real work item (or write a quick markdown story if you're on `local-markdown`) and run:

```
/dev-workflow <Work-Item-ID>
```

The harness will go through up to 9 phases plus 2 cross-cutting ones. Five of them stop and wait for you:

- **GATE 1 (after planning)** — the Planner proposes one or more implementation approaches and a Test Outline. You pick one. Nothing is coded until you do.
- **GATE 2 (after the TDD loop)** — every task has been written (tests first by the Tester, then code by the Developer, then reviewed by the Reviewer). You see the full implementation and approve it before test hardening begins.
- **GATE 2.5 (conditional, after security review)** — fires only if Phase 5.5 found ≥ medium findings. You pick WAIVE / DEFER / FIX-NOW.
- **GATE 3 (before PR creation)** — the Reviewer does a holistic pre-PR pass against the original plan and conventions, returns a structured `pre-pr-report.md`, and you approve the PR.
- **GATE 4 (on-demand, after PR comments arrive)** — only runs if you invoke `/dev-workflow review-response <story-id>`. The Reviewer classifies each PR comment as VALID / INVALID / PARTIAL, and you pick which to address.
- **GATE 5 (on-demand, ad-hoc requests between gates)** — fires whenever you reply `REQUEST <text>` at GATE 2 / GATE 3 or invoke `/dev-workflow request <story-id> "..."` mid-phase. The Reviewer triages each request against the approved plan and you confirm or redirect before any code work happens. Worked example below.

Two phases run hands-off **after** PR creation:

- **P8 — Post-Merge Reconciliation** fires when your PR merges. The orchestrator transitions the work item, cleans up worktrees, stamps `Workflow completed`, and archives the tracker in place (`tracker.md` → `tracker.archived.md` — the workflow dir stays intact). You can trigger it manually with `/dev-workflow reconcile <id>` if the auto-detect missed.
- **P9 — Metrics** auto-fires at three triggers: T1 at PR creation, T2 each time a PR-response round completes, T3 at post-merge. Outputs `metrics-report.md` plus a row in workspace-level `ai/_metrics-log.csv`.

Between gates, the agents run on their own. You can walk away. The orchestrator updates the task tracker on disk after every status change so you can check progress at any time with `/workflow-status <id>`.

## What's new for v2.0

A quick orientation if you've used the v1.x harness:

- **One folder per story.** Plan, tracker, coverage, security report, pre-PR report, PR-comment analysis, metrics — all live under `ai/<YYYY-MM-DD>-<work-item-id>/`. Replaces `ai/plans/` + `ai/tasks/`.
- **Security is part of the workflow.** Phase 5.5 runs SAST + secret-scan + CVE per repo automatically. Only stops you if findings ≥ medium.
- **Closeout is automatic.** Phase 8 archives the tracker and transitions the work item on PR merge. Phase 9 stamps the metrics. No manual cleanup.
- **Recovery is first-class.** Stop-failure marker + PostCompact rehydrate from the tracker; `/dev-workflow resume <id>` is always available.
- **Hotfix path exists.** `/dev-workflow hotfix <id>` un-archives within 30 days or spawns a linked-fresh workflow otherwise. Bidirectional `Hotfix-Of:` / `Hotfixed-By:` headers tie them together.
- **TDD is enforced.** The `tdd-red-verify` hook refuses to let the developer touch production code for a task until the tester has committed at least one independently-replayed failing test.
- **Patterns are configurable.** Branch / commit / path patterns live in `.claude/context/naming-config.md` and are read at runtime. Override without touching code.

### Worked example — finding an issue while testing (GATE 5)

The most common shape this gate takes is "I'm exercising the new feature before GATE 2 and something doesn't work." Here's the full path:

1. **You spot the problem.** Maybe the new drawer doesn't close when you press Escape. The Phase 3 TDD loop finished, all tasks are ✅ Done, the orchestrator presents GATE 2 with a per-repo summary. Instead of `APPROVED`, you reply:

   ```
   REQUEST the drawer doesn't close when I press Escape — pressing the X button works fine
   ```

2. **The Reviewer triages.** The orchestrator does NOT call the Developer directly. It invokes the Reviewer with `mode: request-triage`, which reads the approved plan and the acceptance criteria, locates the drawer's keyboard-handling code on the feature branch, and classifies your request. Common outcomes:

   - **`IN_SCOPE_BUG`** — the plan or an acceptance criterion expects Escape to close the drawer, but the implementation doesn't deliver it. This is a real regression.
   - **`IN_SCOPE_AC_MISS`** — Escape-to-close is implied by AC-3 ("the drawer is dismissible") but no task covered the keyboard path.
   - **`OUT_OF_SCOPE`** — neither the plan nor the ACs say anything about Escape. You're asking for new behaviour.
   - **`PLAN_CONFLICT`** — the plan explicitly chose click-outside-only dismissal because of a design decision recorded in the plan. Escape would contradict it.

3. **You answer the decision matrix (GATE 5).** The Reviewer's report comes back with one row per (repo, request) pair — important for multi-repo stories where the *same* request can be `IN_SCOPE_BUG` in repo A and `OUT_OF_SCOPE` in repo B (each repo's reviewer triages independently against its own plan slice). You answer each row independently:

   ```
   | # | Request | Repo | Classification | Choose |
   |---|---------|------|----------------|--------|
   | 1 | [AHR-1] | web-ui   | IN_SCOPE_BUG  | [1] Confirm  [2] Skip |
   | 2 | [AHR-1] | api      | OUT_OF_SCOPE  | [a] Expand scope  [b] Defer as new story  [c] Withdraw |
   ```

   Even clear in-scope items wait for your `[1] Confirm` — auto-creating tasks would bypass the gate. For out-of-scope rows, `[a] Expand scope` runs a scoped plan amendment (next bullet), `[b]` records the request in `## Deferred Requests` for you to open as a separate work item, `[c]` drops it. There's also `[f] Re-triage with hint` for rows the Reviewer couldn't classify (`UNCLASSIFIED`), and `[SKIP-ALL]` as a global escape.

4. **The TDD loop runs again, scoped to your request.** On confirmation, the Planner appends a new row under a `## Ad-hoc Tasks (Batch 1)` heading in the tracker — separate from the main table so the original plan's DAG stays readable. The orchestrator then re-enters Phase 3 for that row only: Tester writes a failing Escape-key test, Developer makes it green, Reviewer approves, squash-merge. Standard TDD path.

5. **GATE 2 re-presents itself.** Once the ad-hoc batch is ✅ Done, the per-repo summary regenerates (now reflecting the additional commits) and you get the same `APPROVED / CHANGES / REQUEST` prompt again. You can raise another request, approve, or kick back to Phase 3 for more changes.

#### What `[a] Expand scope` actually does — and how to back out

If the Reviewer classifies your request as `OUT_OF_SCOPE` or `PLAN_CONFLICT` and you pick `[a]`, here's the full sequence:

1. The orchestrator **snapshots the plan file** to `ai/.snapshots/` (so it has something to roll back to).
2. The Planner runs in `MODE: plan-amendment` and appends a new `## Plan Amendment — Ad-Hoc Round N` section to the plan. The original plan body is untouched.
3. The orchestrator re-presents **GATE 1** scoped to just the new amendment section — you see the amendment text and approve or reject it.
4. **On approval**: the amended plan stays; the Reviewer re-triages your request under the amended plan (it should now classify as in-scope); the standard task-creation flow takes over.
5. **On rejection** (you reply `CHANGES <description>` or `WITHDRAW`): the orchestrator **restores the plan from the snapshot** — the appended section disappears. You then fall through to the original GATE-5 row for that request and pick `[b] Defer` or `[c] Withdraw` instead.

The snapshot-and-restore approach is workspace-agnostic — it works whether your workspace is itself a git repo or a plain directory. Either way, a rejected amendment leaves the plan in exactly the state it had before you picked `[a]`. If a session ends while a snapshot still exists, the `stop-failure-recovery` hook surfaces the orphan on the next prompt with `[1] restore / [2] keep / [3] discard` options.

#### Mid-phase requests — `/dev-workflow request <id> "..."`

You can submit a request without waiting for a gate. While Phase 3 or Phase 5 is running, type:

```
/dev-workflow request 12345 "the drawer doesn't close when I press Escape"
```

The orchestrator handles it **synchronously and in-line** — no background queue:

- Background agents already running continue uninterrupted. They are not preempted.
- The Reviewer triages immediately, the GATE 5 matrix shows up, you answer it.
- On confirmation, the Planner appends ad-hoc rows to the tracker and control returns to the lane main loop.
- Those new rows are picked up by their target repo's lane on its **next idle cycle** (after the currently-running task completes). They do *not* jump the queue.

If you need an ad-hoc item to run *before* more main-table work proceeds, raise the request at the next gate (GATE 2 or GATE 3) instead. Gate-entry routes pause the workflow until the new batch is ✅ Done; mid-phase routes don't.

#### Where to look afterward

- Every ad-hoc row's `Notes` column carries `ad-hoc: [AHR-<n>] · source: <gate-2 | gate-3 | mid-phase>` so you can trace which request triggered which task.
- `## Deferred Requests` records the requests that didn't become tasks (skipped, deferred, withdrawn, or `[SKIP-ALL]`'d). Useful for retrospectives or for opening follow-up work items.
- Run `/workflow-status <id>` mid-flow to see ad-hoc batches and deferred requests rendered alongside the main table. Stalled gates surface here too — anything still in `Gate prompted <ts>` past the configured threshold gets called out.

## What to expect while it runs

- **Sequential within each repo, parallel across repos.** If your story touches three repos, you'll see three parallel lanes. Within each lane, tasks finish one at a time.
- **Two commits per task** — `test:` from the Tester, then `impl:` from the Developer. The `tdd-red-verify` hook proves the test was actually red before letting the developer commit. Both get squash-merged once the Reviewer approves.
- **The tracker file is uncommitted** until Phase 6. That's intentional — it keeps your PR history clean.
- **One PR per repo**, all linked to the same work item. Phase 8 reconciles each one independently.
- **Phase 5.5 auto-runs** between hardening and PR creation. Only stops you if findings ≥ medium. Findings below medium produce a per-repo `static-security-report-<repo>.md` for audit and the workflow proceeds.
- **Phase 9 metrics** quietly fire at three points (T1 PR creation, T2 each PR-response round, T3 post-merge) and append to `ai/_metrics-log.csv`. Useful for cycle-time tracking; you can ignore them mid-workflow.

## When things go sideways

The most common issues on a first run:

- **Worktree creation fails on Windows** (`could not lock config file`). The Developer reports this and the orchestrator re-runs without worktree isolation. No action needed from you.
- **A build/test command isn't in the allowlist.** The hook will block it with a clear message. Run `/init-workspace --refresh-permissions` to re-propose the allowlist.
- **The Reviewer flags issues you disagree with.** Push back in the gate response — the orchestrator will route your feedback to the right agent.
- **A task gets stuck in a review-fix loop.** Two rounds of "changes requested" usually means the plan was wrong, not the code. Reject at the gate and ask the Planner to revisit.
- **Context compaction interrupts a long session.** The PostCompact hook reconstructs state from the latest tracker. If the workflow really did hit a snag, `/dev-workflow resume <id>` always works.
- **GATE 2.5 surprised you with security findings.** The auto-run is intentional — it's better to find a high-severity finding now than during PR review. `WAIVE` records the decision in the tracker for audit; `FIX-NOW` re-enters Phase 3 with fix tasks.
- **Closeout didn't auto-fire on merge.** Your provider adapter may not support polling. Run `/dev-workflow reconcile <id>` to trigger Phase 8 manually.

## A sanity check before your first real run

Try a tiny throwaway story first. Something like "add a `/health` endpoint that returns 200" against a scratch repo. You'll see all five gates fire (well, four — GATE 2.5 will likely auto-pass since a `/health` endpoint shouldn't trip security scanners), the TDD loop run, a PR get created, and Phase 8/9 auto-reconcile after you merge — in maybe 10–15 minutes of agent time. That's the fastest way to build intuition for what each gate is actually asking you.

## Where to read next

- **[CLAUDE.md](CLAUDE.md)** — the workflow spec. Phases, ownership rules, status transitions, non-negotiable rules. Read this before customizing.
- **[README.md](README.md)** — comprehensive reference. Branch / commit conventions, hook details, project structure, extension points.
- **`agents/`** — one folder per agent (`planner`, `tester`, `developer`, `reviewer`). The agent's behavior is the markdown file you see there. The workflow rules in CLAUDE.md constrain what each agent is allowed to do.
- **`skills/dev-workflow/commands/`** — every workflow phase has a command file (`requirements.md`, `plan.md`, `develop.md`, `security-review.md`, `create-pr.md`, `reconcile.md`, ...). These are the orchestrator's playbooks.
- **`skills/`** — the slash-command entry points and their internals. `dev-workflow`, `story-workflow`, `init-workspace`, `security-report`, `metrics-collector`, and the per-provider adapters under `skills/providers/`.
