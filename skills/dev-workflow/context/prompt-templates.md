# Prompt Context Templates

> Owner: cross-cutting
> Version: 1.0

Standard context blocks the orchestrator inlines when constructing agent prompts in Phase 3 (`develop.md`), Phase 5 (`test.md`), Phase 6 (`create-pr.md`), and Phase 7 (`review-response.md`). Reference this file from each command instead of restating the templates inline.

The orchestrator pulls all field values from `.claude/context/language-config.md` (per-repo block) and the tracker's `Repo Status` section. It substitutes values per agent before launching.

---

## LANGUAGE_CTX

Include in **every** agent prompt. Omit irrelevant fields per agent role:

- **developer** — omit `Test command`
- **tester / reviewer** — omit `Format command`

```
LANGUAGE CONTEXT:
- Language: <language from language-config.md>
- Runtime: <runtime-version>
- Build command: <build-cmd>
- Restore command: <restore-cmd>           # developer / tester
- Test command: <test-cmd>                 # tester / reviewer
- Coverage command: <coverage-cmd>         # tester / reviewer (Phase 5)
- Coverage output: <coverage-path-pattern> # tester / reviewer (Phase 5)
- Format command: <format-cmd>             # developer only
- Test framework: <framework>              # tester only
- Conventions: Read .claude/context/conventions.md
```

## REPO_CTX

Include **only** in the worktree-failed fallback case (the orchestrator's Step 1 sub-step 5 worktree-creation attempt failed twice and the agent must work directly on the feature branch). Carries a `worktree_failed: true` flag so the agent knows it is in fallback mode. For every other launch — initial OR rework — use `WORKTREE_CTX`.

```
REPO CONTEXT (worktree-failed fallback — work directly on the feature branch):
- Repo: <repo-name>
- Repo path: <REPO_PATH>
- Feature branch: <FEATURE_BRANCH>
- Feature HEAD: <FEATURE_HEAD>
- worktree_failed: true
```

## WORKTREE_CTX

Include in **every initial agent launch and every re-invocation** in the lane's worktree. The orchestrator owns worktree creation (Step 1 sub-step 5 of `develop.md`) and inlines the resulting path / branch into the prompt — the agent never creates its own worktree.

```
WORKTREE DETAILS (worktree already exists — do NOT create a new one):
- Worktree path: <WORKTREE_PATH from orchestrator Step 1>
- Worktree branch: <WORKTREE_BRANCH from orchestrator Step 1>
```

On the tester → developer handoff and on rework after a Reviewer rejection, the same `WORKTREE_PATH` / `WORKTREE_BRANCH` values are reused — the orchestrator never recreates the worktree mid-task.

## PATTERN_HINTS_CTX

Include in **Phase 3 Tester (`auto-tdd`) launches** when the plan has a `## Test Pattern References` section that lists patterns for the current task. Skip if the section is absent or the task's pattern list is empty.

```
TEST PATTERN HINTS (from the plan's Test Pattern References section):
- <repo-relative-path-1> — <one-line rationale>
- <repo-relative-path-2> — <one-line rationale>

Consult these existing files for naming, structure, and fixture patterns. If they do
not apply (different framework, different mutation type, etc.), fall back to your test
framework's defaults — do NOT browse the tree looking for alternatives.
```

The "do NOT browse the tree" line is critical: it prevents the Tester from re-doing pattern-discovery research the Planner already attempted bounded-ly at plan time. If no hints fit, the framework default is the correct answer.

## CONTRACTS_CTX

Include when `ai/<workflow-dir>/contracts.md` exists AND at least one `## C<n>` section in it names this repo as Producer or Consumer. Skip otherwise — including when the file is absent (single-repo stories), or when the file exists but no `## C<n>` section matches this repo.

> Authoritative reference: [workflow-paths](workflow-paths.md) — `contracts.md` is the canonical location.

```
CROSS-REPO CONTRACTS (from ai/<workflow-dir>/contracts.md):
<Include each ## C<n> — <type> section verbatim where this repo is named in Producer or Consumer.>
<Strip sections that name only other repos — the developer doesn't need them.>
```

Note: the developer is permitted to read `contracts.md` directly via the `Read` tool if they need full context. CONTRACTS_CTX is a *narrowed* injection for token-budget efficiency, not an access-control boundary.
