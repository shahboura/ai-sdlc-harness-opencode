#!/usr/bin/env python3
"""cc-check — convention-check aggregator.

Discovers every script under `tests/convention-check/` matching the canonical
naming pattern (`CC*.convention-check.test.sh`), runs each one in turn,
collects exit codes, and produces a concise summary.

Exit-code semantics:
    0   every Convention-Check passed (or only advisory-layer hits, per
        each check's own fail-open contract)
    1   one or more Convention-Checks failed-closed (STRICT-layer
        violations)
    2   no Convention-Check scripts found (likely misconfigured workspace)

Per the plan's IMPL-13-01 / IMPL-13-03, this aggregator is invoked as the
final step of `tests/run.sh` so a CI run that passes the unit + skill +
hook + integration tiers but introduces convention drift still fails the
build at this gate.

Created by: dev-workflow-plan.md [M-13] [IMPL-13-01]
CC conventions applied: CC-04.3, CC-06.2, CC-07.5.
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path
from typing import List, NamedTuple

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECK_DIR = REPO_ROOT / "tests" / "convention-check"
SCRIPT_GLOB = "*.convention-check.test.sh"


class CheckResult(NamedTuple):
    name: str
    path: Path
    exit_code: int
    duration_ms: int
    stdout: str
    stderr: str


def discover_checks() -> List[Path]:
    if not CHECK_DIR.is_dir():
        return []
    return sorted(CHECK_DIR.glob(SCRIPT_GLOB))


def run_check(path: Path) -> CheckResult:
    start = time.monotonic()
    try:
        proc = subprocess.run(
            ["bash", str(path)],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
        rc = proc.returncode
        out = proc.stdout
        err = proc.stderr
    except subprocess.TimeoutExpired:
        rc = 124
        out = ""
        err = f"cc-check: {path.name} exceeded 120s timeout"
    except OSError as e:
        rc = 1
        out = ""
        err = f"cc-check: {path.name} raised OSError: {e}"
    elapsed_ms = int((time.monotonic() - start) * 1000)
    return CheckResult(
        name=path.name,
        path=path,
        exit_code=rc,
        duration_ms=elapsed_ms,
        stdout=out,
        stderr=err,
    )


def _print_summary(results: List[CheckResult], failures: List[CheckResult]) -> None:
    print()
    print(f"cc-check: {len(results)} convention-check(s) ran")
    for r in results:
        symbol = "✓" if r.exit_code == 0 else "✗"
        print(f"  {symbol} {r.name:<60} ({r.duration_ms:>4} ms, exit {r.exit_code})")
    print()
    if failures:
        print(f"cc-check: {len(failures)} failure(s) — STRICT-layer convention drift", file=sys.stderr)
        for f in failures:
            print(f"\n--- {f.name} (exit {f.exit_code}) ---", file=sys.stderr)
            tail = (f.stderr or f.stdout).strip().splitlines()[-20:]
            for line in tail:
                print(f"  {line}", file=sys.stderr)
    else:
        print("cc-check: PASS — no STRICT-layer convention drift detected")


def main(argv: List[str] | None = None) -> int:
    argv = argv if argv is not None else sys.argv[1:]
    verbose = "-v" in argv or "--verbose" in argv

    checks = discover_checks()
    if not checks:
        print(
            f"cc-check: no scripts found under {CHECK_DIR.relative_to(REPO_ROOT)}/ — "
            f"is the workspace initialised?",
            file=sys.stderr,
        )
        return 2

    print(f"cc-check: running {len(checks)} convention-check(s)")
    results: List[CheckResult] = []
    for path in checks:
        print(f"  - {path.name} ...", end="", flush=True)
        r = run_check(path)
        results.append(r)
        if r.exit_code == 0:
            print(f" ok ({r.duration_ms} ms)")
        else:
            print(f" FAIL (exit {r.exit_code}, {r.duration_ms} ms)")
            if verbose:
                if r.stderr:
                    print(f"    stderr:")
                    for line in r.stderr.strip().splitlines()[-10:]:
                        print(f"      {line}")
                if r.stdout:
                    print(f"    stdout:")
                    for line in r.stdout.strip().splitlines()[-10:]:
                        print(f"      {line}")

    failures = [r for r in results if r.exit_code != 0]
    _print_summary(results, failures)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
