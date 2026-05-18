---
name: security-report
description: >
  Composes the per-repo static security report (SAST + dependency-vuln + secret-scan).
  Discovery-driven tool selection from `.claude/context/language-config.md`. Severity
  normalisation via the per-tool map. Returns 0 (no findings ≥ medium) / 1 (findings present)
  / 2 (precondition unmet — tool missing).
version: 1.0
inputs:
  - name: repo_path
    type: arg
    description: Local repo path from `repos-paths.md`.
  - name: workflow_dir
    type: arg
    description: Per-workflow output directory under `ai/<YYYY-MM-DD>-<work-item-id>/`.
outputs:
  - name: static-security-report-<repo>.md
    destination: <workflow_dir>/static-security-report-<repo>.md
    description: Per-repo static security report (CC-05.7 path).
phase: 5.5
owner_role: orchestrator
---

# /security-report — Static Security Scanner Composition

<!-- Created by: dev-workflow-plan.md [M-18] [IMPL-18-02]
     Reason: P5.5 phase aggregator — composes SAST + dependency + secret-scan results per repo
     into a single normalised report. Dispatched per-language via `language-config.md`.
     CC conventions applied: CC-01.1, CC-01.4, CC-01.5, CC-01.7. -->

## Purpose

Per-repo composition of static security findings from SAST (bandit / semgrep / gosec / spotbugs / dotnet-analysers), dependency CVE scanners (safety / npm audit / govulncheck / mvn dependency-check), and secret scanners (trufflehog when installed).

## When to use

- Invoked by `commands/security-review.md` (P5.5) once per repo lane.
- May be invoked manually for ad-hoc audits.

## Preconditions

- `language-config.md` for the repo declares the language and toolchain.
- The repo's feature branch is checked out (this skill does not switch branches).
- Required per-language tools are installed; absence is fail-closed per CC-01.5 / CC-09 (no silent skip).

## Steps

> Authoritative references: [provider-resolver](../dev-workflow/context/provider-resolver.md), [summary-render](../dev-workflow/context/summary-render.md), [timestamp](../dev-workflow/context/timestamp.md), [workflow-paths](../dev-workflow/context/workflow-paths.md)

1. **Resolve language** from `language-config.md` for the repo.
2. **Dispatch tools** per the language → tool map (see Tool Dispatch Table below).
3. **Run each tool** in subprocess; capture structured output (JSON / SARIF where supported, plain text otherwise).
4. **Normalise severity** via `severity-map.md` (per-tool map; reduces every tool's severity vocabulary to the canonical `high | medium | low`).
5. **Compose** `static-security-report-<repo>.md` with three sections: Findings, Severity Counts, Tools Used.
6. **Exit code**: `0` (no finding ≥ medium), `1` (≥ 1 medium-or-higher finding), `2` (tool not installed; precondition unmet).

## Tool Dispatch Table

| Language | SAST | Dependency / CVE | Secret scan (optional) |
|---|---|---|---|
| python | `bandit -r <repo>` | `safety check --json` | `trufflehog filesystem <repo>` |
| javascript / typescript | `semgrep --config=auto <repo>` | `npm audit --json` | `trufflehog` |
| go | `gosec -fmt=json -quiet ./...` | `govulncheck -json ./...` | `trufflehog` |
| java | `spotbugs -textui <repo>/target/*.jar` | `mvn dependency-check:aggregate` | `trufflehog` |
| csharp | `semgrep --config=auto <repo>` | `dotnet list package --vulnerable --include-transitive` | `trufflehog` |

Languages not in the table fall back to `semgrep --config=auto <repo>` (language-agnostic) for SAST and emit `dependency: not-scanned (no per-language adapter)` for CVE.

## Severity Normalisation

Per-tool severity map lives in `severity-map.md` (sibling file). Canonical levels: `high | medium | low`. Tools that report a richer scale (e.g. CVSS 0-10) collapse via:
- CVSS ≥ 7.0 → `high`
- CVSS 4.0..6.9 → `medium`
- CVSS < 4.0 → `low`

## Outputs

| Destination | Content |
|---|---|
| `<workflow_dir>/static-security-report-<repo>.md` | Per-repo report (Findings + Severity Counts + Tools Used) |
| Exit code | 0 / 1 / 2 per CC-01.5 |

## Exit criteria

- Report file exists at the canonical path.
- Every dispatched tool either completed or produced a `.error.md` entry in the report's Tools Used section.

## Failure modes

| Failure | Detection | Response |
|---|---|---|
| Required tool not installed | `which <tool>` returns nothing | Exit 2 with `[CC-09] required tool <name> not installed for <language>; install or override in language-config.md`. |
| Tool produces malformed output | JSON parse fails | Record entry in Tools Used as `(parse failed: <cause>)`; continue with other tools; do not block. |
| Subprocess timeout | `subprocess.run timeout=600` | Lane fails BLOCKED; surface verbatim. |

## Related skills

- `commands/security-review.md` — orchestrator entry point that invokes this skill per repo.
- `metrics-collector` — counts findings into `_metrics-log.csv` columns `security_findings_high|medium|low` (M-18 IMPL-18-05 schema bump 1.0.0 → 1.1.0).
