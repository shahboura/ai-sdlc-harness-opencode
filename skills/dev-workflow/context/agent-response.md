# Agent Response Parsing

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-02]
     Reason: Foundational shared snippet — extracts AGENT STATUS parsing pattern duplicated at >=6 sites.
     CC conventions applied: CC-04.2, CC-04.3, CC-04.4 -->

## Purpose

Single source of the orchestrator-side parser contract for the `📋 AGENT STATUS` block that every agent emits at the end of its final message (per CC-02.4). The block's schema is owned by `agents/shared/status-schema.md` — this file documents how the orchestrator parses and routes on the block.

## Schema authority

> Authoritative reference: [status-schema](../../../agents/shared/status-schema.md)

The schema lives in YAML inside `status-schema.md` and is the source of truth for which fields are universal vs role-specific. Do not duplicate field lists here — read them from the schema file.

## Parser contract (orchestrator-side)

When an agent's final message arrives, the orchestrator:

1. **Locate** the `📋 AGENT STATUS` header in the message tail (last 64 KB per CC-09 `STATUS_TAIL_BYTES`).
2. **Extract** the block by capturing every line between the header and the next blank line or end-of-message.
3. **Parse** each line into `Field: Value` pairs. Field names are case-preserving; values are trimmed.
4. **Validate** universal-required fields (`Agent`, `Phase`, `Outcome`, `Next action`) against the YAML schema. Missing → routed to fix loop or BLOCKED.
5. **Validate** per-role / per-mode required fields against the YAML schema.
6. **Reject** contradictory combinations declared in the schema's `contradictions:` list.
7. **Route** on `Outcome` / `Verdict`:
    - `SUCCESS` / `APPROVED` → proceed to next phase step
    - `FAILED` / `BLOCKED` / `CHANGES_REQUESTED` → enter fix loop or escalate
    - `PARTIAL` / `DONE_WITH_CONCERNS` → surface concerns; orchestrator decides advance vs. iterate
    - `ANALYSIS_PARTIAL` / `TRIAGE_PARTIAL` → mark unclassified items as advisory; advance with caution

`Verdict:` is authoritative for routing in reviewer modes; `Outcome:` reports execution success. The orchestrator-side parser MUST treat `Verdict:` as primary when both are present.

## HTML-entity normalisation

Subagent responses are occasionally emitted with HTML-encoded entities (`&lt;`, `&gt;`, `&amp;`, `&quot;`, etc.) in place of their raw character forms — observed in cases where one reviewer invocation in a multi-task lane emits clean characters and a sibling invocation in the same lane emits encoded ones. Root cause unclear (model emission non-determinism, transcript rendering layer, or HTML-sensitive content like `<!-- … -->` inside the agent output) but the defence is uniform across the harness:

- The `agent-status-check` hook calls `html.unescape()` on the extracted response text before validating the status block, so both encoded and raw forms produce identical validation outcomes.
- The orchestrator-side parser **must do the same** when copying field values from the AGENT STATUS block to downstream artifacts (tracker rows, PR descriptions, review-history entries). Concretely: if a field value like `Review comments:` contains `&lt;` / `&gt;` / `&amp;`, treat the decoded form (`<` / `>` / `&`) as the canonical value before writing it to the tracker — otherwise the tracker accumulates HTML-encoded noise that no one decodes back. This rule applies to every field that may carry free-text or code-fragment content (`Review comments`, `Concerns`, `Blockers`, `Files changed`, `Spec issues`).

Idempotent: re-running `html.unescape()` on already-decoded text is a no-op.

## Hook enforcement

The SubagentStop hook `_agent_status_check.py` enforces a structural floor — see `scripts/agent-status-check.sh`. The hook reads the YAML schema from `agents/shared/status-schema.md` (per CC-02.4.1) — never hard-coded.

## Example status block

```
📋 AGENT STATUS
Agent: ai-sdlc-developer
Phase: 3
Story: PROJ-123
Outcome: SUCCESS
Repo: web-app
Self-review: PASS
Next action: route to reviewer for task T1
```

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [agent-response](../context/agent-response.md)
```

Inlining the parser logic in a command file is a CC-04.5 drift signal.
