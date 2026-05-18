# Provider Adapter Parity Report

> Owner: M-21 (parity-test milestone; refreshed on every adapter change)
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-21] [IMPL-21-02 / -10]
     Reason: Per RAG-32 (advisor G2), document the parity matrix surface and the per-capability /
     per-provider test status. Full per-provider fixture infrastructure (TEST-131..149) is the
     M-12 backfill scope; this file captures the matrix shape + current declared-but-untested rows
     so CI can fail when an unlabelled row appears.
     CC conventions applied: CC-04.5 (drift detection), CC-06.4 (coverage rule), CC-07.5 (no TODO left). -->

## Purpose

Per-capability × per-provider parity matrix. For every required-Y capability declared in [`capabilities.md`](shared/capabilities.md), this report records the parity-test status (`PASS` / `FAIL` / `SKIPPED-WITH-REASON`) against every adapter that declares the capability.

CI policy: any row that is `FAIL` or **unlabelled** (no entry at all) fails the build. `SKIPPED-WITH-REASON` is permitted only when the adapter explicitly declares the capability as `❌` (unsupported) or `🟡` (emulated with a documented mechanism).

## Scope

Providers in scope:

| Provider | Work-item adapter | Git adapter |
|---|---|---|
| ado | ✅ | ✅ |
| jira | ✅ | ⏭️ (stub) |
| gitlab | ✅ | ✅ (MR terminology) |
| github | ✅ | ✅ |
| gh-cli | — | ✅ |
| glab-cli | — | ✅ (MR terminology) |
| zoho | ✅ | — |
| local-markdown | ✅ | — |

Capabilities from [`capabilities.md`](shared/capabilities.md):

```
work_item.fetch       — P1 — REQUIRED for every work-item provider
work_item.transition  — P8 — REQUIRED for every work-item provider
pr.create             — P6 — REQUIRED for every git provider
pr.list_review_comments    — P7 — REQUIRED for every git provider
pr.reply_to_review_comment — P7 — REQUIRED for every git provider
pr.merge_status            — P8 — REQUIRED for every git provider
pr.link_work_item          — P6 — OPTIONAL (emulated permitted)
```

## Parity matrix

> **Status legend**: 🟢 PASS · 🔴 FAIL · ⏭️ SKIPPED (declared ❌ in capabilities table) · 🟡 SKIPPED (emulated — verified emulation works) · ⚠ UNLABELLED (CI fails)

### Work-item capabilities

| Capability | ado | jira | gitlab | github | zoho | local-markdown |
|---|---|---|---|---|---|---|
| `work_item.fetch` | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED |
| `work_item.transition` | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED |

### PR / MR capabilities

| Capability | ado | gitlab | github | gh-cli | glab-cli |
|---|---|---|---|---|---|
| `pr.create` | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED |
| `pr.list_review_comments` | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED |
| `pr.reply_to_review_comment` | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED |
| `pr.merge_status` | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED |
| `pr.link_work_item` | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED | ⚠ UNLABELLED |

## Status of the parity test suite

The behavioural per-provider parity test suite under `tests/integration/providers/<provider>/` is **scheduled but not yet implemented**. Tracked tests (declared in `dev-workflow-tests.md` § M-21):

| Test | Status |
|---|---|
| TEST-131 `work_item.fetch` happy-path normalised shape | ⏸ Pending fixture infrastructure (M-12 backfill) |
| TEST-132 `work_item.fetch` NOT_FOUND canonical | ⏸ Pending |
| TEST-133 `work_item.transition` happy path | ⏸ Pending |
| TEST-134 `work_item.transition` illegal-FSM | ⏸ Pending |
| TEST-135 `pr.create` happy path + title format | ⏸ Pending |
| TEST-136 `pr.create` ALREADY_EXISTS | ⏸ Pending |
| TEST-137 `pr.list_review_comments` flat shape | ⏸ Pending |
| TEST-138 `pr.merge_status` canonical enum | ⏸ Pending |
| TEST-139 token redaction in error logs | ⏸ Pending — depends on `scripts/_token_redact.py` (M-21 IMPL-21-04 future) |
| TEST-140 capability negotiation | ⏸ Pending |
| TEST-141 unicode preservation | ⏸ Pending |
| TEST-142 INPUT_TOO_LONG boundary | ⏸ Pending |
| TEST-143 malformed-ID local rejection | ⏸ Pending |
| TEST-144 network-failure canonical errors | ⏸ Pending — depends on loopback HTTP fixture |
| TEST-145 capability matrix snapshot vs `capabilities.md` | ⏸ Pending |
| TEST-146 `local-md` network-isolation | ⏸ Pending — Linux CI `unshare -n`; Mac CI doc fallback |
| TEST-147 concurrency state isolation | ⏸ Pending |
| TEST-148 AC extraction consistency | ⏸ Pending |
| TEST-149 CLI-mode parity (`gh-cli` / `glab-cli`) | ⏸ Pending |
| TEST-150 `provider-parity-report.md` emitted with no unlabelled rows | ⏸ Pending (this file is the gate artifact; verification is M-13 cc-check) |

## CI gate

The Convention-Check `CC04-provider-parity.convention-check.test.sh` (future — M-13 cc-check) will:

1. Re-emit this report from the current adapter capability declarations + the latest parity-test run results.
2. Fail the build if any `⚠ UNLABELLED` row is present (forces an explicit per-row decision).
3. Fail the build if any **`🔴 FAIL`** row is present.
4. Accept `🟢` / `⏭️` / `🟡` rows as the only labelled-and-passing states.

Until the parity test infrastructure lands (M-12 backfill), all rows are intentionally `⚠ UNLABELLED` — surfacing the gap rather than hiding it under a false PASS.

## Outstanding work

- **IMPL-21-01** Fixture infrastructure under `tests/integration/providers/_fixtures/<provider>/` (deterministic in-memory mocks; **not** live API).
- **IMPL-21-02** Parameterised test runners per provider × capability.
- **IMPL-21-03..-09** TEST-131..149 implementations.
- **IMPL-21-10** Automated regeneration of this report from test runs (replaces the manual matrix above).

When the M-12 test backfill lands, this report is regenerated and the matrix flips from `⚠ UNLABELLED` → `🟢 PASS` / `⏭️ SKIPPED-WITH-REASON` per row.
