# Provider Adapter Audit Report

> Owner: M-09 (one-shot audit; refreshed on every adapter change)
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-09] [IMPL-09-03]
     Reason: Audit summary per CC-07.5 — captures the citation + capability-declaration
     status of every provider adapter at M-09 completion. Refreshed on every adapter change.
     Generated against repository state at the M-09 milestone gate.
     CC conventions applied: CC-07.5 (no TODO left), CC-04.3 (audit format mirrors citation contract). -->

## Scope

Covers all 8 providers in `skills/providers/` (excluding `shared/` and `README.md`):

- **Work-item providers**: `ado`, `jira`, `gitlab`, `github`, `zoho`, `local-markdown`
- **Git providers**: `ado`, `gitlab`, `github`, `gh-cli`, `glab-cli`

Lint sources: `scripts/lint-capabilities.py` (existing capability check + new shared-ref citation check added in IMPL-09-01).

## Citation Status (CC-04.3)

### `work-items.md` → `> Authoritative reference: [work-item-concepts](../shared/work-item-concepts.md)`

| Provider | Status | Notes |
|---|---|---|
| ado | ✅ PASS | Citation present. |
| github | ✅ PASS | Citation present. |
| gitlab | ✅ PASS | Citation present. |
| jira | ✅ PASS | Citation present. |
| local-markdown | ✅ PASS | Citation present. |
| zoho | ✅ PASS | Citation present. |

### `pull-requests.md` / `merge-requests.md` → `> Authoritative reference: [pr-conventions](../shared/pr-conventions.md)`

| Provider | File | Status | Notes |
|---|---|---|---|
| ado | `pull-requests.md` | ✅ PASS | Citation added in IMPL-09-02. |
| github | `pull-requests.md` | ✅ PASS | Citation present. |
| gh-cli | `pull-requests.md` | ✅ PASS | Citation present. |
| gitlab | `merge-requests.md` | ✅ PASS | Citation present (MR terminology). |
| glab-cli | `merge-requests.md` | ✅ PASS | Citation present (MR terminology). |
| jira | `pull-requests.md` | ⏭️ SKIP | Jira is a work-item provider only; the file is a stub explaining `PRs are created via the git provider`. Skip-listed in `lint-capabilities.py` `SHARED_REF_SKIP_LIST`. |
| zoho | (no `pull-requests.md`) | ⏭️ N/A | Work-item provider only. |
| local-markdown | (no `pull-requests.md`) | ⏭️ N/A | Work-item provider only. |

## Capability Declaration Status

Status from `scripts/lint-capabilities.py` (the canonical capability lint — runs in CI):

```
Capability lint OK (13 adapter file(s) checked).
```

All 13 adapter files declare a `## Capabilities` section with each in-scope capability marked ✅ / 🟡 / ❌ per the format in `skills/providers/shared/capabilities.md`. Required capabilities (`work_item.fetch`, `pr.create`, `pr.list_review_comments`, `pr.reply_to_review_comment`) declared ✅ for every applicable adapter.

## Duplicated-Prose Sweep (CC-08.1 / IMPL-09-04)

Manual grep on the adapter set for the duplication signals:

- **AC parsing regex** (≥ 5 lines): grep `acceptance criteria.*regex\|AC.*regex\|parse.*AC` across `work-items.md` files — no duplicate ≥ 5-line block found. Adapter-specific regex variations are short (≤ 3 lines) per provider.
- **PR title format prose** (≥ 5 lines): grep `PR title.*format\|title format` across `pull-requests.md` / `merge-requests.md` — no duplicate ≥ 5-line block; the canonical title contract lives in `shared/pr-conventions.md` and each adapter cites it.

> The 2026-05-17 plan flagged GAP-10 / GAP-11 (potential AC + PR-title duplication). The sweep confirms the citation pattern is sufficient — extracting more aggressively would obscure adapter-specific quirks. CC-08.4 acceptable variance applies for any per-adapter short divergence.

## Outstanding Items

| Item | Status | Owner |
|---|---|---|
| `work_item.transition_state` vs `work_item.transition` vocabulary divergence | ✅ RESOLVED 2026-05-17 | Renamed across `ado/work-items.md`, `gitlab/work-items.md`, `github/work-items.md`, `shared/capabilities.md` prose table, and the `WORK_ITEM_CAPS` list in `scripts/lint-capabilities.py`. The legacy `transition_state` name is no longer accepted; every adapter declares `work_item.transition` (matching the canonical YAML in `shared/capabilities.md`). |

## Summary

| Total adapters checked | Citation PASS | Citation SKIP / N/A | Capability lint | Duplicated prose found |
|---|---|---|---|---|
| 8 providers / 13 adapter files | 11 / 11 applicable | 4 (jira PR stub + 3 work-item-only PR absences) | ✅ all green | none |

**Gate**: GAP-10, GAP-11 marked resolved. M-09 closes.
