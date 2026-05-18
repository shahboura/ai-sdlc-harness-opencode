# Provider Capability Surface

> Owner: cross-cutting
> Version: 1.0

<!-- Updated by: dev-workflow-plan.md [M-01] [IMPL-01-18]
     Reason: Prepend owner + version headers (CC-04.4 / CC-04.6) and the canonical
     capability vocabulary as a machine-readable YAML block per TEST-181 (M-24 drift sweep).
     Existing prose preserved below — it documents the adapter declaration format
     and the per-provider sweep status, both consumed by `lint-capabilities.py`.
     CC conventions applied: CC-04.2, CC-04.4, CC-04.6, YAGNI. -->

## Core cross-phase contract (machine-readable — minimum required for orchestrator routing)

The YAML block below is the **minimum cross-phase contract** — the seven
capabilities the orchestrator routes on across phases. It is the smaller of two
sets in this file; the wider adapter capability surface lives in the prose
tables further down and is what `scripts/lint-capabilities.py` actually
enforces against each adapter (see *Adapter capability surface* below for the
full 12-name list).

| Vocabulary | Where | Consumer | Count |
|---|---|---|---|
| **Core cross-phase contract** | YAML block below | `provider-resolver.md` and orchestrator-side capability-aware routing | 7 |
| **Adapter capability surface** | Prose tables (*Work item capabilities*, *Pull/Merge Request capabilities*, *PR review-comment capabilities*) | `scripts/lint-capabilities.py` (enforces presence per adapter) | 12 |

The split is intentional: the orchestrator only needs to know whether a phase
can run end-to-end against the configured provider (the 7 names), while each
adapter declares the richer surface it can supply for finer-grained operations
(the 12 names). Every name in the YAML appears in the prose; the prose adds
five capabilities the orchestrator does not key on but adapters declare for
audit / introspection (`work_item.list_comments`, `work_item.add_comment`,
`work_item.list_changelog`, `work_item.list_children`, `work_item.list_attachments`,
`work_item.search`, `pr.find_for_branch`, `pr.set_draft`).

The YAML carries `{name, required_for_phase, description}` per entry — no
`kind` field (`work-item` vs `pr`): per YAGNI the discriminator is not yet
needed by any consumer; if a future consumer requires it, add the field then
with a concrete use rather than pre-emptively.

```yaml
# skills/providers/shared/capabilities.md — canonical capability vocabulary
# > Owner: cross-cutting
# > Version: 1.0
capabilities:
  - name: work_item.fetch
    required_for_phase: P1
    description: Fetch a single work item by ID — title, description, AC, state.
  - name: work_item.transition
    required_for_phase: P8
    description: Move the work item to its terminal workflow state on merge (e.g. Closed, Done, Resolved).
  - name: pr.create
    required_for_phase: P6
    description: Open a new PR / MR for a feature branch.
  - name: pr.list_review_comments
    required_for_phase: P7
    description: Enumerate unresolved review threads / inline review comments.
  - name: pr.reply_to_review_comment
    required_for_phase: P7
    description: Post a reply on a specific review thread.
  - name: pr.merge_status
    required_for_phase: P8
    description: Detect whether a PR / MR has been merged (and into which branch).
  - name: pr.link_work_item
    required_for_phase: P6
    description: Link the PR to the corresponding work item (native or emulated via PR-body keywords).
```

> **Historical rename**: the `work_item.transition_state` →
> `work_item.transition` rename was completed across every adapter on
> 2026-05-17 — the legacy `transition_state` name is no longer accepted by
> `lint-capabilities.py`.

---

## Adapter capability surface (enforced by `lint-capabilities.py`)

This section is the **wider 12-name surface** every adapter under
`skills/providers/<provider>/` is expected to declare in a `## Capabilities`
section of the relevant file (`work-items.md`, `pull-requests.md`, or
`pr-comments.md`). `scripts/lint-capabilities.py` enforces declaration
presence against this set.

Each adapter declares its support as ✅ supported / 🟡 emulated / ❌ unsupported.
The orchestrator and the harness skills use the declarations to decide whether
a given workflow phase can run end-to-end with the configured provider. Phase 7
(`/dev-workflow review-response`), for example, requires the `pr.list_review_comments`
and `pr.reply_to_review_comment` capabilities on the configured git provider — if
either is `❌`, Phase 7 cannot complete.

## Capability Reference

### Work item capabilities

Declared in `skills/providers/<provider>/work-items.md`.

| Capability | Required? | Description |
|------------|-----------|-------------|
| `work_item.fetch` | ✅ required | Fetch a single work item by ID — title, description, AC, state. |
| `work_item.list_comments` | optional | List comments / discussion threads on a work item. |
| `work_item.add_comment` | optional | Post a comment back to the work item. |
| `work_item.list_changelog` | optional | List the audit / revision history of a work item. |
| `work_item.list_children` | optional | List child items (e.g. tasks under a story). |
| `work_item.list_attachments` | optional | List file attachments on the item. |
| `work_item.transition` | optional | Move the item to a new workflow state. (Renamed from `transition_state` 2026-05-17 to match the canonical YAML vocabulary above; the old name is rejected by the lint.) |
| `work_item.search` | optional | Free-text search across work items. |

### Pull/Merge Request capabilities

Declared in `skills/providers/<provider>/pull-requests.md`.

| Capability | Required? | Description |
|------------|-----------|-------------|
| `pr.create` | ✅ required for git providers | Open a new PR/MR for a feature branch. |
| `pr.find_for_branch` | optional (required for idempotent re-runs) | Look up open PR/MR by source branch. |
| `pr.link_work_item` | optional | Link the PR to the corresponding work item. Often emulated via body keywords. |
| `pr.set_draft` | optional | Create the PR/MR in draft state. |

### PR review-comment capabilities

Declared in `skills/providers/<provider>/pr-comments.md`. Required for Phase 7.

| Capability | Required for Phase 7? | Description |
|------------|------------------------|-------------|
| `pr.list_review_comments` | ✅ required | Enumerate unresolved review threads / inline review comments. |
| `pr.reply_to_review_comment` | ✅ required | Post a reply on a specific review thread. |

## Declaration Format

Every adapter `## Capabilities` section uses a three-column table:

```markdown
## Capabilities

| Capability | Status | Notes |
|------------|--------|-------|
| pr.create | ✅ | Native — `mcp__github__create_pull_request` |
| pr.find_for_branch | ✅ | `gh pr list --head <branch> --state open` |
| pr.link_work_item | 🟡 | Emulated — `Closes #N` keyword in PR body |
| pr.set_draft | ✅ | `--draft` flag |
```

### Status values

- **✅ Supported** — adapter has a primitive or stable command that implements the capability.
- **🟡 Emulated** — capability is achieved indirectly (e.g. PR-body keyword instead of an API call). Note the mechanism in the Notes column.
- **❌ Unsupported** — the underlying provider has no path to do this. The workflow phase that depends on the capability cannot run.

A capability **not listed** in the adapter table is treated as `❌`.

## Adapter Sweep Status

Every git provider adapter declares the canonical capability list and ships a
`pr-comments.md` file with the Phase 7 primitives. The sweep covers:

| Provider | Work item | PR/MR | Phase 7 (`pr-comments.md`) |
|----------|-----------|-------|-----------------------------|
| `ado` | ✅ | ✅ `pull-requests.md` | ✅ — REST via `curl` (MCP threads 🟡) |
| `github` | ✅ | ✅ `pull-requests.md` | ✅ — `gh api graphql` (MCP review-threads ❌) |
| `gh-cli` | — (no work-item tracker) | ✅ `pull-requests.md` | ✅ — `gh api graphql` |
| `gitlab` | ✅ | ✅ `merge-requests.md` | ✅ — REST via `curl` (MCP discussions 🟡) |
| `glab-cli` | — (no work-item tracker) | ✅ `merge-requests.md` | ✅ — `glab api` |

`jira`, `zoho`, and `local-markdown` are work-item providers only — Phase 7 routes through
the configured git provider regardless of the work-item provider. They have no
`pr-comments.md` and the lint does not expect one.

`scripts/lint-capabilities.py` enforces declaration presence across the swept set. Adding
a new provider involves: (1) the adapter file(s) under `skills/providers/<name>/`, each
with a `## Capabilities` section; (2) an entry in the lint's `ALLOW_LIST`; (3) a
test-suite assertion that covers it.
