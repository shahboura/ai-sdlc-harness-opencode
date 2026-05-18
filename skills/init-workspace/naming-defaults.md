# Naming Defaults — shipped templates the P0 bootstrap proposes

> Owner: P0 (init-workspace)
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-15] [IMPL-15-03]
     Reason: Separate-file defaults so they can be tuned over time without re-versioning the SKILL.md schema.
     CC conventions applied: CC-04.2, CC-04.4 (owner = P0), CC-01.8. -->

## Purpose

Single source for the **shipped default naming templates** that `init-workspace` proposes during the P0 bootstrap. The user reviews these in S5b and either accepts them as-is or customises in S5c; the chosen values are written to `.claude/context/naming-config.md`.

Per CC-01.8 these defaults are templates only — no consumer reads from this file at runtime. The runtime authority is `naming-config.md` (post-bootstrap) and the placeholder vocabulary lives in [naming-templates](../dev-workflow/context/naming-templates.md).

## Default templates

| Key | Default | Rationale |
|---|---|---|
| `branch_format:` | `${team}/feature/${story_id}-${slug}` | Team-prefixed `<team>/feature/<id>-<slug>` form documented in CLAUDE.md as the harness's canonical branch shape. The literal `feature` segment makes the branch list scannable by directory; `${team}` lets multi-team workspaces partition ownership. |
| `commit_format:` | `#${story_id} #${task_id} ${type}: ${slug}` | Twin `#`-prefixed IDs (story + task) so any conventional-commit + autolink integration picks both up. Type-then-slug matches the project's pre-existing convention. |
| `pr_title_format:` | `[${repo}] ${slug}` | Multi-repo stories produce one PR per repo; bracketed repo prefix makes the PR list scannable in tools like GitHub's All-PRs view. |
| `tag_format:` | `v${story_id}` | Rarely used — only for release-train-shaped stories. Teams that don't tag per-story should leave this default (it just goes unused). |

## Per-template field availability

Per `naming-templates.md`, the placeholder vocabulary is:

| Placeholder | Branch | Commit | PR title | Tag |
|---|---|---|---|---|
| `${story_id}` | ✅ | ✅ (required) | optional | ✅ |
| `${task_id}` | optional | ✅ (required) | optional | — |
| `${slug}` | ✅ | ✅ | ✅ | optional |
| `${type}` | optional | ✅ | optional | — |
| `${team}` | ✅ (default) | optional | optional | optional |
| `${repo}` | optional | optional | ✅ | optional |
| `${branch_default}` | optional | — | — | — |
| `${author}` | optional | optional | optional | — |

> Validation: the bootstrap rejects templates that omit `${story_id}` from branch / commit (traceability requirement per CC-01.8); empty templates; unknown placeholders.

## Cross-check at bootstrap (IMPL-15-06)

The bootstrap also performs a cross-check against the active git provider's `pr-conventions.md`:

- **ADO**: prefers a specific PR title prefix on multi-team backlogs; the chosen `pr_title_format:` should align or the bootstrap surfaces the conflict before writing.
- **GitHub**: any title is accepted; no cross-check required.
- **GitLab**: any title is accepted; no cross-check required.

If a conflict is surfaced, the human's choice still wins — the validator records the deviation in `naming-config.md` as a comment so future audits can locate it.

## When defaults are revised

Bumping the default templates here triggers a workspace re-bootstrap prompt for existing workspaces (the bootstrap detects schema-version drift between this file and the workspace's `naming-config.md` Version: header). The user opts in or out per workspace — never force-overwritten.

## Consumers

| Consumer | Use |
|---|---|
| `init-workspace` Step 5b | Proposes these defaults at bootstrap; writes user-accepted values to `naming-config.md`. |
| (none at runtime) | Runtime consumers read `naming-config.md`, not this file. |
