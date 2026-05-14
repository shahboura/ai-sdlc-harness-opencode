#!/usr/bin/env bash
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

MARKER_SCRIPT="$(repo_root)/scripts/stop-failure-marker.sh"
RECOVERY_SCRIPT="$(repo_root)/scripts/stop-failure-recovery.sh"

# Helpers
marker_path() {
    printf '%s' "$FAKE_WORKSPACE/.claude/context/.stop-failure"
}

# ── marker hook writes the marker file from the workspace root ─────────────

test_marker_creates_file_when_in_workspace() {
    rm -f "$(marker_path)"
    (cd "$FAKE_WORKSPACE" && printf '%s' '{}' | "$MARKER_SCRIPT" >/dev/null 2>&1)
    if [ ! -f "$(marker_path)" ]; then
        _fail "marker file should exist after running marker script in workspace"
        return 1
    fi
    rm -f "$(marker_path)"
}

test_marker_walks_up_from_subdir() {
    # The OLD inline command used cwd-based gating. If cwd is a subdir of
    # the workspace, it would NOT have written the marker.
    rm -f "$(marker_path)"
    mkdir -p "$FAKE_WORKSPACE/some/deep/sub"
    (cd "$FAKE_WORKSPACE/some/deep/sub" && printf '%s' '{}' | "$MARKER_SCRIPT" >/dev/null 2>&1)
    if [ ! -f "$(marker_path)" ]; then
        _fail "marker should be written via walk-up even from a subdir"
        return 1
    fi
    rm -f "$(marker_path)"
}

test_marker_noop_outside_workspace() {
    # No workspace marker = no provider-config.md ancestor — silent pass.
    local outside
    outside="$(mktemp -d -t outside.XXXXXX)"
    (cd "$outside" && printf '%s' '{}' | "$MARKER_SCRIPT" >/dev/null 2>&1)
    local rc=$?
    rm -rf "$outside"
    if [ "$rc" != "0" ]; then
        _fail "marker script should exit 0 outside a workspace, got rc=$rc"
        return 1
    fi
}

# ── recovery hook emits text once when marker is present, then deletes ─────

test_recovery_emits_when_marker_present() {
    touch "$(marker_path)"
    local out
    out="$(cd "$FAKE_WORKSPACE" && printf '%s' '{}' | "$RECOVERY_SCRIPT" 2>/dev/null)"
    if ! printf '%s' "$out" | grep -qF 'API ERROR RECOVERY'; then
        _fail "expected recovery context block, got: $out"
        return 1
    fi
    if [ -f "$(marker_path)" ]; then
        _fail "marker should be deleted after recovery hook runs once"
        rm -f "$(marker_path)"
        return 1
    fi
}

test_recovery_silent_when_no_marker() {
    rm -f "$(marker_path)"
    local out
    out="$(cd "$FAKE_WORKSPACE" && printf '%s' '{}' | "$RECOVERY_SCRIPT" 2>/dev/null)"
    if [ -n "$out" ]; then
        _fail "expected no output without marker, got: $out"
        return 1
    fi
}

test_recovery_walks_up_for_marker() {
    # Marker exists in the workspace; we run from a deep subdir.
    # The OLD cwd-based gate would have missed it.
    touch "$(marker_path)"
    mkdir -p "$FAKE_WORKSPACE/some/deep/sub"
    local out
    out="$(cd "$FAKE_WORKSPACE/some/deep/sub" && printf '%s' '{}' | "$RECOVERY_SCRIPT" 2>/dev/null)"
    if ! printf '%s' "$out" | grep -qF 'API ERROR RECOVERY'; then
        _fail "expected recovery from deep subdir via walk-up, got: $out"
        return 1
    fi
    if [ -f "$(marker_path)" ]; then
        rm -f "$(marker_path)"
        _fail "marker should have been deleted"
        return 1
    fi
}

test_recovery_noop_outside_workspace() {
    local outside
    outside="$(mktemp -d -t outside.XXXXXX)"
    local out rc
    out="$(cd "$outside" && printf '%s' '{}' | "$RECOVERY_SCRIPT" 2>/dev/null)"
    rc=$?
    rm -rf "$outside"
    if [ "$rc" != "0" ] || [ -n "$out" ]; then
        _fail "recovery should silently pass outside workspace; rc=$rc out=$out"
        return 1
    fi
}

run_all_tests
