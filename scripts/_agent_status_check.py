#!/usr/bin/env python3
"""SubagentStop hook — enforce that every subagent response ends with a
properly-shaped `📋 AGENT STATUS` block.

Reads the hook payload file path from argv[1].

Schema: `agents/shared/status-schema.md`. This hook enforces the universal
floor only. Mode-specific field enforcement lives in
`tests/skills/status-schema.test.sh` (doc-grep regression on every agent's
status-block example) — the hook does not try to reproduce that logic
because it cannot reliably distinguish modes from one block at runtime.

Universal floor (enforced):
  - `📋 AGENT STATUS` phrase appears in the response's final tail window.
  - The block contains `Agent: <recognized name>` (planner | developer |
    tester | reviewer).
  - The block contains one of `Outcome:` or `Verdict:` with a **non-empty**
    value.
  - The block contains `Next action:` with a non-empty value.

Fail policy: fail-CLOSED when a response was extracted but the floor isn't
met; fail-OPEN when no response text can be located in the payload (logs a
warning so the gap is investigatable).

Exit 0 = allow, Exit 2 = block.
"""
from __future__ import annotations

# Changed by: dev-workflow-plan.md [M-01] [IMPL-01-09]
# Reason: Delegate `Field: Value` parsing to shared `_block_parsing` per TEST-16 / CC-04.3 / CC-08.1.
# CC conventions applied: CC-04.3 (Python `from` import), CC-08.1 (DRY extraction).
import html
import json
import re
import sys
from typing import Any

from _block_parsing import extract_field_from_block, extract_field_value


_REQUIRED_PHRASE = "📋 AGENT STATUS"
_KNOWN_AGENTS = ("ai-sdlc-planner", "ai-sdlc-developer", "ai-sdlc-tester", "ai-sdlc-reviewer")


# ──────────────────────────────────────────────────────────────────────────────
# M-23 IMPL-23-01: YAML-schema reader (CC-02.4.1 — hook reads from YAML, never
# hardcoded constants).
#
# PyYAML is a SOFT dependency. When absent, the hook falls back to the existing
# hardcoded universal-required check (CC-02.4 minimum floor) and logs a
# one-line advisory. This preserves backward compatibility for installs that
# haven't picked up the new dependency yet, while making the schema
# authoritative wherever PyYAML is available.
# ──────────────────────────────────────────────────────────────────────────────

import os.path as _osp

_SCHEMA_CACHE: dict | None = None


def _schema_path() -> str:
    """Resolve `agents/shared/status-schema.md` relative to this script."""
    here = _osp.dirname(_osp.abspath(__file__))
    return _osp.normpath(_osp.join(here, "..", "agents", "shared", "status-schema.md"))


def _load_yaml_schema() -> dict | None:
    r"""Return the parsed YAML schema or None when unavailable.

    Caches the parse for the lifetime of the process. Returns None when:
      - PyYAML is not installed (fallback path)
      - status-schema.md is absent / unreadable
      - The schema file contains no ```yaml block
      - The YAML fails to parse (logged advisory; hook continues with fallback)
    """
    global _SCHEMA_CACHE
    if _SCHEMA_CACHE is not None:
        return _SCHEMA_CACHE
    try:
        import yaml  # type: ignore
    except ImportError:
        return None
    path = _schema_path()
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    m = re.search(r"```yaml\s*\n(.*?)\n```", text, re.DOTALL)
    if not m:
        return None
    try:
        data = yaml.safe_load(m.group(1))
    except Exception as e:
        print(
            f"agent-status-check: ⚠ status-schema.md YAML block failed to parse "
            f"({type(e).__name__}); falling back to hardcoded universal-required check.",
            file=sys.stderr,
        )
        return None
    if not isinstance(data, dict):
        return None
    _SCHEMA_CACHE = data
    return data


def _schema_universal_required() -> list[str] | None:
    schema = _load_yaml_schema()
    if not schema:
        return None
    val = schema.get("universal_required")
    return val if isinstance(val, list) else None


def _schema_outcome_enum() -> list[str] | None:
    schema = _load_yaml_schema()
    if not schema:
        return None
    val = schema.get("outcome_enum")
    return val if isinstance(val, list) else None


def _normalise_agent_name(raw: str) -> str:
    """Strip the `ai-sdlc-` prefix to match the YAML schema's role keys."""
    if not raw:
        return ""
    return raw.replace("ai-sdlc-", "", 1).strip()


def _schema_required_for(agent: str, mode: str | None) -> list[str] | None:
    """Return the `required` list for `roles.<agent>.modes.<mode>`, or None.

    `agent` is the normalised name (`planner` / `developer` / `tester` / `reviewer`).
    When `mode` is None, returns the union of all modes' required fields for
    that role (conservative — universal across the role's modes).
    """
    schema = _load_yaml_schema()
    if not schema:
        return None
    roles = schema.get("roles") or {}
    role_entry = roles.get(agent) or {}
    modes = role_entry.get("modes") or {}
    if mode and mode in modes:
        return modes[mode].get("required") or []
    # No specific mode — return the intersection of all modes' required.
    if not modes:
        return None
    required_sets = [set(modes[m].get("required") or []) for m in modes]
    if not required_sets:
        return None
    return sorted(set.intersection(*required_sets))

# The tail window scales with response length: at least 10 lines so a typical
# status block (header + ~8 fields + short prose preamble) fits in a short
# response, at most 50 so very long responses don't get a slack window.
# Between the bounds it tracks the last ~quarter of the response.
_TAIL_LINES_MIN = 10
_TAIL_LINES_MAX = 50


def _tail_window(line_count: int) -> int:
    return min(_TAIL_LINES_MAX, max(_TAIL_LINES_MIN, line_count // 4))


def _extract_text(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = [
            p.get("text", "")
            for p in content
            if isinstance(p, dict) and p.get("type") == "text"
        ]
        return "\n".join(parts)
    return ""


def _extract_response(payload: dict) -> str:
    """Try multiple known and plausible keys, then fall back to the most
    recent assistant message in `messages`/`transcript`.

    HTML-entity normalisation: subagents occasionally emit responses with HTML
    entities (`&lt;`, `&gt;`, `&amp;`, `&quot;`, etc.) instead of their raw
    character forms — observed when one reviewer invocation in a multi-task
    lane emits clean characters and a sibling invocation in the same lane
    emits encoded ones. Cause is unclear (model emission non-determinism,
    transcript rendering layer, or HTML-sensitive content like `<!-- … -->` in
    the agent output) but the *defence* is uniform: `html.unescape()` the
    extracted text before downstream parsing so the validator, status-block
    extractor, and every consumer sees a single canonical form. Idempotent on
    already-decoded text (no entity sequences → no-op).
    """
    raw: str = ""
    for k in ("response", "agent_response", "final_response", "text", "output", "result"):
        v = payload.get(k)
        if isinstance(v, str) and v:
            raw = v
            break
        if isinstance(v, list):
            joined = _extract_text(v)
            if joined:
                raw = joined
                break
    if not raw:
        msgs = payload.get("messages") or payload.get("transcript") or []
        if isinstance(msgs, list):
            for m in reversed(msgs):
                if isinstance(m, dict) and m.get("role") == "assistant":
                    text = _extract_text(m.get("content", ""))
                    if text:
                        raw = text
                        break
    return html.unescape(raw) if raw else ""


def _field_value(block: str, field: str) -> str | None:
    """Delegate to `_block_parsing.extract_field_value` per CC-04.3 / CC-08.1
    (M-01 IMPL-01-09). Wrapper preserved so callsites keep a stable name.
    """
    return extract_field_value(block, field)


def _validate(response: str) -> tuple[bool, str]:
    """Return (ok, reason). reason is empty when ok=True."""
    if _REQUIRED_PHRASE not in response:
        return False, f'response does not contain the literal phrase "{_REQUIRED_PHRASE}"'

    # M-23 IMPL-23-03: reject transcripts with > 1 status block. CC-02.4 says
    # the block IS the agent's terminal contract; a second block is either a
    # copy-paste artefact or an attempt to confuse the parser.
    block_count = response.count(_REQUIRED_PHRASE)
    if block_count > 1:
        return (
            False,
            f'response contains {block_count} `{_REQUIRED_PHRASE}` markers — exactly one is '
            f'allowed. Remove the earlier marker(s); the block at end-of-response is the '
            f'authoritative one.',
        )

    lines = response.splitlines()
    tail_size = _tail_window(len(lines))
    tail = "\n".join(lines[-tail_size:])
    if _REQUIRED_PHRASE not in tail:
        return (
            False,
            f'the "{_REQUIRED_PHRASE}" phrase appears, but not in the response\'s '
            f'final {tail_size} lines (of {len(lines)} total) — the block must end '
            f'the response.',
        )

    block_start = response.rfind(_REQUIRED_PHRASE)
    block = response[block_start:]

    # `Agent:` with a recognized name.
    agent_val = _field_value(block, "Agent")
    if agent_val is None:
        return False, 'the block has no `Agent:` field. Add one of: ai-sdlc-planner | ai-sdlc-developer | ai-sdlc-tester | ai-sdlc-reviewer.'
    if agent_val.strip() not in _KNOWN_AGENTS:
        return (
            False,
            f'`Agent:` value `{agent_val.strip() or "(empty)"}` is not recognized. '
            f'Expected one of: {" | ".join(_KNOWN_AGENTS)}.',
        )

    # Outcome OR Verdict with a non-empty value.
    outcome_val = _field_value(block, "Outcome")
    verdict_val = _field_value(block, "Verdict")
    has_outcome = outcome_val is not None and outcome_val.strip() != ""
    has_verdict = verdict_val is not None and verdict_val.strip() != ""
    if not (has_outcome or has_verdict):
        # Distinguish "field absent" from "field present but empty" so the
        # error message is precise.
        outcome_state = "absent" if outcome_val is None else "empty"
        verdict_state = "absent" if verdict_val is None else "empty"
        return (
            False,
            f'the block needs at least one of `Outcome:` / `Verdict:` with a '
            f'non-empty value. Currently: Outcome={outcome_state}, Verdict={verdict_state}.',
        )

    # Next action with a non-empty value.
    next_action_val = _field_value(block, "Next action")
    if next_action_val is None or next_action_val.strip() == "":
        return (
            False,
            'the block needs a `Next action:` field with a non-empty value '
            "(the orchestrator's decision matrix routes on this).",
        )

    # M-23 IMPL-23-01: when the YAML schema is loadable, enforce its
    # universal_required + outcome_enum + (advisory) per-role-mode required
    # lists. Source of truth per CC-02.4.1 lives in `agents/shared/status-schema.md`.
    #
    # Substitution rules honoured (preserve legacy hook semantics):
    #   - When `Outcome` is in universal_required AND `Verdict:` is present
    #     and non-empty, the Outcome requirement is satisfied. Reviewer modes
    #     substitute Verdict for Outcome — the routing signal is equivalent.
    schema_universal = _schema_universal_required()
    if schema_universal:
        for field in schema_universal:
            if field == "Outcome" and has_verdict:
                continue  # Verdict-substitution rule
            v = _field_value(block, field)
            if v is None or v.strip() == "":
                return (
                    False,
                    f'CC-02.4.1: status-schema.md declares `{field}` as universal_required; '
                    f'block is missing it.',
                )

    # Outcome enum check (when schema declares one).
    outcome_enum = _schema_outcome_enum()
    if outcome_enum and has_outcome:
        oc_val = outcome_val.strip() if outcome_val else ""
        if oc_val and oc_val not in outcome_enum:
            return (
                False,
                f'CC-02.4.1: `Outcome: {oc_val}` not in declared enum '
                f'{outcome_enum}. Use one of the declared values.',
            )

    # Per-role-mode required-field check (ADVISORY — emits to stderr but does
    # NOT block). The mode-specific required-field lists are aspirational
    # contracts that legacy agent fixtures don't always satisfy. M-12 backfill
    # will tighten this to fail-closed once every agent emission carries the
    # full per-mode field set.
    agent_normalised = _normalise_agent_name(agent_val.strip())
    mode_val = _field_value(block, "Mode")
    mode = mode_val.strip() if mode_val else None
    per_role_required = _schema_required_for(agent_normalised, mode)
    if per_role_required:
        missing = [f for f in per_role_required if _field_value(block, f) is None]
        if missing:
            print(
                f"agent-status-check: ADVISORY — schema declares fields "
                f"{missing} as required for `{agent_normalised}`"
                f"{' mode ' + mode if mode else ''}; block omits them. "
                f"M-12 backfill will turn this into a hard block.",
                file=sys.stderr,
            )

    return True, ""


def main() -> int:
    if len(sys.argv) < 2:
        return 0
    try:
        with open(sys.argv[1], "r", encoding="utf-8") as f:
            payload = json.load(f)
    except (OSError, json.JSONDecodeError):
        return 0

    response = _extract_response(payload)
    if not response:
        # No text to evaluate — emit a stderr warning and pass.
        # Fail-OPEN here so that an unfamiliar payload shape doesn't
        # block every subagent stop; the agent-status contract is
        # still enforced wherever the response *can* be located.
        #
        # CHANGED: when `agent_type` is present in the payload AND names a
        # recognised agent, the response SHOULD have been extractable. Empty
        # response in that case is a strong signal of an ungraceful stop
        # (turn-cap hit mid-action, API error, tool failure). Emit a louder
        # warning that names the agent and points at the Stalled-Agent
        # Recovery sequence so the orchestrator routes through re-invocation
        # rather than wandering into a role-boundary violation.
        try:
            from _subagent_utils import normalize_agent_type, is_known_agent_type
            agent = normalize_agent_type(payload)
        except Exception:
            agent = None
        if agent and is_known_agent_type(agent):
            print(
                f"agent-status-check: ⚠ STALLED AGENT DETECTED — `{agent}` ended without "
                f"emitting a `📋 AGENT STATUS` block (response text could not be located in "
                f"the SubagentStop payload).",
                file=sys.stderr,
            )
            print(
                "  Likely cause: `maxTurns` cap hit mid-action, API error, or tool failure.",
                file=sys.stderr,
            )
            print(
                "  Orchestrator recovery (NON-NEGOTIABLE per orchestrator-rules.md → "
                "Stalled-Agent Recovery): RE-INVOKE the agent with a continuation prompt "
                "naming any uncommitted files in its worktree. DO NOT commit on the agent's "
                "behalf — that crosses the CC-02.1 role boundary.",
                file=sys.stderr,
            )
        else:
            print(
                "agent-status-check: could not locate response text in payload; "
                "passing without check.",
                file=sys.stderr,
            )
        return 0

    ok, reason = _validate(response)
    if ok:
        return 0

    print("agent-status-check: blocking subagent stop", file=sys.stderr)
    print(f"  - {reason}", file=sys.stderr)
    print("", file=sys.stderr)
    print(
        'Every subagent must end its response with a block of the form:\n'
        "    📋 AGENT STATUS\n"
        "    - Agent: ai-sdlc-planner | ai-sdlc-developer | ai-sdlc-tester | ai-sdlc-reviewer\n"
        "    - Outcome: SUCCESS | PARTIAL | FAILED | BLOCKED   (or Verdict: for reviewers)\n"
        "    - Next action: <one-line description>\n"
        "    (additional fields per agents/shared/status-schema.md)\n",
        file=sys.stderr,
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
