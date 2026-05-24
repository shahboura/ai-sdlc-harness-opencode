# Command Manifest Schema

> **Authority:** ADR-009, FR-6 (Orchestrator Introspection), M-28 IMPL-28-01
> **Consumed by:** `cc-check-phase-manifest-drift.py` (US-E07-004), `/dev-workflow inspect` (US-E07-005), `--dry-run` flag handler (US-E07-006)
> **Created by:** dev-workflow-plan.md [M-28] [IMPL-28-01]

Every command file under `skills/dev-workflow/commands/<cmd>.md` MUST have a sibling
`<cmd>.manifest.yaml` declaring the command's machine-readable metadata. This schema
is the single source of truth for manifest validation.

---

## Schema

```yaml
# ── Required fields ─────────────────────────────────────────────────────────

phase_id: <string>
# The workflow phase this command drives (e.g. "P1-P2", "P3", "P5", "P6").
# Use the canonical phase identifiers (P1-P2, P3, P4, P5, P5.5, P5.6, P6,
# P7, P8, P9, Q, IG, R, Inspect, or compound forms like "P3-hotfix").
# Utility commands that span multiple phases use the hyphen form: "P1-P2".

hooks_fired:
  # List of hook event + matcher pairs that fire during this command's execution.
  # List only hooks that are meaningfully fired (i.e. actions that trigger them
  # occur in this command's normal flow). Omit hooks that never fire.
  - event: <PreToolUse | PostToolUse | SubagentStop | SubagentStart | Stop>
    matcher: <matcher string from hooks.json, or "" for wildcard>

agents_invoked:
  # List of agent type identifiers invoked by this command.
  # Use the canonical agent names from the harness agent definitions.
  # Empty list ([]) for orchestrator-only commands.
  - <agent-type-identifier>

read_set:
  # List of LITERAL file paths read by this command (or its agents).
  # NO glob patterns (*, **, ?, [a-z]) — literal paths only.
  # Paths are relative to the workspace root.
  # Template variables like <date>-<id> are permitted (not globs).
  - <literal-path>

writes:
  # List of LITERAL output paths written by this command (or its agents).
  # Same literal-paths-only rule as read_set.
  # Include the primary artifacts this command produces.
  - <literal-path>

# ── Optional fields ──────────────────────────────────────────────────────────

gate_id: <string>
# The human-approval gate this command presents, if any.
# Standard gates: GATE-1 (plan approval), GATE-2 (impl approval),
# GATE-2.5 (security waive/defer), GATE-3 (pre-PR approval), GATE-4 (PR review),
# GATE-5 (ad-hoc confirmation). Omit if the command has no human gate.
```

---

## Validation rules

| Rule | Description |
|---|---|
| No globs in `read_set` or `writes` | `*`, `**`, `?`, `[...]` patterns are rejected with "literal paths required" error |
| `phase_id` required | Must be a non-empty string matching a declared phase |
| `hooks_fired` required | May be an empty list `[]`; must be a list |
| `agents_invoked` required | May be an empty list `[]`; must be a list |
| `read_set` required | May be an empty list `[]`; must be a list |
| `writes` required | May be an empty list `[]`; must be a list |
| `gate_id` optional | Omit if command has no human gate |

---

## Full example — `develop.manifest.yaml`

```yaml
phase_id: P3

hooks_fired:
  - event: PreToolUse
    matcher: "Write|Edit|MultiEdit"
  - event: PreToolUse
    matcher: "Bash"
  - event: PostToolUse
    matcher: "Bash"
  - event: PostToolUse
    matcher: "Agent"
  - event: SubagentStop
    matcher: ""
  - event: SubagentStart
    matcher: "ai-sdlc-tester"

agents_invoked:
  - ai-sdlc-developer
  - ai-sdlc-reviewer

read_set:
  - .claude/context/provider-config.md
  - .claude/context/language-config.md
  - .claude/context/conventions.md
  - .claude/context/repos-paths.md
  - .claude/context/repos-metadata.md
  - ai/<date>-<id>/plan.md
  - ai/<date>-<id>/tracker.md

writes:
  - ai/<date>-<id>/tracker.md
```

---

## Minimal example — `metrics.manifest.yaml`

```yaml
phase_id: P9

hooks_fired: []

agents_invoked: []

read_set:
  - ai/<date>-<id>/tracker.md

writes:
  - ai/<date>-<id>/metrics-report.md
  - ai/_metrics-log.csv
```

---

## Adding a new command

When adding a new command `<cmd>.md`:
1. Create `<cmd>.manifest.yaml` in the same directory.
2. Fill in all five required fields.
3. Run `cc-check-phase-manifest-drift.py` to verify the manifest is valid and drift-free.
4. Optionally run `scripts/scaffold-command.sh <cmd>` which creates both files from a template.
