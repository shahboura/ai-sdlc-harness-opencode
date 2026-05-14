# Provider Capability Surface

Canonical list of capabilities every provider adapter is expected to declare.
Each adapter under `skills/providers/<provider>/` declares its support for these
capabilities in a `## Capabilities` section of the relevant file
(`work-items.md`, `pull-requests.md`, or `pr-comments.md`).

The orchestrator and the harness skills use the capability list to decide whether
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
| `work_item.transition_state` | optional | Move the item to a new workflow state. |
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
