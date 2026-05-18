# Naming Templates DSL

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-13]
     Reason: Foundational consumer-side helper for naming-config.md — declares placeholder set and render contract.
     CC conventions applied: CC-04.2, CC-04.4, CC-01.8 -->

## Purpose

Single source for the placeholder DSL used in branch / commit / PR / tag naming templates. Per CC-01.8, naming conventions are sourced from `.claude/context/naming-config.md` and **never** hardcoded — this file declares the placeholder vocabulary, the rendering contract, and the per-template defaults the P0 bootstrap proposes.

## Placeholders

| Placeholder | Meaning | Source |
|---|---|---|
| `${story_id}` | Provider-native work-item ID, post-`safe_id()` normalisation | `tracker.md` `Story:` header |
| `${task_id}` | Plan-internal task identifier (`T1`, `T2`, …) | `plan.md` task table |
| `${slug}` | Short kebab-case slug derived from the story title | `tracker.md` derived; lowercased; spaces → `-`; non-alnum → drop |
| `${type}` | Conventional-commit type (`feat`, `fix`, `chore`, `refactor`, …) | task `Type:` in plan |
| `${team}` | Team identifier supplied at `/dev-workflow` invocation (or `provider-config.md` default) — used as the leading segment in `<team>/feature/<id>-<slug>` branch names | `/dev-workflow <id> [project] [team]` arg, or `provider-config.md` default |
| `${repo}` | Repo slug post-`safe_id()` | `provider-config.md` |
| `${branch_default}` | The default branch of the current repo (`main` / `master` / `trunk`) | `provider-config.md` |
| `${author}` | Git author from `git config user.email` | local git config |

Unknown placeholders are rejected at render time — the renderer emits `Outcome: BLOCKED` with `Reason: unknown placeholder ${<name>}`.

## Render function contract

```python
def render_template(template: str, vars: dict[str, str]) -> str:
    """Substitute ${var} placeholders in template using vars dict.

    Raises ValueError on unknown placeholder.
    Returns the rendered string; never partial-renders.
    """
```

Idempotency: rendering with the same vars twice produces the same output. No side effects.

## Default templates (proposed by P0 bootstrap)

The bootstrap proposes these defaults and the user accepts or customises; the chosen values are written to `naming-config.md`:

| Concept | Default template |
|---|---|
| Branch name | `${team}/feature/${story_id}-${slug}` |
| Commit subject | `#${story_id} #${task_id} ${type}: ${slug}` |
| PR title | `[${repo}] ${slug}` |
| Tag (release) | `v${story_id}` *(rarely used; team-specific)* |

## Validation rules

- A template that references an undefined placeholder is rejected at bootstrap time.
- A template that omits `${story_id}` for branch / commit is rejected — the workflow requires traceability from PR back to story.
- Empty templates are rejected.

## Consumers

| Consumer | Use |
|---|---|
| `init-workspace` (P0) | Proposes defaults, writes user-accepted values to `naming-config.md` |
| `commands/develop.md` (P3) | Renders branch + commit names from `naming-config.md` |
| `commands/create-pr.md` (P6) | Renders PR title from `naming-config.md` |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [naming-templates](../context/naming-templates.md)
```

Hardcoding branch / commit / PR formats inline is a CC-01.8 violation and a CC-04.5 drift signal.
