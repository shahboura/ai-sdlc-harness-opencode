#!/usr/bin/env python3
"""q_phase_guard — Quick-mode entry and invariant guard (IMPL-25-01).

Enforces CC-05.8 invariants I-1..I-3 and FR-1.4 hard-threshold aborts at
quick-mode entry. Consumed by commands/quick.md orchestrator (US-E01-004).

Invariants (CC-05.8):
    I-1  No Planner or Tester — quick mode runs Developer + Reviewer only.
    I-2  No mid-flow upgrade to full mode — abort and restart are the only paths.
    I-3  Security-sensitive paths abort regardless of LOC count.

FR-1.4 hard thresholds (sourced from quick-mode-config.md via classify_change):
    loc_delta  > loc_max      (default 80, CC-09 tunable)
    files_touched > files_max (default 5,  CC-09 tunable)
    public_api_touched        (bool — always aborts)
    migration_touched         (bool — always aborts)
    security_paths_touched    (bool — always aborts; also enforces I-3)

CLI usage:
    python3 q_phase_guard.py --diff <path|->  [--config <path>]
    python3 q_phase_guard.py --refuse-agent <agent_type>
    python3 q_phase_guard.py --refuse-upgrade

Exit codes:
    0   check passed — entry allowed / agent permitted
    1   internal error (IO failure, import error)
    2   entry denied — FR-1.4 threshold exceeded or invariant violated

Output (stdout JSON):
    {"allowed": bool, "reason": "<explanation>" | null}

Created by: dev-workflow-plan.md [M-25] [IMPL-25-01]
CC conventions applied: CC-05.8 (fast-path invariants), ADR-001 (code not prompts),
    ADR-011 (shared classify_change source of truth).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from typing import List, Optional, Tuple

# ---------------------------------------------------------------------------
# Import quick-mode-classify (hyphenated filename requires importlib)
# ---------------------------------------------------------------------------

def _load_classify_module():  # type: ignore[return]
    """Load quick-mode-classify.py via importlib (hyphen in filename)."""
    scripts_dir = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location(
        "quick_mode_classify",
        scripts_dir / "quick-mode-classify.py",
    )
    if spec is None or spec.loader is None:
        raise ImportError("Cannot locate quick-mode-classify.py")
    mod = importlib.util.module_from_spec(spec)
    # Register before exec_module so @dataclass can resolve cls.__module__
    sys.modules["quick_mode_classify"] = mod
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


_qmc = None  # lazy-loaded on first use


def _qmc_module():
    global _qmc
    if _qmc is None:
        _qmc = _load_classify_module()
    return _qmc


# ---------------------------------------------------------------------------
# Agent blocklist (CC-05.8 I-1)
# ---------------------------------------------------------------------------

BLOCKED_AGENTS: frozenset = frozenset({
    "ai-sdlc-planner",
    "ai-sdlc-tester",
})

# ---------------------------------------------------------------------------
# Exception
# ---------------------------------------------------------------------------


class QPhaseGuardError(Exception):
    """Raised when a QPhaseGuard invariant or threshold check fails.

    Attributes:
        invariant: Which invariant was violated, e.g. "I-1", "FR-1.4".
        reason:    Human-readable explanation of why entry was denied.
    """

    def __init__(self, reason: str, invariant: str = "FR-1.4") -> None:
        super().__init__(reason)
        self.reason = reason
        self.invariant = invariant


# ---------------------------------------------------------------------------
# Guard class
# ---------------------------------------------------------------------------


class QPhaseGuard:
    """Enforces CC-05.8 quick-mode invariants and FR-1.4 hard thresholds.

    All methods are side-effect-free regarding the tracker: they raise
    QPhaseGuardError on denial; the orchestrator decides what to write.
    This satisfies ADR-001 (logic in code, not agent prompts) and the AC
    requirement "writes nothing to the tracker" on abort.

    Example (orchestrator usage in commands/quick.md):
        guard = QPhaseGuard()
        try:
            guard.check_entry(diff_text)
        except QPhaseGuardError as e:
            emit_abort_message(e.reason)
            return
        # proceed with quick-mode workflow ...
        guard.refuse_agent(agent_type)   # call before each Agent invocation
    """

    def check_entry(
        self,
        diff_text: str,
        config_path: Optional[Path] = None,
    ) -> None:
        """Validate a diff against FR-1.4 hard thresholds.

        Raises QPhaseGuardError if the diff triggers any hard abort condition.
        On success, returns None — entry is allowed.

        I-3 enforcement: security-sensitive paths abort regardless of LOC count.
        """
        mod = _qmc_module()
        tier, stats = mod.classify_change(diff_text, config_path)

        if tier != mod.RiskTier.high:
            return  # allowed

        # Build a specific abort reason from stats
        reasons: List[str] = []
        if stats.security_paths_touched:
            reasons.append(
                "security-sensitive path touched (invariant I-3: always aborts)"
            )
        if stats.public_api_touched:
            reasons.append("public-API file touched")
        if stats.migration_touched:
            reasons.append("migration file touched")
        if stats.loc_delta > 80:  # CC-09-OK: 80 is the FR-1.4 LOC threshold (quick-mode-config.md)
            reasons.append(
                f"LOC delta {stats.loc_delta} exceeds the quick-mode limit "
                "(check quick-mode-config.md loc_max)"
            )
        if stats.files_touched > 5:  # CC-09-OK: 5 is the FR-1.4 files threshold (quick-mode-config.md)
            reasons.append(
                f"files touched {stats.files_touched} exceeds the quick-mode limit "
                "(check quick-mode-config.md files_max)"
            )

        reason_str = "; ".join(reasons) if reasons else "change exceeds quick-mode thresholds"
        raise QPhaseGuardError(
            f"Quick-mode aborted: {reason_str}. "
            "Restart in full mode: /dev-workflow plan <work-item-id>",
            invariant="FR-1.4",
        )

    def refuse_agent(self, agent_type: str) -> None:
        """Enforce I-1: Planner and Tester must not be invoked in quick mode.

        Raises QPhaseGuardError if agent_type is in BLOCKED_AGENTS.
        Called by the orchestrator before every Agent tool invocation.
        """
        if agent_type in BLOCKED_AGENTS:
            raise QPhaseGuardError(
                f"Quick-mode invariant I-1 violated: '{agent_type}' must not be "
                "invoked in quick mode. Quick mode runs Developer + Reviewer only. "
                "To use the full pipeline, abort and restart with "
                "/dev-workflow plan <work-item-id>.",
                invariant="I-1",
            )

    def refuse_upgrade(self) -> None:
        """Enforce I-2: mid-flow upgrade to full mode is not supported.

        Always raises QPhaseGuardError. The only valid path when a quick-mode
        workflow turns out to need full-mode is to abort and restart.
        """
        raise QPhaseGuardError(
            "Quick-mode invariant I-2 violated: mid-flow upgrade to full mode is "
            "not supported. Abort this session and restart with: "
            "/dev-workflow plan <work-item-id>.",
            invariant="I-2",
        )


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="Quick-mode entry guard — enforces CC-05.8 invariants and FR-1.4 thresholds",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    mode_group = p.add_mutually_exclusive_group(required=True)
    mode_group.add_argument(
        "--diff",
        metavar="PATH",
        help="Path to a git diff file, or - to read from stdin. Checks FR-1.4 entry thresholds.",
    )
    mode_group.add_argument(
        "--refuse-agent",
        metavar="AGENT_TYPE",
        help="Check whether AGENT_TYPE is blocked by I-1. Exits 2 if blocked.",
    )
    mode_group.add_argument(
        "--refuse-upgrade",
        action="store_true",
        help="Assert I-2: always exits 2 (mid-flow upgrade is never permitted).",
    )
    p.add_argument(
        "--config",
        metavar="PATH",
        default=None,
        help="Path to quick-mode-config.md (default: .claude/context/quick-mode-config.md).",
    )
    return p


def main(argv: Optional[List[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv if argv is not None else sys.argv[1:])

    guard = QPhaseGuard()

    try:
        # --refuse-upgrade: I-2 enforcement (always denied)
        if args.refuse_upgrade:
            try:
                guard.refuse_upgrade()
            except QPhaseGuardError as e:
                print(json.dumps({"allowed": False, "reason": e.reason, "invariant": e.invariant}))
                return 2

        # --refuse-agent: I-1 enforcement
        elif args.refuse_agent is not None:
            try:
                guard.refuse_agent(args.refuse_agent)
                print(json.dumps({"allowed": True, "reason": None}))
                return 0
            except QPhaseGuardError as e:
                print(json.dumps({"allowed": False, "reason": e.reason, "invariant": e.invariant}))
                return 2

        # --diff: FR-1.4 entry threshold check
        else:
            config_path = Path(args.config) if args.config else None

            if args.diff == "-":
                diff_text = sys.stdin.read()
            else:
                diff_path = Path(args.diff)
                if not diff_path.is_file():
                    print(f"error: diff file not found: {diff_path}", file=sys.stderr)
                    return 1
                diff_text = diff_path.read_text(encoding="utf-8")

            try:
                guard.check_entry(diff_text, config_path)
                print(json.dumps({"allowed": True, "reason": None}))
                return 0
            except QPhaseGuardError as e:
                print(json.dumps({"allowed": False, "reason": e.reason, "invariant": e.invariant}))
                return 2

    except Exception as exc:  # pylint: disable=broad-except
        print(f"error: {exc}", file=sys.stderr)
        return 1

    return 0  # unreachable but satisfies type checkers


if __name__ == "__main__":
    sys.exit(main())
