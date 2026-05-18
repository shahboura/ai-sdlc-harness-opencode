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

# ── orphan plan-snapshot detection (handle-request.md Step 5 rollback path) ─

test_recovery_does_not_mention_snapshots_when_none_exist() {
    # Marker present, no snapshot dir — recovery emits the standard block
    # without any orphan-snapshot extension.
    touch "$(marker_path)"
    rm -rf "$FAKE_WORKSPACE/ai/.snapshots"
    local out
    out="$(cd "$FAKE_WORKSPACE" && printf '%s' '{}' | "$RECOVERY_SCRIPT" 2>/dev/null)"
    if printf '%s' "$out" | grep -qF 'orphan plan snapshot'; then
        _fail "expected no orphan-snapshot mention when .snapshots/ is empty, got: $out"
        rm -f "$(marker_path)"
        return 1
    fi
    rm -f "$(marker_path)"
}

test_recovery_surfaces_orphan_snapshot() {
    # Marker present + a snapshot file exists in ai/.snapshots/ — the recovery
    # block must list it and tell the orchestrator to surface a 3-option
    # disposition prompt to the human. Filename follows the canonical round-5
    # shape: <plan-basename>-<YYYY-MM-DD-HHMMSS>-<uid8>.md.
    touch "$(marker_path)"
    mkdir -p "$FAKE_WORKSPACE/ai/.snapshots"
    local snapshot="$FAKE_WORKSPACE/ai/.snapshots/2026-05-16_12345_feature-2026-05-16-103045-a1b2c3d4.md"
    : > "$snapshot"
    local out
    out="$(cd "$FAKE_WORKSPACE" && printf '%s' '{}' | "$RECOVERY_SCRIPT" 2>/dev/null)"
    rm -f "$(marker_path)" "$snapshot"
    rmdir "$FAKE_WORKSPACE/ai/.snapshots" 2>/dev/null
    rmdir "$FAKE_WORKSPACE/ai" 2>/dev/null
    if ! printf '%s' "$out" | grep -qF 'orphan plan snapshot'; then
        _fail "expected orphan-snapshot mention, got: $out"
        return 1
    fi
    if ! printf '%s' "$out" | grep -qF '2026-05-16_12345_feature-2026-05-16-103045-a1b2c3d4.md'; then
        _fail "expected the snapshot filename to appear in the recovery block, got: $out"
        return 1
    fi
    # The recovery block must offer three concrete options and forbid auto-action.
    if ! printf '%s' "$out" | grep -qF 'Do NOT auto-restore or auto-delete'; then
        _fail "expected the recovery block to forbid auto-action on snapshots, got: $out"
        return 1
    fi
}

test_recovery_lists_multiple_snapshots_newest_first() {
    touch "$(marker_path)"
    mkdir -p "$FAKE_WORKSPACE/ai/.snapshots"
    # Two snapshots — `find | sort -r` orders them by filename descending,
    # which for the canonical `<plan>-YYYY-MM-DD-HHMMSS-<uid8>.md` shape is
    # newest-first by timestamp. Uid8 is a secondary sort key (effectively
    # random) but only matters for identical-second snapshots.
    local older="$FAKE_WORKSPACE/ai/.snapshots/plan-A-2026-05-15-080000-aaaaaaaa.md"
    local newer="$FAKE_WORKSPACE/ai/.snapshots/plan-A-2026-05-16-120000-bbbbbbbb.md"
    : > "$older"
    : > "$newer"
    local out
    out="$(cd "$FAKE_WORKSPACE" && printf '%s' '{}' | "$RECOVERY_SCRIPT" 2>/dev/null)"
    rm -f "$(marker_path)" "$older" "$newer"
    rmdir "$FAKE_WORKSPACE/ai/.snapshots" 2>/dev/null
    rmdir "$FAKE_WORKSPACE/ai" 2>/dev/null
    # Both filenames present.
    if ! printf '%s' "$out" | grep -qF 'plan-A-2026-05-15-080000-aaaaaaaa.md'; then
        _fail "expected older snapshot to appear, got: $out"
        return 1
    fi
    if ! printf '%s' "$out" | grep -qF 'plan-A-2026-05-16-120000-bbbbbbbb.md'; then
        _fail "expected newer snapshot to appear, got: $out"
        return 1
    fi
    # Newer should appear BEFORE older in the output (find | sort -r).
    local newer_pos older_pos
    newer_pos=$(printf '%s' "$out" | grep -n '2026-05-16-120000' | head -1 | cut -d: -f1)
    older_pos=$(printf '%s' "$out" | grep -n '2026-05-15-080000' | head -1 | cut -d: -f1)
    if [ -z "$newer_pos" ] || [ -z "$older_pos" ] || [ "$newer_pos" -ge "$older_pos" ]; then
        _fail "expected newer snapshot listed before older; newer_pos=$newer_pos older_pos=$older_pos"
        return 1
    fi
}

test_recovery_lists_same_second_snapshots_distinctly() {
    # Two snapshots taken in the same UTC second but with different uid8s —
    # the new collision-prevention rule should mean both files exist and both
    # appear in the recovery block.
    touch "$(marker_path)"
    mkdir -p "$FAKE_WORKSPACE/ai/.snapshots"
    local a="$FAKE_WORKSPACE/ai/.snapshots/plan-X-2026-05-16-120000-aaaaaaaa.md"
    local b="$FAKE_WORKSPACE/ai/.snapshots/plan-X-2026-05-16-120000-bbbbbbbb.md"
    : > "$a"
    : > "$b"
    local out
    out="$(cd "$FAKE_WORKSPACE" && printf '%s' '{}' | "$RECOVERY_SCRIPT" 2>/dev/null)"
    rm -f "$(marker_path)" "$a" "$b"
    rmdir "$FAKE_WORKSPACE/ai/.snapshots" 2>/dev/null
    rmdir "$FAKE_WORKSPACE/ai" 2>/dev/null
    if ! printf '%s' "$out" | grep -qF 'aaaaaaaa.md'; then
        _fail "expected same-second snapshot A to appear, got: $out"
        return 1
    fi
    if ! printf '%s' "$out" | grep -qF 'bbbbbbbb.md'; then
        _fail "expected same-second snapshot B to appear, got: $out"
        return 1
    fi
}

run_all_tests
