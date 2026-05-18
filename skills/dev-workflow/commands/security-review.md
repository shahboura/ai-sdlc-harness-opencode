# Phase 5.5: Static Security Review

> Authoritative references: [timestamp](../context/timestamp.md), [provider-resolver](../context/provider-resolver.md), [summary-render](../context/summary-render.md), [workflow-paths](../context/workflow-paths.md), [parallel-lane](../context/parallel-lane.md)

<!-- Created by: dev-workflow-plan.md [M-18] [IMPL-18-01]
     Reason: NEW P5.5 phase per RAG-25 — static security review between P5 and P6 that gates the PR on
     medium+ severity findings.
     CC conventions applied: CC-05.1, CC-07.3, CC-04.3. -->

**Phase**: 5.5 (between P5 test-hardening and P6 PR creation)
**Actor**: Orchestrator (invokes the `security-report` skill — no agents); Human gate (#2.5) when findings ≥ medium severity

## Trigger

P5 exit (all T-TEST tasks `✅ Done`). The orchestrator auto-invokes P5.5 between P5 and P6 in full-pipeline mode; manual entry via `/dev-workflow security-review <id>`.

## Preconditions

- All P5 hardening lanes returned `✅ Done` and `Test hardening completed <ts>` is stamped.
- `.claude/context/language-config.md` is populated so the per-language tool dispatch can resolve.
- The active branch (one per repo) contains both production source + tests; the security scan reads both.

## Steps

### S1 — Resolve per-repo lanes

For each repo touched by the story (from the tracker's Repo Status), spawn a per-lane invocation of `security-report` (per [parallel-lane](../context/parallel-lane.md)). Each lane runs in the repo's existing feature branch — no new worktree.

### S2 — Run SAST + dependency scan (per lane)

The `security-report` skill discovers per-repo tools from `language-config.md`:

| Language | SAST | Dependency / CVE | Secret scan |
|---|---|---|---|
| Python | bandit | safety | trufflehog (when present) |
| JS/TS | semgrep | npm audit | trufflehog |
| Go | gosec | govulncheck | trufflehog |
| Java | spotbugs + spotbugs-find-sec-bugs | mvn dependency-check | trufflehog |
| C# | semgrep | dotnet list package --vulnerable | trufflehog |

Per CC-09 the severity gate is `≥ medium` by default; per-tool normalisation lives in `skills/security-report/severity-map.md`.

### S3 — Write per-lane report

Each lane writes `ai/<workflow_dir>/static-security-report-<repo>.md` (per CC-05.7) with sections:
- **Findings** — one row per finding (rule ID, file:line, severity, message).
- **Severity Counts** — `high`, `medium`, `low` totals.
- **Tools Used** — which tools were dispatched and their versions.

### S4 — Aggregate and gate

Sum severity counts across all per-repo reports. Two outcomes:

- **No finding ≥ medium severity** → auto-proceed to P6. Stamp `Security review completed <ts>` to the tracker; no gate.
- **At least one finding ≥ medium** → fire **GATE #2.5** (human decision):
    ```
    ⚠ P5.5 Security Review surfaced N findings (high: <h>, medium: <m>).
    Decisions:
      [waive]    — accept the findings as-is; proceed to P6 with a deviation note.
      [fix-now]  — route back to P3 to fix the source; re-runs P5 then P5.5.
      [defer]    — create follow-up story for the findings; proceed to P6.
    ```

### S5 — Record metric

Stamp `Security review completed <ts>` to the tracker's `## Metrics` block using the canonical UTC timestamp (see [timestamp](../context/timestamp.md)).

## Outputs

| Artifact | Path | Format |
|---|---|---|
| Per-repo report | `ai/<workflow_dir>/static-security-report-<repo>.md` | Markdown; sections Findings / Severity Counts / Tools Used |
| Tracker stamp | Tracker `## Metrics` | `Security review completed <ts>` |
| Gate decision (when fired) | Tracker — `Gate #2.5 <waive|fix-now|defer> <ts>` | Stamp per decision |

## Exit Criteria

1. Per-repo `static-security-report-<repo>.md` exists for every repo.
2. No finding ≥ medium severity OR GATE #2.5 resolved with `waive` / `fix-now` / `defer`.
3. `Security review completed <ts>` stamped.

## Failure Modes

| Failure | Detection | Response |
|---|---|---|
| Required tool not installed | S2 dispatch | Exit 2 with `[CC-09] required tool <name> not installed for <language>`; do not silently skip. |
| Scan timeout | S2 subprocess timeout | Lane reports `Outcome: BLOCKED`; sync aggregator marks the lane failed; orchestrator surfaces verbatim. |
| Severity-map drift | Per-tool severity not in `severity-map.md` | Treat as `medium` (defensive default); surface advisory; do not block. |
| Gate stalled > 24h | CC-09 `gate_stall_threshold_hours` | `workflow-status` surfaces stall via `Gate prompted <ts>` stamp. |

## CC Conventions Applied

- CC-05.1 — Phase contract.
- CC-05.3 — Explicit phase exit (`Security review completed <ts>`).
- CC-05.6 — Parallel-lane fan-out (one lane per repo).
- CC-05.7 — Per-workflow canonical paths.
- CC-04.3 — All shared snippets cited.
- CC-09 — Severity gate threshold (`security_gate_severity`) sourced from `state.md`.

## Next Phase

P6 (PR creation) on auto-proceed OR `waive` / `defer`. P3 re-entry on `fix-now`.
