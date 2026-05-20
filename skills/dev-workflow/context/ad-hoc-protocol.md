# Ad-Hoc Request Protocol

> Owner: cross-cutting
> Version: 1.0

<!-- Extracted from orchestrator-rules.md by dev-workflow-plan.md [M-26] [IMPL-26-03]
     Reason: US-E03-004 surgery — moved per-phase detail to context file.
     Primary consumer: commands/handle-request.md
     CC conventions applied: CC-04.8, CC-04.4. -->

> Authoritative reference: consumed by `commands/handle-request.md`.

## Ad-Hoc Request Handling

Between approval gates the human may submit ad-hoc requests — typically while exercising the implementation before Phase 4 approval, at GATE #2 / GATE #3 instead of `APPROVED`, or mid-phase via `/dev-workflow request <story-id> "<text>"`. The orchestrator MUST route every such request through `commands/handle-request.md` before any code work begins; silently treating a request as a free-form "fix this" instruction is a workflow failure.

### Mandatory Triage Before Action

1. **No code work without triage.** When a request arrives, the orchestrator does NOT invoke the Developer, the Tester, or the Planner directly. The first agent invocation MUST be `@ai-sdlc-reviewer` with `mode: request-triage` to classify the request against the approved plan and acceptance criteria.
2. **In-scope items still require human confirmation (GATE #5).** Even when the Reviewer classifies a request as `IN_SCOPE_BUG` or `IN_SCOPE_AC_MISS`, the orchestrator MUST present the triage report and wait for the human's confirmation before invoking the Planner with `MODE: ad-hoc-tasks`. Auto-creating tasks bypasses the gate and violates rule #2.
3. **Out-of-scope items are never silently merged.** When the Reviewer returns `OUT_OF_SCOPE` or `PLAN_CONFLICT`, the orchestrator MUST surface the classification with the conflicting plan section (for `PLAN_CONFLICT`) and the explicit `[a] Expand scope / [b] Defer as new story / [c] Withdraw` options. The orchestrator does NOT decide which option to take.
4. **Plan amendments re-enter GATE #1 scoped to the amendment delta.** When the human picks `[a] Expand scope`, the Planner runs in `MODE: plan-amendment`, the orchestrator re-presents the amendment for approval (a scoped re-run of GATE #1 limited to the amendment section), and only on approval invokes `MODE: ad-hoc-tasks` to create the tracker rows. A rejected amendment reverts the plan write and falls through to `[b]` or `[c]`.

### Mid-Phase Request Handling (Synchronous, Non-Negotiable)

When a request arrives mid-Phase 3 or mid-Phase 5 (background agents in flight), the orchestrator handles it **synchronously and in-line** — there is no orchestrator-side queue and no "drain at the next safe checkpoint" hook. Specifically:

1. The orchestrator captures the request text and assigns the next `[AHR-<n>]` ID **immediately**.
2. The orchestrator runs `commands/handle-request.md` Steps 2–6 in the current turn — Reviewer triage, GATE #5 presentation, and (on confirmation) Planner row-append. Steps 2–6 only touch the tracker via the Planner and do not require any lane to be idle.
3. **Concurrency model:** background agents spawned with `run_in_background: true` are independent processes — they continue executing while the orchestrator handles the request. But the orchestrator is a single turn-based loop and cannot *service* their completion notifications until it finishes the current request-handling turn (which includes a human gate at Step 4 — potentially a long pause). Notifications that arrive during request handling queue up at the loop layer; they are processed in the usual `develop.md` Step 2 order **after** Step 6 returns. Background agents are not preempted, killed, or paused — they simply complete on their own clock and their completion handlers are deferred.
4. After Step 6, control returns to the standard lane main loop. New ad-hoc rows are ⏳ Pending in the tracker; the lane picks them up in tracker order on its next idle-cycle (after any deferred completion handlers run and the currently-running task completes), per the picker in `develop.md` Step 1. Since ad-hoc rows are appended **below** any existing pending main-table rows in the same repo, they are scheduled *after* those pending rows — not in front of them.
5. Phase 5 (`test.md`) interacts the same way: if a T-TEST task is in flight when a mid-phase request arrives, T-TEST continues to completion; ad-hoc rows are then picked up by their target repo's lane in the standard order. There is no explicit "pause Phase 5 to run ad-hoc" path — that's the gate-entry path's job.

**Practical impact**: a lane whose reviewer completes during request handling won't see its squash-merge until after GATE #5 closes. That latency is inherent to the single-loop orchestrator and is acceptable for the typical request-handling time. The orchestrator's documentation deliberately does NOT claim parallel orchestrator execution; only the background agents themselves run in parallel.

**Priority knob for the human**: if the in-scope ad-hoc item must run *before* additional main-table work proceeds, raise the request at the next gate (GATE #2 or GATE #3) instead of mid-phase. Gate-entry routes pause the workflow until the new batch is ✅ Done, then return to the gate; mid-phase routes do not.

### Tracker Section Ownership

The `## Ad-hoc Tasks (Batch <N>)` section is owned by the Planner (`MODE: ad-hoc-tasks`) — only the Planner creates row entries, only the orchestrator updates Status / Reviewer Verdict / Commit(s) on existing rows per the standard transitions. The same separation as the main task table applies.

The `## Deferred Requests` section is owned by the **orchestrator** (not the Planner). The orchestrator writes rows directly via Read+Write when the human picks `[2] Skip`, `[b] Defer as new story`, `[c] Withdraw`, `[d] Acknowledge`, `[g] Skip`, or `[SKIP-ALL]` at GATE #5. These are non-task records — there is no failure mode the Planner could add by being involved, and routing through the Planner would introduce an extra agent invocation for what is effectively a tracker append.

### Failure-Mode Pinning

These triage failure modes have prescribed handlers — the orchestrator MUST follow them and MUST NOT improvise alternatives:

1. **`Verdict: PLAN_NOT_FOUND`** (from any per-repo Reviewer in `mode: request-triage`) — escalate to the human and pause the request-handling flow. Do NOT fabricate a plan path. Do NOT retry with a guessed path. Do NOT proceed to GATE #5 with the remaining repos' reports (partial-state gates produce ambiguous human choices). The fix is human-side: rerun `/init-workspace` if `repos-paths.md` is stale, restore the plan from version control, or kill the request. The same rule applies to `Verdict: PLAN_NOT_FOUND` from `mode: pr-comment-analysis` in Phase 7 — handled there by `commands/review-response.md` Step 4, and pinned here for the same reason.
2. **`Verdict: TRIAGE_PARTIAL`** (Reviewer could not classify every request) — surface the unclassified rows via the GATE #5 decision matrix as `Classification: UNCLASSIFIED` with the `[f] Re-triage with hint / [g] Skip / [h] Override → <class>` choice set. Do NOT silently skip them and do NOT auto-classify them as `OUT_OF_SCOPE`. The matrix shape is the only handler — `TRIAGE_PARTIAL` never falls through.
3. **Plan-amendment rejection at the scoped GATE #1 re-presentation** — restore the plan from the orchestrator's `PLAN_SNAPSHOT` cache via the Write tool. Do NOT ask the Planner to undo its own append. Do NOT leave the rejected amendment in the plan file. The snapshot is workspace-agnostic (works whether the workspace is a git repo or not) and is the only durable rollback artifact.

### Repo-Scope Inference Bounds

When a mid-phase request via `/dev-workflow request <id> "<text>"` does not name a target repo, the orchestrator infers repos in scope by **substring-matching** repo names from `repos-metadata.md` against the request text. This is the only inference allowed. The orchestrator MUST NOT:

- Attempt semantic mapping (e.g. parsing "the API" → repo `api-gateway`, "the frontend" → repo `web-ui`). Semantic mapping is an LLM judgement and belongs to the Reviewer's classification, not the orchestrator's scoping.
- Read source code or any project file to determine scope. Source reading is a Reviewer responsibility (rule #1).

**Match classification**:

| Substring match count | State | Orchestrator action |
|-----------------------|-------|---------------------|
| Exactly 1 repo matched | **Resolved** | Invoke Reviewer for the matched repo only. |
| 0 repos matched | **No match** | Default to all repos. Invoke Reviewer for every repo in the tracker's `## Repo Status` section (populated from `repos-metadata.md`; the two sets are identical by construction — see `tracker-schema.md`). Over-broad scoping is self-correcting — the Reviewer returns `OUT_OF_SCOPE` or `INVALID` for the irrelevant repos and the GATE #5 matrix lets the human dismiss them. |
| 2 or more repos matched | **Ambiguous match** | Pause before triage. Present a disambiguation prompt to the human (see below) and resolve to a specific repo subset before invoking any Reviewer. |

**Ambiguous-match disambiguation prompt** (only fires for 2+ substring matches):

```
## Ad-Hoc Request — Repo Disambiguation

Request: "<verbatim text>"
Substring-matched repos: <repo-1>, <repo-2>, ... (matched on token "<token>")

Which repo(s) does this request target?
  [1] <repo-1>
  [2] <repo-2>
  [3] All matched repos (run triage in all of them)
  [4] All workspace repos (treat as "no match" — every repo gets triage)
  [5] Cancel — withdraw the request

  ⚠️ If you pick [3] and any matched repo has no plan slice (e.g. a repo
     added after the original plan), the per-repo Reviewer returns
     `Verdict: PLAN_NOT_FOUND` and — per the Failure-Mode Pinning rule —
     the entire batch escalates without proceeding to GATE #5. To avoid
     this cascade, pick a narrower numeric subset (e.g. "1,2") that only
     includes repos with plan slices.

Reply with one or more numbers (e.g. "1" or "1,2") or [5].
```

**Invalid-input fallback**: if the human's reply does not parse as one of `[1]`–`[5]` or a comma-separated list of valid numbers (e.g. they type free-form text, an out-of-range number, an empty line, or `3,99`), the orchestrator MUST re-render the prompt with a one-line preamble:

```
⚠️ Could not parse: "<verbatim reply>". Expected [1], [2], [3], [4], [5], or a comma-separated list of repo numbers (e.g. "1,2"). Please reply again.
```

The orchestrator does NOT infer intent from free-form text. The disambiguation prompt is the only orchestrator-side prompt that loops on invalid input; everything else uses Claude Code's standard handler. The loop has no explicit bound — the human can always type `[5] Cancel` to terminate. Two consecutive un-parseable replies are not flagged as a special case; the human is presumed to be reading the prompt.

**Provenance**: the disambiguation is recorded in the request's audit trail (the `[AHR-<n>]` row's Notes column carries `disambiguated-from: <token>` when this path fires).

**Why not always prompt the human?** Because the 0-match and 1-match cases are unambiguous and the prompt would be pure overhead. Substring-matching is deterministic; the 2+ case is the only one where the orchestrator genuinely cannot pick without a tie-break, and that's where the cost is worth paying.

**Why does `[3]` cascade on PLAN_NOT_FOUND rather than scoping it out?** Per the Failure-Mode Pinning rule above, `Verdict: PLAN_NOT_FOUND` from any per-repo Reviewer is a setup error — the orchestrator cannot quietly drop the affected repo and proceed because the human's choice of `[3]` was explicit. If we silently scoped out the broken repo, the human would not know one of their chosen repos was excluded. Escalating is the only safe behaviour; the inline warning in the prompt is the prevention mechanism.

### Provenance Marker

Every ad-hoc task row's `Notes` column MUST contain the `ad-hoc: [AHR-<n>]` token. The Phase 3 re-entry filter, the batch counter, and the post-completion gate-resumption logic all rely on this token. Removing or renaming it breaks the loop.
