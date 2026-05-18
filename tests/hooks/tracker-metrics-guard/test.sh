#!/usr/bin/env bash
# Hook: tracker-metrics-guard
# Event: PreToolUse on Edit
# Policy: fail-OPEN (advisory only — always exits 0)
# Enforces: warns when an Edit on a tracker file writes a date-shaped token
#           that is not the canonical `YYYY-MM-DD HH:MM UTC` format.
#
# These tests pin the advisory's trigger surface:
#   1. The hook is a no-op when tool_name isn't `Edit`.
#   2. The hook is a no-op when file_path isn't a tracker (legacy `ai/tasks/`
#      or canonical `ai/<YYYY-MM-DD>-<id>/tracker.md`).
#   3. The hook is silent when the timestamp is well-formed.
#   4. The hook emits an `ADVISORY:` line to stdout when the timestamp is
#      missing the time, `UTC` suffix, or uses an ISO `T` separator.
# In every case the hook exits 0 (fail-OPEN).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd ../lib && pwd)/assert.sh"

HOOK="$(repo_root)/scripts/tracker-metrics-guard.sh"

# Capture stdout in addition to the standard exit-code check.
# Returns "<exit_code>\t<stdout>" so tests can assert on the advisory text.
_run_with_stdout() {
    local script="$1"
    local payload="$2"
    local stdout_file stderr_file exit_code
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    exit_code=0
    (
        cd "$FAKE_WORKSPACE"
        printf '%s' "$payload" | "$script" >"$stdout_file" 2>"$stderr_file"
    ) || exit_code=$?
    local out
    out="$(cat "$stdout_file")"
    rm -f "$stdout_file" "$stderr_file"
    printf '%d\t%s' "$exit_code" "$out"
}

# ── no-op paths (wrong tool, wrong path, no input) ─────────────────────────

test_noop_when_tool_is_not_edit() {
    local payload
    payload="$(mk_bash_payload 'echo hi')"
    assert_hook_allows "$HOOK" "$payload"
}

test_noop_when_path_is_not_a_tracker() {
    local payload
    payload="$(mk_edit_payload 'README.md' 'old' '2026-04-05 14:30 UTC')"
    local result rc out
    result="$(_run_with_stdout "$HOOK" "$payload")"
    rc="${result%%$'\t'*}"
    out="${result#*$'\t'}"
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 (advisory), got $rc"
        return 1
    fi
    if printf '%s' "$out" | grep -qF 'ADVISORY:'; then
        _fail "no advisory expected for non-tracker path; got: $out"
        return 1
    fi
}

test_noop_when_new_string_empty() {
    local path
    path="$(write_fixture 'ai/2026-05-18-S123/tracker.md' '# tracker')"
    local payload
    payload="$(mk_edit_payload "$path" 'old' '')"
    assert_hook_allows "$HOOK" "$payload"
}

# ── valid timestamps must not warn ────────────────────────────────────────

test_silent_on_full_utc_timestamp() {
    local path
    path="$(write_fixture 'ai/2026-05-18-S123/tracker.md' '# tracker')"
    local payload
    payload="$(mk_edit_payload "$path" '--' 'Plan approved 2026-04-05 14:30 UTC')"
    local result rc out
    result="$(_run_with_stdout "$HOOK" "$payload")"
    rc="${result%%$'\t'*}"
    out="${result#*$'\t'}"
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0, got $rc"
        return 1
    fi
    if printf '%s' "$out" | grep -qF 'ADVISORY:'; then
        _fail "expected no advisory for canonical timestamp; got: $out"
        return 1
    fi
}

test_silent_on_legacy_tasks_tracker_path() {
    # The legacy `ai/tasks/*.md` layout is still recognised as a tracker by
    # _TRACKER_PATH_RE (read-side compat during the M-14 migration window).
    local path
    path="$(write_fixture 'ai/tasks/2026-05-tracker.md' '# tracker')"
    local payload
    payload="$(mk_edit_payload "$path" '--' 'PR created 2026-04-05 14:30 UTC')"
    local result rc out
    result="$(_run_with_stdout "$HOOK" "$payload")"
    rc="${result%%$'\t'*}"
    out="${result#*$'\t'}"
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0, got $rc"
        return 1
    fi
    if printf '%s' "$out" | grep -qF 'ADVISORY:'; then
        _fail "expected no advisory for canonical timestamp on legacy path; got: $out"
        return 1
    fi
}

# ── invalid timestamps must trigger the advisory (still exit 0) ───────────

test_advise_on_date_only() {
    local path
    path="$(write_fixture 'ai/2026-05-18-S123/tracker.md' '# tracker')"
    local payload
    payload="$(mk_edit_payload "$path" '--' 'Plan approved 2026-04-05')"
    local result rc out
    result="$(_run_with_stdout "$HOOK" "$payload")"
    rc="${result%%$'\t'*}"
    out="${result#*$'\t'}"
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0 (advisory), got $rc"
        return 1
    fi
    if ! printf '%s' "$out" | grep -qF 'ADVISORY:'; then
        _fail "expected ADVISORY: warning, got: $out"
        return 1
    fi
    if ! printf '%s' "$out" | grep -qF 'YYYY-MM-DD HH:MM UTC'; then
        _fail "expected required-format hint, got: $out"
        return 1
    fi
}

test_advise_on_missing_utc_suffix() {
    local path
    path="$(write_fixture 'ai/2026-05-18-S123/tracker.md' '# tracker')"
    local payload
    payload="$(mk_edit_payload "$path" '--' 'Plan approved 2026-04-05 14:30')"
    local result rc out
    result="$(_run_with_stdout "$HOOK" "$payload")"
    rc="${result%%$'\t'*}"
    out="${result#*$'\t'}"
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0, got $rc"
        return 1
    fi
    if ! printf '%s' "$out" | grep -qF 'ADVISORY:'; then
        _fail "expected advisory for missing-UTC; got: $out"
        return 1
    fi
}

test_advise_on_iso_t_separator() {
    local path
    path="$(write_fixture 'ai/2026-05-18-S123/tracker.md' '# tracker')"
    local payload
    payload="$(mk_edit_payload "$path" '--' 'Plan approved 2026-04-05T14:30 UTC')"
    local result rc out
    result="$(_run_with_stdout "$HOOK" "$payload")"
    rc="${result%%$'\t'*}"
    out="${result#*$'\t'}"
    if [ "$rc" != "0" ]; then
        _fail "expected exit 0, got $rc"
        return 1
    fi
    if ! printf '%s' "$out" | grep -qF 'ADVISORY:'; then
        _fail "expected advisory for ISO-T separator; got: $out"
        return 1
    fi
}

run_all_tests
