---
name: plan-generator
description: >
  Decompose an approved requirements summary into an implementation plan with
  atomic tasks, Mermaid diagrams, and a task tracker. Use during Phase 2 of the
  development workflow after requirements are fully understood.
allowed-tools: Bash, Read, Write, Grep, Glob
argument-hint: "[Work-Item-ID] [brief-slug]"
---

# Plan Generator

> **See also**: [`tracker-schema.md`](tracker-schema.md) — single-page reference for every
> tracker section, column, Notes-token, and enum. Edit it first when adding or renaming any
> schema element; the rest of this file (and the orchestrator command files) cross-reference it.

## Purpose

Take a validated requirements summary and produce a comprehensive implementation plan with atomic tasks, class diagrams, flow charts, sequence diagrams, and a task tracker file.

## Inputs

- `$ARGUMENTS[0]` — Work Item / Issue ID (e.g., `123456` for ADO/GitLab/GitHub, `PROJ-123` for Jira)
- `$ARGUMENTS[1]` — Brief kebab-case slug (e.g., `token-refresh-service`)

## Steps

### 0a. Minimum-Input Gate (bounces back to story-intake on failure)

Before proposing approaches or reading any code, verify the requirements summary is substantive enough to plan against. Check, in order:

1. **Description present.** Non-empty `Description` (or equivalent) section required.
2. **At least one acceptance criterion.** At least one entry under `## Acceptance Criteria`.
3. **At least one repo configured.** Read `.claude/context/repos-metadata.md` and confirm at least one repo row is declared. A workspace with no repos cannot host any of the tasks the Planner would produce.

If any of these checks fails, **STOP** and bounce back to `story-intake`:

```
## Plan generation aborted — requirements summary is below the minimum input bar

  - Description: <present | MISSING>
  - Acceptance criteria count: <N>
  - Configured repos (repos-metadata.md): <N>

The Planner cannot produce a usable plan from this. Re-run
`/dev-workflow plan <story-id>` after one of:
  [1] Re-running `/story-intake <story-id>` so the requirements summary is
      filled in (description, ACs).
  [2] Re-running `/init-workspace` if `repos-metadata.md` is empty.
  [3] Editing the requirements summary manually if you want to bypass intake.
```

End the invocation with `Outcome: BLOCKED`.

The repo-identification check in Step 1b is the **secondary** gate — if the requirements implicate zero of the configured repos, Step 1b bounces back with the same message shape. This Step 0a check only verifies the inputs are non-trivial, not that they map to a specific repo.

### 0. Design Approach Selection

Propose 2-3 architectural approaches (name, summary, trade-offs). Present using the `🏗️ DESIGN APPROACHES` block format with your recommendation. **Wait for the human to select an approach before proceeding.** The selected approach informs all subsequent steps.

### 1. Pre-Flight

> Authoritative reference: [workflow-paths](../dev-workflow/context/workflow-paths.md) — canonical layout is `ai/<YYYY-MM-DD>-<work-item-id>/` (CC-05.7).

Read prior-session work from **both** layouts:

1. **New canonical layout (M-14)**: `ai/*-$ARGUMENTS[0]/tracker.md` (any date prefix).
2. **Legacy layout (deprecated)**: `ai/tasks/*$ARGUMENTS[0]*.md`.

If the canonical directory already exists, the orchestrator's P1 entry has already prompted for Takeover / Abort per CC-05.7.2. Inside the planner, assume the directory is yours to write to.

### 1b. Repo Identification (Multi-Repo)

Read `.claude/context/repos-metadata.md` and `.claude/context/repos-paths.md`. Map each requirement to the repo that owns that domain. Identify **cross-repo boundaries** (HTTP API, Service Bus, shared DTOs) — define these as contracts so all repos develop in parallel.

### 1c. Dependency Version Pre-Flight

For each affected repo, read `key_dependencies` from `.claude/context/language-config.md` to build a version map. If absent/empty, fall back to the repo's primary dependency manifest (pom.xml, package.json, go.mod, pyproject.toml); for unsupported manifests (`# manifest unsupported` comment), hold an empty map and do not retry by reading the manifest yourself.

**Annotation rule:** for every task whose Description prescribes a specific library API, append `[API: <lib> v<version>]` to its **Notes** column if the library is in the version map. omit the annotation entirely if the map is empty or the library is absent — a guessed version is worse than no annotation.

### 2. Task Decomposition

Break the story into ordered, atomic tasks (fields: Task ID `T<n>` / `T-TEST-<Repo>`, Repo, Title, Description, Files, Dependencies, Complexity S/M/L).

**Multi-repo rules:** tasks within the same repo respect dependency ordering; different-repo lanes run fully in parallel; create one `T-TEST-<RepoName>` per affected repo.

**Dependency notation (machine-readable):** record intra-repo dependencies in the Notes column as `depends: T<n>[, T<n>...]`. Tasks with no dependencies omit the token. Combine tokens via `·` separator: `test-required: true · depends: T1, T2`. The token must match `depends:\s*T[A-Za-z0-9-]+(\s*,\s*T[A-Za-z0-9-]+)*`. Cross-repo dependencies are forbidden — use contracts instead.

### 2b. Cross-Repo Contracts (Multi-Repo Only)

When repos communicate at runtime, write a dedicated `contracts.md` to the per-workflow directory (sibling of plan.md and tracker.md); contracts live at `ai/<YYYY-MM-DD>-<work-item-id>/contracts.md`. For single-repo stories, skip this step entirely.

Use the canonical section heading `## C1 — HTTP API` (or `C2`, `C3`, etc. for Service Bus / Shared DTO). The exact heading pattern (`## C<n> — <type>`) is the stable contract the orchestrator and reviewer parsers depend on — do **not** rename it or change capitalisation.

> Full multi-repo tracker templates for HTTP API (C1) and Service Bus (C2) contracts: see [tracker-schema.md → Cross-repo contract templates](tracker-schema.md#cross-repo-contract-templates).

Per-contract fields: **Contract ID** `C<n>` (1-based, section heading prefix); **Type** `HTTP API | Service Bus Message | Shared DTO`; **Producer** repo; **Consumer** repo(s); **Definition** full signature in a fenced code block.

**Developer** receives contracts via CONTRACTS_CTX prompt block. **Reviewer** checks `contracts.md` during Phase 3/6; use the `Contract: C<n>` annotation format in `[S<n>]` findings. Phase 7 and ad-hoc requests that touch a contract update `contracts.md` (not `plan.md`).

In the plan.md, include a stub section `## Cross-Repo Contracts → see contracts.md` that points readers to the dedicated file rather than inlining the full contract definitions.

### 3. Class Diagram

Produce a Mermaid `classDiagram` showing new/modified types, relationships, and key methods.

#### Wrapper-type check for update / PATCH DTOs (NON-NEGOTIABLE)

When the diagram contains any DTO used for **partial-update** semantics (HTTP `PATCH`, optional admin toggles, Service Bus messages that may omit fields), **every optional field MUST use a wrapper / nullable type** — never a primitive that cannot represent "unset". Languages: Java → `Boolean`/`Integer`; C# → `bool?`/`int?`; Go → `*bool`/`*int`; TypeScript → `boolean | undefined`; Python → `Optional[bool]`; Rust → `Option<bool>`.

**Why**: primitives default to `false`/`0` — the server can't distinguish "sent false" from "omitted". Required actions: (1) annotate every optional field with the wrapper type; (2) add a Risk note for the DTO in item 13; (3) if legacy primitives exist, add an explicit migration sub-task.

### 4. Flow Chart

Produce a Mermaid `flowchart TD` showing the runtime flow, decision points, external interactions, and error paths.

### 4b. Sequence Diagram

Produce a Mermaid `sequenceDiagram` (with `autonumber`) showing end-to-end actor interactions, call order, sync vs async, and key payloads.

### 5. Produce Test Outline

For each task T(n), produce a Test Outline listing unit/integration tests the Tester will implement in Phase 3.

**Format per task:**
```markdown
## Test Outline

### T1: <task title>
`test-required: true`
- `MethodName_Scenario_ExpectedResult` — one-line description of what behaviour it validates and which acceptance criterion it covers (e.g. AC-2)

### T2: <task title>
`test-required: false` — <one-line justification, e.g. "dependency bump covered by existing suite" or "pure config change with no branching logic">
```

**Rules:** use `Subject_Scenario_Outcome` naming convention; include happy-path, error/edge-case, and security/boundary tests per AC; mark `test-required: false` for pure-config/scaffolding/rename tasks; present at GATE #1 for approval.

### 5b. Test Pattern References (Bounded Pattern-Hint Discovery)

For every task with `test-required: true`, produce a short list of 0–2 existing test files the Tester should consult — front-loading pattern discovery prevents watchdog stalls at Phase 3.

**Heuristic — strictly filename-globbing only. No semantic comparison, no advisor calls, no reading file contents.** At most 5 globs per task; at most 2 matches returned, ranked by file modification time (newest first).

**Procedure for each `test-required: true` task:**

1. **Determine the repo's test root** from `language-config.md` (`test_root` field, or language default: `tests/` Python, `test/` Java, `__tests__`/`tests/` JS/TS, `*_test.go` siblings Go).

2. **Extract 1–3 distinctive tokens from the task title** — noun phrases describing the *what*. Generic one-word titles expect zero matches.

3. **Run filename globs** (stop after 5 total per task):
   - `<test_root>/**/*<token>*.spec.*`
   - `<test_root>/**/*<token>*.test.*`
   - `<test_root>/**/test_*<token>*.*` (Python)
   - `<test_root>/**/*<token>*_test.*` (Go)
   - `<test_root>/**/harden-*<token>*.*` (story-prefixed)

4. **Rank and trim**: dedupe, sort by modification time (`stat -c %Y` Linux / `stat -f %m` macOS / `git log -1 --format=%ct` fallback), keep top 2.

5. **Output format** per task:
   ```markdown
   ### T<n>: <task title>
   Patterns:
   - <repo-relative path> — matched on `<token>`, modified <YYYY-MM-DD>
   ```
   If zero matches: `Patterns: (none — Tester will use test framework defaults)`.

**Bounds (non-negotiable):**

- Globbing is finite — at most 5 globs × 1 candidate-token sweep per task. The Planner does NOT keep retrying with broader patterns. "No match" is a valid answer.
- **The Planner does NOT read the contents of any candidate file.** Filename match is the entire signal.
- The output is a *suggestion*. The human reviews these patterns at GATE #1 and may strike or replace any line before approving the plan.

The approved Patterns list per task is inlined verbatim into the Tester's prompt as a `TEST PATTERN HINTS` block (see `prompt-templates.md` → `PATTERN_HINTS_CTX`).

### 6. Save Plan Document

**Before saving**, run:
```bash
date -u +%Y-%m-%d   # capture as TODAY (UTC — canonical per orchestrator-rules #14)
STORY_ID=$(echo "<raw-id>" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g')
WORKFLOW_DIR="$WORKSPACE_ROOT/ai/${TODAY}-${STORY_ID}"
mkdir -p "$WORKFLOW_DIR"
```

Save to: `$WORKFLOW_DIR/plan.md`  (i.e. `ai/<YYYY-MM-DD>-<safe-id>/plan.md`)

The plan document must include:
1. Story metadata (ID, title, sprint)
2. Requirements summary
3. **Affected repos** (list with justification)
4. **Cross-repo contracts** (if multi-repo: full contract definitions)
5. Selected design approach
6. **Test Outline** (per-task test names + intent; `test-required` flag)
7. **Test Pattern References** (per-task list of 0–2 existing test files; produced by Step 5b. The human reviews these at GATE #1 and may edit them before approval.)
8. Task breakdown table (with Repo column)
9. Class diagram
10. Flow chart
11. Sequence diagram
12. Conventions reference (link to `.claude/context/conventions.md`)
13. Risk/assumptions section
14. Attribution footer (last line): `🤖 Generated with [Claude Code](https://claude.ai/claude-code)`

### 7. Create Task Tracker

Save to: `$WORKFLOW_DIR/tracker.md`  (i.e. `ai/<YYYY-MM-DD>-<safe-id>/tracker.md`)

Before writing, run `date -u +"%Y-%m-%d %H:%M UTC"` and use output as `Workflow started`. All other metrics remain `—`.

**CRITICAL**: Use this EXACT column schema. Do NOT invent, rename, remove, or reorder columns. Every tracker row must have exactly 7 pipe-separated columns.

**REQUIRED: After the task table you MUST write a `## Dependency Graph` section** (Mermaid `flowchart LR`). Mandatory for every story — do NOT skip it.

> Dependency graph rendering rules: see [tracker-schema.md → Dependency graph](tracker-schema.md#dependency-graph-rendering-rules).

Tracker format (authoritative in [`tracker-schema.md`](tracker-schema.md)):

```markdown
# Task Tracker — <Story Title> (<Story-ID>)

| Task ID | Repo | Title | Status | Reviewer Verdict | Commit(s) | Notes |
|---------|------|-------|--------|------------------|-----------|-------|
| T1 | AuthService | ... | ⏳ Pending | — | — | test-required: true |
| T2 | AuthService | ... | ⏳ Pending | — | — | test-required: true · depends: T1 |
| T3 | BillingService | ... | ⏳ Pending | — | — | test-required: false |
| T-TEST-AuthService | AuthService | Test hardening | ⏳ Pending | — | — | Phase 5 |
| T-TEST-BillingService | BillingService | Test hardening | ⏳ Pending | — | — | Phase 5 |
```

**Column definitions, status enum, legal transitions, and Notes-token vocabulary are authoritative in [`tracker-schema.md`](tracker-schema.md).** The row template above shows the concrete shape the Planner writes — refer to the schema page for what each cell may legally contain.

Quick legend (full enum in [`tracker-schema.md` → Status enum](tracker-schema.md#status-enum)): ⏳ Pending · 🔧 In Progress · 🔄 In Review · ✅ Done

After the task table, write `## Dependency Graph`, `## Repo Status`, and `## Workflow Metrics` sections. The Workflow Metrics block uses these canonical field names (filled by the orchestrator at runtime): `Workflow started`, `Plan approved`, `Development started`, `Initial development completed`, `Human approval (impl)`, `Test hardening started`, `Test hardening completed`, `PR created`.

> Full tracker template (Dependency Graph, Repo Status, Workflow Metrics, Task Metrics, Review History): see [tracker-schema.md → Full tracker template](tracker-schema.md#full-tracker-template).

### 8. Present for Approval

Display the full plan — including the Test Outline and the Test Pattern References — to the human user. Call out the Pattern References explicitly:

> **🚦 GATE: Please review this plan, the Test Outline, and the Test Pattern References (per-task list of existing test files the Tester will consult) and respond with APPROVED to proceed, or describe the changes you'd like.**
>
> *Patterns are filename-glob suggestions. If any look irrelevant, strike them — empty pattern lists are fine; the Tester will fall back to framework defaults.*

Do NOT proceed until receiving approval.

## Phase 7 Amendment Mode (`MODE: pr-response-tasks`)

When the orchestrator invokes this skill with `MODE: pr-response-tasks` (from `skills/dev-workflow/commands/review-response.md` Step 7 after PR review comments have been classified VALID/PARTIAL and accepted at GATE #4), the skill operates in **amendment mode** instead of producing a fresh plan.

**Skip**: Steps 0a, 0, 1 (plan/tracker already exist), Step 7 fresh-file creation, Step 8 (human gated at GATE #4 — amendment write-back is silent).

**Repeat**: Step 1b (verify Repo values), Step 5 (Test Outline under `## Test Outline — PR Review Round N`), Step 5b (Test Pattern References for amendment tasks), Step 6 Dependency Graph regeneration (amendment tasks appear as root nodes with implicit T-TEST edge).

### Amendment row template

Append new task rows under a new `## Amendments (PR Review Round N)` heading **below** the existing task table — do NOT reorder, edit, or remove any existing rows. Existing rows record history; mutating them would corrupt the trail.

Tracker format — same column schema (authoritative in [`tracker-schema.md`](tracker-schema.md) → *Task-row column schema*):

```markdown
## Amendments (PR Review Round <N>)

| Task ID | Repo | Title | Status | Reviewer Verdict | Commit(s) | Notes |
|---------|------|-------|--------|------------------|-----------|-------|
| T<next-n> | <repo-name> | <≤ 60-char title> | ⏳ Pending | — | — | PR-comment: [PC-<n>] thread_id=<provider-thread-id> · test-required: <true|false> |
```

The `Notes` column **must** include the `PR-comment: [PC-<n>] thread_id=<...>` token. Full Notes-token vocabulary: [`tracker-schema.md` → Notes column tokens](tracker-schema.md#notes-column-tokens).

**Task ID continuation**: highest existing Task ID + 1 (T-TEST rows excluded). **Status transitions**: every amendment row MUST start in `⏳ Pending`. The `tracker-transition-guard` hook enforces this.

## Ad-Hoc Task Mode (`MODE: ad-hoc-tasks`)

When the orchestrator invokes this skill with `MODE: ad-hoc-tasks` (from `skills/dev-workflow/commands/handle-request.md` Step 6 after a batch of ad-hoc requests has been triaged IN_SCOPE_BUG / IN_SCOPE_AC_MISS and confirmed at GATE #5), the skill appends new tasks under a separate `## Ad-hoc Tasks (Batch <N>)` heading.

**Skip**: Steps 0a, 0, 1, Step 7 fresh-file creation, Step 8 (human gated at GATE #5 — append is silent).

**Repeat**: Step 1b (verify Repo values), Step 5 (Test Outline under `## Test Outline — Ad-Hoc Batch <N>`), Step 5b (Test Pattern References), Step 6 Dependency Graph regeneration.

### Ad-hoc row template

Append under a new `## Ad-hoc Tasks (Batch <N>)` heading **below** any existing Amendment and Ad-hoc headings — do NOT reorder, edit, or remove any existing rows.

```markdown
## Ad-hoc Tasks (Batch <N>)

| Task ID | Repo | Title | Status | Reviewer Verdict | Commit(s) | Notes |
|---------|------|-------|--------|------------------|-----------|-------|
| T<next-n> | <repo-name> | <≤ 60-char title> | ⏳ Pending | — | — | ad-hoc: [AHR-<n>] · source: <gate-2 \| gate-3 \| mid-phase> · submitted: <YYYY-MM-DD HH:MM UTC> · test-required: <true \| false> |
```

The `Notes` column **must** include the `ad-hoc: [AHR-<n>]` token — the Phase 3 re-entry filter and `[AHR-<n>]` counter both rely on it. Full vocabulary: [`tracker-schema.md` → Notes column tokens](tracker-schema.md#notes-column-tokens).

**Task ID continuation**: highest existing Task ID across all sections (T-TEST rows excluded).

**Workflow Metrics — Ad-Hoc Fields**: if the tracker has no `Ad-hoc requests started` row yet, append:

```markdown
| **Ad-hoc requests started** | <date -u +"%Y-%m-%d %H:%M UTC"> |
| **Ad-hoc requests completed** | — |
```

`Ad-hoc requests started` is set on the first batch only. `Ad-hoc requests completed` is owned by the orchestrator and remains `—` in the Planner's write.

**Status transitions**: every ad-hoc row MUST start in `⏳ Pending`. The `tracker-transition-guard` hook enforces this.

## Plan Amendment Mode (`MODE: plan-amendment`)

When the orchestrator invokes this skill with `MODE: plan-amendment` (from `skills/dev-workflow/commands/handle-request.md` Step 5 after the human chose **Expand scope**), the skill amends the **plan file** only and returns. Task creation happens in a subsequent `MODE: ad-hoc-tasks` invocation.

**Skip**: Steps 0a / 0 / 1, Steps 5b through 8. **Do NOT touch the tracker in this mode.**

Append a new `## Plan Amendment — Ad-Hoc Round <N>` section below the existing Risk/Assumptions section.

> Plan amendment section format and field details: see [tracker-schema.md → Plan Amendment section](tracker-schema.md#plan-amendment--ad-hoc-round-n).

### Rules

- Do NOT modify the original Requirements Summary, AC list, or Task breakdown table in-place. All amendment content lives in the new section.
- **Rollback is owned by the orchestrator, not by this skill.** Before invoking `MODE: plan-amendment`, the orchestrator takes a `PLAN_SNAPSHOT` via Read and persists a copy to `<WORKSPACE_ROOT>/ai/.snapshots/<plan-basename>-<YYYY-MM-DD-HHMMSS>-<uid8>.md` via Write. The in-memory cache is the fast path; the on-disk copy survives crashes and `/compact`. If the amendment is rejected, the orchestrator restores from the snapshot (prefer in-memory, fall back to on-disk) and deletes the file. On approval, the snapshot is deleted. The Read+Write pair is the only **workspace-agnostic** rollback that always works, and `stop-failure-recovery.sh` scans `.snapshots/` at recovery time to surface orphan snapshots.
- If the human asks for rework, the orchestrator re-invokes this skill; the mode edits the appended section in place.

## Rules

- Tasks must be **atomic** — each should be implementable and reviewable independently.
- Tasks within the same repo must be **sequential** — respect dependency ordering.
- Tasks in different repos always run in **parallel** — cross-repo contracts eliminate blocking.
- Dependencies are **intra-repo only**. Cross-repo boundaries are resolved via contracts defined in step 2b.
- Every task must have a **Repo** column value matching a repo name from `repos-metadata.md`.
- Every task must have `test-required: true` or `test-required: false` in its Notes column.
- Every `test-required: true` task must have a corresponding Test Outline entry with at least one test name.
- Include one `T-TEST-<RepoName>` row per affected repo. These track Phase 5 test hardening through the same Pending → In Progress → In Review → Done lifecycle as dev tasks.
- The **Repo Status** section must be populated from `repos-paths.md` and `repos-metadata.md`.
- The plan is the **contract** — all agents will reference it as the source of truth.
