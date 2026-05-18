# Mermaid Diagram Styling — Canonical Palette

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-19]
     Reason: Canonical 9-line Mermaid classDef palette — pinned by CC-08.4 standing acceptable-variance invocation.
     CC conventions applied: CC-04.2, CC-04.4, CC-04.6, CC-08.4 -->

## Purpose

Canonical 9-line Mermaid `classDef` palette that every per-phase diagram in `dev-workflow-phases.md` (and every other diagram in the harness) must reproduce **byte-identically**. Per CC-08.4 the duplication is structurally unavoidable (Mermaid has no include / extends / theme-from-file directive); the **logical** invariant — that every diagram renders identical node colors — is enforced by `CC07-diagram-palette.convention-check.test.sh` (TEST-184).

## Canonical palette (9 lines — copy verbatim)

```
classDef input fill:#ecffec,stroke:#3a7,stroke-width:1px,color:#063
classDef output fill:#eaf3ff,stroke:#36b,stroke-width:1px,color:#024
classDef skill fill:#fff7d8,stroke:#b80,stroke-width:1px,color:#530
classDef agent fill:#f4eaff,stroke:#6b3,stroke-width:1px,color:#303
classDef hook fill:#ffe9e9,stroke:#c33,stroke-width:1px,color:#601
classDef human fill:#fff1de,stroke:#a60,stroke-width:1px,color:#420
classDef orch fill:#dde6fa,stroke:#446,stroke-width:1.5px,color:#013
classDef decision fill:#fff,stroke:#444,stroke-width:1.5px,color:#000
classDef error fill:#ffd9d9,stroke:#a00,stroke-width:2px,color:#600
```

## Class semantics

| Class | Use for |
|---|---|
| `:::input` | Inputs into a phase / step (artifacts read in) |
| `:::output` | Outputs produced by a phase / step (artifacts written) |
| `:::skill` | Skill invocations |
| `:::agent` | Agent invocations (planner / developer / tester / reviewer) |
| `:::hook` | Hook gates (PreToolUse / SubagentStart / Stop / etc.) |
| `:::human` | Human-in-the-loop decision (GATE prompt, ad-hoc request) |
| `:::orch` | Orchestrator routing nodes |
| `:::decision` | Decision diamonds |
| `:::error` | In-phase error nodes (per CC-07.4.4) |

## Subset rule (per TEST-184)

A diagram may **omit** unused class lines — e.g. an overview diagram that has no `:::orch` nodes may drop the `classDef orch` line. The Convention-Check rule is **subset, not equality**: every classDef line that appears in any diagram must be byte-identical to the canonical line above. Lines may be omitted; lines may not diverge.

Forbidden:

- Adding a new class line to a diagram without first adding it to this canonical file.
- Changing any color / stroke / fill / stroke-width of an existing class line.
- Reordering — line order in this file is irrelevant for matching; the byte-identity check is per-line.

## Copy-paste-ready snippet for new diagrams

Paste the full 9-line block at the bottom of any new `flowchart` diagram in `dev-workflow-phases.md` (or anywhere else in the harness), then remove any class line your diagram does not use:

```
%% --- Canonical palette — see agents/shared/diagram-styling.md ---
classDef input fill:#ecffec,stroke:#3a7,stroke-width:1px,color:#063
classDef output fill:#eaf3ff,stroke:#36b,stroke-width:1px,color:#024
classDef skill fill:#fff7d8,stroke:#b80,stroke-width:1px,color:#530
classDef agent fill:#f4eaff,stroke:#6b3,stroke-width:1px,color:#303
classDef hook fill:#ffe9e9,stroke:#c33,stroke-width:1px,color:#601
classDef human fill:#fff1de,stroke:#a60,stroke-width:1px,color:#420
classDef orch fill:#dde6fa,stroke:#446,stroke-width:1.5px,color:#013
classDef decision fill:#fff,stroke:#444,stroke-width:1.5px,color:#000
classDef error fill:#ffd9d9,stroke:#a00,stroke-width:2px,color:#600
```

## Rationale for the duplication

Mermaid has no `@include`, `extends`, `theme-from-file`, or comparable directive. Every diagram must carry its own classDef block to render — there is no markdown-native way to share styling. Two options were considered:

1. **Compile-step approach** — pre-process markdown to inline a shared palette. Rejected: it breaks markdown-native authoring (`open the .md, write a diagram, render it`); the compile step would be a hidden contract every author has to remember.
2. **Document the variance, pin the bytes** — accept the physical duplication; pin the logical invariant via a Convention-Check. **Adopted** — this is CC-08.4's standing acceptable-variance invocation.

The duplication is therefore **structurally permitted**; logical divergence is **structurally forbidden** by `CC07-diagram-palette.convention-check.test.sh` (TEST-184).

## Citation form

This file is **not** cited inline in diagrams — diagrams contain the canonical palette directly (that is the point of the standing variance). Skill / hook / agent files that *describe* diagram conventions cite this file with:

```markdown
> Authoritative reference: [diagram-styling](../../agents/shared/diagram-styling.md)
```
