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

---

## Agent Response Contract

<!-- Extracted from orchestrator-rules.md by dev-workflow-plan.md [M-26] [IMPL-26-03]
     Reason: US-E03-004 surgery — consolidated into agent-response.md.
     CC conventions applied: CC-02.4. -->

All agents end every response with a `📋 AGENT STATUS` block. The orchestrator MUST parse this block after every agent invocation to determine the next action.

**Decision matrix based on Outcome:**

| Outcome | Orchestrator action |
|---------|-------------------|
| `SUCCESS` | Proceed to next step in workflow |
| `DONE_WITH_CONCERNS` | Proceed to next step (same as SUCCESS), but relay the Developer's `Concerns` field to the Reviewer as additional context for extra scrutiny. |
| `PARTIAL` | Read Blockers field. Retry the failed portion with targeted instructions. |
| `FAILED` | Read Blockers and build/test output. If retryable, re-invoke agent (max 1 retry). If not, pause workflow and report to human. |
| `BLOCKED` | Read Blockers field. If human input needed, present to human. If dependency-related, resolve dependency first. |

**Phase 6 Reviewer Verdict matrix** (separate field from `Outcome`; only applies when `Outcome: SUCCESS`):

| Verdict | Orchestrator action |
|---------|---------------------|
| `APPROVED` | Present the full Pre-PR Report to the human and request the gate-3 approval as normal. |
| `APPROVED_WITH_CONCERNS` | Treat the same as `APPROVED` for control-flow purposes — present the report, surface the `Warnings`/`Suggestions` sections prominently in the gate prompt, and request the gate-3 approval. The human may proceed or ask for fixes. |
| `CHANGES_REQUESTED` | Do NOT present a normal approval gate. Show the `Critical issues` block and offer the fix-or-override choice defined in `commands/create-pr.md` Step 3. |

If the Phase 6 reviewer reports `Outcome: FAILED` (build/test broken, worktree missing, etc.) the standard `Outcome` matrix above takes precedence and the Verdict is ignored.

**Per-agent status fields:**

| Agent | Key status fields |
|-------|------------------|
| **Planner** | `Outcome`, `Files written`, `Files failed`, `Blockers` |
| **Developer** | `Repo`, `Repo path`, `Worktree`, `Worktree branch`, `Commit`, `Build result`, `Build attempts`, `Files changed`, `Self-review` (no tracker fields — orchestrator owns tracker) |
| **Reviewer (Phase 3/5)** | `Repo`, `Repo path`, `Spec compliance`, `Code quality verdict`, `Verdict`, `Worktree reviewed`, `Build verified`, `Tests verified`, `Review comments` (full `[S<n>]`/`[R<n>]`/`[T<n>]` list) |
| **Tester** | `Repo`, `Repo path`, `Task`, `Tests written`, `Tests passing`, `Coverage %`, `Test attempts`, `Commit` |
| **Reviewer (Phase 6)** | `Verdict`, `AC coverage`, `Task coverage`, `Test coverage`, `Critical issues` — full Pre-PR Report in response body. See `agents/reviewer/pre-pr.md`. |
| **Reviewer (Phase 7)** | `Outcome`, `Comments analysed`, `Valid`, `Invalid`, `Partial` — full PR Comment Analysis Report in response body. See `agents/reviewer/pr-comment-analysis.md`. |

**Parsing rules:**
1. Look for `📋 AGENT STATUS` in the agent response.
2. If the block is MISSING, the Stop hook will catch this and force the agent to add it. If after retry it's still missing, log a warning and proceed based on the agent's prose output.
3. Extract the `Outcome` field first — it determines the branch.
4. For Developer: also check `Repo`, `Repo path`, `Worktree`, `Worktree branch`, `Commit`, `Build result`, `Build attempts`, and `Self-review`. If `Build attempts: 3` and `FAILED`, do NOT retry — escalate. The `Repo`, `Repo path`, and worktree fields are REQUIRED for the reviewer and merge steps. Use `Repo` to map the agent back to its lane.

   **Self-review enforcement:** the combination `Outcome: SUCCESS` + `Self-review: FAIL` is invalid by definition (self-review is a commit precondition). If you observe it, override the Outcome to `PARTIAL` and re-route via the standard `PARTIAL` handler — re-invoke the Developer with the failed self-review check(s) as focused instructions. Do not advance the lane to review while self-review is failing.
5. For Reviewer: check `Verdict`. If `CHANGES_REQUESTED`, extract structured comments from the `Review comments` field and route them per the three-prefix model in `context/comment-routing.md` — `[R<n>]` to the Developer, `[T<n>]` to the Tester, `[S<n>]` by file path (production → Developer, test → Tester). The orchestrator (not the reviewer) updates the task tracker.
6. For Tester: check `Tests passing` and `Coverage`. If `Coverage` < 90% after `Test attempts: 3`, escalate.
