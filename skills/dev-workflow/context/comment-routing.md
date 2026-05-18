# Comment Routing

> Owner: cross-cutting
> Version: 2.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-04]
     Revised: aligned with the indexed-prefix three-prefix model that every
     consumer actually emits and routes (per develop.md, agents/reviewer/index.md,
     orchestrator-rules.md, status-schema.md, and the test-md re-routing pattern).
     The previous unindexed `[S]/[R]/[T]` table was a stale design artefact; this
     version documents the implementation.
     CC conventions applied: CC-04.2, CC-04.4 -->

## Purpose

Single source for the **indexed three-prefix** routing rules used in every Reviewer-emitted comment list (Phase 3 / 5 development loop, P7 PR-comment analysis, and the IG ad-hoc-request triage). Reviewer comments are tagged at emit time and routed to the agent that owns the change surface; the index `<n>` provides a stable referent so the orchestrator can match comments across rework cycles.

## Tag grammar

Each comment opens with one of the three indexed prefixes:

| Prefix | Meaning | Phase scope |
|---|---|---|
| `[S<n>]` | **Spec compliance failure** (Phase A) — the plan promised X; the diff does not deliver X. The comment is placed against whichever file (production or test) needs to change to satisfy the plan. | Phase 3 review |
| `[R<n>]` | **Quality issue in production code** (Phase B) — severity `CRITICAL \| WARNING \| SUGGESTION`. | Phase 3 review |
| `[T<n>]` | **Quality issue in test code** (Phase B), or test files that diverged from the approved Test Outline — severity `CRITICAL \| WARNING \| SUGGESTION`. Use this whenever the fix must happen in a test file. | Phase 3 review + Phase 5 hardening |

`<n>` is a monotonically increasing 1-based integer scoped to the Reviewer's verdict (`[S1]`, `[S2]`, `[R1]`, `[R2]`, `[T1]` …). The index does NOT have to be globally unique across all three prefixes — each prefix carries its own counter.

## Routing table

The orchestrator routes each comment to one agent based on the prefix **and**, for `[S<n>]`, the file path mentioned in the comment body:

| Prefix | Routes to | Routing logic |
|---|---|---|
| `[S<n>]` | Developer **or** Tester | Read the file path inside the comment. Production file → **Developer**. Test file → **Tester**. The orchestrator does not inspect comment content beyond the path. |
| `[R<n>]` | Developer | All `[R<n>]` are production-code issues by definition. |
| `[T<n>]` | Tester | All `[T<n>]` are test-code issues by definition. |

**Ambiguous `[S<n>]`** — if a single `[S<n>]` mentions paths for **both** production and test files (e.g., the plan requires changes in both), route to the agent that owns the file listed first in the comment body. If that's still ambiguous, default to the **Developer** and include the comment verbatim so they can flag it. This rule appears nowhere else; consumers should defer to this file for it.

## Test-harden context (Phase 5)

During Phase 5 test hardening the Tester runs alone — there is no Developer in this phase. The routing semantics shift:

| Prefix | Phase 5 routing | Notes |
|---|---|---|
| `[S<n>]` | Tester | A Phase 5 `[S<n>]` indicates the reviewer found a defect in the test itself; the file path will always be a test file. |
| `[T<n>]` | Tester | Same as Phase 3 — test-code quality / Test-Outline divergence. |
| `[R<n>]` | **Escalate to human AND pause the lane** | In Phase 5 a `[R<n>]` means "production refactor required", but the Tester cannot edit production source (CC-02.1 boundary). The orchestrator (i) surfaces the comment to the human verbatim with the prefix-mismatch flagged and (ii) pauses the affected lane — keeping `T-TEST-<RepoName>` in `🔄 In Review` when there are ONLY `[R<n>]` comments (no transition; the universal-rule `Started` overwrite would lose audit fidelity), or letting the lane advance on the legitimate `[T<n>]/[S<n>]` findings while the `[R<n>]` is surfaced separately. See `commands/test.md` Step 2 for the case split. Do **NOT** silently relay to the Tester. |

The `[R<n>] → escalate` rule is what distinguishes Phase 5 from Phase 3 routing.

## When multiple prefixes appear in one review cycle

The Reviewer emits a single list mixing all three prefixes. The orchestrator processes them in two phases per `develop.md`:

1. **Phase A — `[S<n>]` spec compliance.** If any `[S<n>]` appears, route those first. Skip Phase B until every `[S<n>]` is resolved (a non-conforming diff is not a quality-review candidate).
2. **Phase B — `[R<n>]` + `[T<n>]` quality.** Once Phase A is clean, route `[R<n>]` to the Developer and `[T<n>]` to the Tester. When both appear in the same cycle, the **Tester runs first** in the same worktree, then the Developer — this prevents the Developer from immediately reverting tests the Tester just rewrote.

## Edge cases

- **Unindexed legacy tag** (`[S]`, `[R]`, `[T]` without a digit): the orchestrator treats it as the indexed form with `n = 1` and surfaces an advisory to the Reviewer that the comment lacked an index.
- **Multi-tag comment** (`[S1][T2]`): the orchestrator splits into two routed work items, one per tag. The Tester and Developer execute in their own lanes per CC-05.6.
- **Unrecognised tag** (`[X<n>]`, `[INFO]`): hook-blocked at the IG entry — the orchestrator refuses to proceed and surfaces the unknown tag verbatim to the human.
- **Comment with no file path under `[S<n>]`**: the orchestrator cannot route without a file path; surfaces the comment to the human with a precise error and pauses the cycle.

## Consumers

| Phase | Site | Notes |
|---|---|---|
| P3 | `commands/develop.md` Step 4 | Two-phase routing (A then B); orchestrator parses the Reviewer's `Review comments:` field. |
| P5 | `commands/test.md` Step 2 | Re-routing under harden semantics; `[R<n>] → escalate`. |
| P7 | `commands/review-response.md` Step 4 | PR comment classification feeds the same prefix-routing rules into the Phase 3 re-entry loop. |
| IG | `commands/handle-request.md` Step 3 | Ad-hoc request triage emits the same prefixed routing decisions. |

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [comment-routing](../context/comment-routing.md)
```

Inlining the `[S<n>]/[R<n>]/[T<n>]` mapping in a command file is a CC-04.5 drift signal.
