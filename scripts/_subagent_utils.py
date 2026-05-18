"""Shared subagent identification utilities.

> Owner: cross-cutting
> Version: 1.0

Created by: dev-workflow-plan.md [M-01] [IMPL-01-08]
Reason: Foundational shared helper — extracts subagent-type normalisation that
appeared inline in both `_bash_write_guard.py` and `_tracker_update_reminder.py`.
CC conventions applied: CC-04.2, CC-04.3 (Python `from` form), CC-04.4 (owner = cross-cutting).

Exports:
    normalize_agent_type(payload) -> str | None
"""
from __future__ import annotations

import os
from typing import Any, Mapping, Optional


_KNOWN_AGENT_TYPES = {"developer", "reviewer", "tester", "planner"}

_SUBAGENT_PAYLOAD_KEYS = (
    "agent_type",
    "subagent_type",
    "subagent_name",
    "agent_name",
    "agentName",
    "subagent",
)


def _normalise_namespaced(raw: str) -> str:
    """Strip plugin / directory namespace prefixes — keep the last segment."""
    for sep in (":", "/"):
        if sep in raw:
            raw = raw.rsplit(sep, 1)[-1]
    return raw.lower()


def normalize_agent_type(payload: Mapping[str, Any] | None) -> Optional[str]:
    """Return the canonical agent type (`developer`/`reviewer`/`tester`/`planner`)
    given a Claude Code hook payload, or None when the payload carries no
    recognisable agent identifier.

    Canonical field per Claude Code docs is `agent_type` (present only when the
    hook fires inside a subagent call). Values may be namespaced as
    `plugin:directory:name`; this helper normalises to the last segment, lowered.

    Falls back to alternate field names that older Claude Code releases used,
    then to the `CLAUDE_SUBAGENT_NAME` env var.

    Returns None when no recognisable agent type is present (the caller decides
    whether absence is a soft pass or a contract violation).
    """
    raw: Optional[str] = None
    if payload is not None:
        for key in _SUBAGENT_PAYLOAD_KEYS:
            v = payload.get(key)
            if isinstance(v, str) and v.strip():
                raw = v.strip()
                break
    if raw is None:
        env_v = os.environ.get("CLAUDE_SUBAGENT_NAME", "").strip()
        if env_v:
            raw = env_v
    if raw is None:
        return None
    return _normalise_namespaced(raw) or None


def is_known_agent_type(name: str | None) -> bool:
    """True when `name` (post-normalisation) is one of the four canonical agents."""
    return name in _KNOWN_AGENT_TYPES
