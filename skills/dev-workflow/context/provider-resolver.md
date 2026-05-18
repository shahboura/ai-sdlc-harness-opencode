# Provider Resolver

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-06]
     Reason: Foundational shared snippet — extracts the read-provider-config-then-load-adapter sequence duplicated at 3 sites.
     CC conventions applied: CC-04.2, CC-04.4 -->

## Purpose

Single source for the "read `provider-config.md` → load adapter" sequence used by every phase that touches the work-item provider (ADO / Jira / GitLab / GitHub / Zoho / local-markdown). Per CC-05.2 phases communicate via artifacts only, so adapter selection is data-driven from the config file — never hardcoded.

## Resolution sequence

1. **Read** `.claude/context/provider-config.md`.
2. **Parse** the `work_item_provider:` field. Allowed values: `ado | jira | gitlab | github | zoho | local-markdown`.
3. **Parse** the `git_provider:` field. Allowed values: `github | gh-cli | gitlab | glab-cli | ado`.
4. **Locate** the adapter directory: `skills/providers/<provider>/`.
5. **Load** the adapter's relevant sub-skill (`work-items.md`, `pull-requests.md` / `merge-requests.md`, or `pr-comments.md`).
6. **Validate** the adapter declares the required capabilities for the calling phase (see `skills/providers/shared/capabilities.md`).
7. **Reject** at exit-code 2 if any of: config missing, provider unknown, adapter missing required capability for the phase.

## Capability-aware resolution

Per `skills/providers/shared/capabilities.md`, each phase requires a specific capability set:

| Phase | Provider role | Required capability |
|---|---|---|
| P1 | work-item | `work_item.fetch` |
| P6 | git | `pr.create` (and `pr.link_work_item` if available) |
| P7 | git | `pr.list_review_comments`, `pr.reply_to_review_comment` |
| P8 | git + work-item | `pr.merge_status`, `work_item.transition` |

If the resolved adapter's `## Capabilities` declaration does not include the required capability with status `✅`, the resolver emits `Outcome: BLOCKED` with `Reason: provider <name> missing capability <cap> for phase <P>`.

## Skipping rules (per CC-08.4 standing variance)

- **P5 / P5.5**: no provider call required (test hardening and security review operate on local source).
- **R**: provider calls are forbidden during recovery — recovery operates on local artifacts only.

## Consumers

| Phase | Site |
|---|---|
| P1 | `commands/requirements.md` |
| P6 | `commands/create-pr.md` |
| P7 | `commands/review-response.md` |
| P8 | `commands/reconcile.md` |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [provider-resolver](../context/provider-resolver.md)
```

Inlining the resolution sequence in a command file is a CC-04.5 drift signal.
