---
name: validate-mermaid
description: >
  Structural validator for Mermaid diagrams embedded in markdown files. Verifies
  every CC-07.4.1 syntax requirement — HTML entity escaping, quoted subgraph
  titles, classDef ↔ class-reference closure, node-ID closure, stadium /
  parallelogram / hexagonal shape closure, comment style, and the 60-node
  ceiling. Returns 0 (valid) / 1 (invalid + line / column / cause) / 2 (skill
  precondition unmet).
version: 1.0
inputs:
  - name: file_path
    type: arg
    description: Absolute or workspace-relative path to a .md file containing one or more Mermaid fences.
outputs:
  - name: result
    destination: stdout (advisory) / stderr (block)
    description: PASS line on stdout when valid; FAIL block on stderr with `line:col cause` per failure.
phase: cross-cutting
owner_role: orchestrator
---

# /validate-mermaid — Structural Mermaid syntax validator

<!-- Created by: dev-workflow-plan.md [M-16] [IMPL-16-01]
     Reason: CC-07.4 / GAP-23 — every Mermaid diagram emitted by the harness must pass structural validation
     before the containing artifact is considered complete. Skill replaces the legacy unstructured "just trust the agent" model.
     CC conventions applied: CC-01.1, CC-01.7, CC-04.3 (consumes `_block_parsing.py`), CC-03.2 (fail-closed when invoked from a hook). -->

## Purpose

Structural validator for every Mermaid diagram embedded in markdown across the harness. Validates the **CC-07.4.1 syntax requirements** — the structural rules that the official Mermaid parser would also reject, plus the harness's stricter additions (60-node ceiling, no `<!-- -->` comments inside fences, etc.).

## When to use

- Whenever a plan / spec / artifact ships a Mermaid fence. The PreToolUse hook (`validate-mermaid-syntax.sh`) fires automatically on `Write|Edit|MultiEdit` against `*.md` content containing `\`\`\`mermaid`.
- Manually via `/validate-mermaid <file>` to audit a hand-edited file before committing.
- As part of M-13 cc-check's pre-commit aggregator (TEST-95 — `CC07-04-mermaid-syntax.convention-check.test.sh`).

## Preconditions

- The target `.md` file exists and is readable.
- The file contains at least one ```` ```mermaid ```` fence (otherwise the skill is a no-op — exits 0 with stdout `no mermaid fences found`).
- If `mermaid-cli` is installed on PATH, it is used as a secondary validator alongside the structural rules (CC-07.4.2 — pure structural, no rendering). If absent in CI (any standard CI env var set), the hook fails-closed per CC-07.4.3. In local interactive mode, the hook fails-open with an advisory.

## Inputs

| Name | Type | Description |
|---|---|---|
| `file_path` | arg | Absolute or workspace-relative path to a `.md` file. |

## Steps

1. **Read** the file. Refuse with exit 2 if absent / unreadable.
2. **Extract** every ```` ```mermaid ... ``` ```` fence using `_block_parsing` shared helper (CC-04.3) — never re-implement fence extraction.
3. **For each fence**, apply the rule pipeline:
    - **R1**: Header line must be `flowchart <TD|LR|BT|RL|TB>` OR `graph <dir>` OR a Mermaid diagram type the harness uses (`stateDiagram`, `classDiagram`, `sequenceDiagram`). Reject unknown openers.
    - **R2**: Every node label containing `&`, `<`, `>`, `|`, or `"` must use the HTML entity form (`&amp;`, `&lt;`, `&gt;`, `&#124;`, `&quot;`). Unescaped literal `<` / `>` outside HTML entities is rejected.
    - **R3**: Every `subgraph X` line must use the quoted form `subgraph X["..."]`. The unquoted form `subgraph X [...]` is rejected per CC-07.4.1.
    - **R4**: Every `:::<class>` class reference must have a matching `classDef <class>` line in the same diagram.
    - **R5**: Every node ID used in an edge (`A --> B`, `A -->|label| B`) must be defined (declared as a node either bare or via a shape like `A[Foo]`).
    - **R6**: Edge labels containing special chars (`#`, `:`, `&`) must be quoted (`-->|"GATE #1: approved"|`). Unquoted `#` in edge labels is rejected.
    - **R7**: Every shape must close its delimiters — `[/.../]` (parallelogram), `((..))` (circle), `(((...)))` (double-circle), `{...}` (diamond), `{{...}}` (hexagonal), `([...])` (stadium). Unmatched delimiters are rejected.
    - **R8**: Comments inside diagrams MUST use `%%`; never `//` or `<!-- -->`. HTML comments inside fences render as literal text — rejected.
    - **R9**: Diagrams must NOT exceed 60 nodes (the rendering ceiling per CC-07.4.1). Reject with `[CC-07.4.1] diagram has <n> nodes; cap is 60 — split into sub-diagrams.`
    - **R10** *(opt-in, when mermaid-cli is available)*: Run `mermaid-cli --validate` on the fence content; surface its diagnostic verbatim on failure.
4. **Aggregate** failures. Exit 0 (no failures) / 1 (≥ 1 failure) / 2 (preconditions unmet — file missing, etc.).
5. **Stdout** on success: one line `mermaid: PASS — <n> fence(s) in <file>`. **Stderr** on failure: one line per rule violation `<file>:<line>:<col>: <rule>: <cause>`.

## Outputs

| Destination | Content |
|---|---|
| stdout | PASS line per success; one line `<file>: no mermaid fences found` when the file is fence-less |
| stderr | One FAIL line per rule violation; `[CC-07.4.1] ...` prefix when the violation is the harness's stricter rule (not standard Mermaid) |
| Exit code | 0 (valid) / 1 (rule violation found) / 2 (precondition unmet) |

## Exit criteria

- Every fence in the target file passes R1–R9 (and R10 when mermaid-cli is available).
- The skill always exits with one of 0 / 1 / 2 — never partial completion.

## Failure modes

| Failure | Detection | Response |
|---|---|---|
| File missing | Read fails | Exit 2 with `validate-mermaid: file not found: <path>`. |
| No fences | After fence extraction | Exit 0 with `no mermaid fences found` (no-op success). |
| Rule violation | R1–R10 detection | Exit 1; emit one FAIL line per violation to stderr. |
| mermaid-cli crash | R10 subprocess error | Exit 1 with the crash output verbatim — don't swallow. |
| mermaid-cli not installed (interactive mode) | PATH lookup fails | Exit 0 with stderr advisory `mermaid-cli not on PATH; structural rules only.` |
| mermaid-cli not installed (CI mode — any CI env var set) | PATH lookup fails + CI | Exit 2 with `[CC-07.4.3] mermaid validator unavailable in CI — install mermaid-cli`. |

## Related skills

- `plan-generator` — invokes this validator on the generated `plan.md` before stamping `Plan approved` per CC-05.3.
- `coverage-report`, `metrics-collector` — any future skill that ships a Mermaid diagram in its output runs this validator before exit.
