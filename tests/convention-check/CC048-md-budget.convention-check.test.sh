#!/usr/bin/env bash
# CC048-md-budget.convention-check.test.sh — TEST-191..194 (CC-04.8)
#
# Runs scripts/cc-check-md-budget.py against the live harness tree.
# v2.1 mode: WARN-only, always exits 0 (ADR-006 time-bounded exception).
# v2.1.1: flip _DEFAULT_HARD_CAP_MODE to "block" in the script (US-E03-009).
#
# Unit tests for classification, soft/hard breach, and exemption handling
# live in tests/hooks/cc-check-md-budget/test.sh (TEST-191..194).
#
# Created by: dev-workflow-plan.md [M-26] [IMPL-26-01]
# CC conventions applied: CC-04.8, ADR-006.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 "$REPO_ROOT/scripts/cc-check-md-budget.py" "$REPO_ROOT"
