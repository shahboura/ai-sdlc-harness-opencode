#!/usr/bin/env bash
# workflow_fixture.sh — reusable fixture composer for dev-workflow integration tests.
#
# Tests source this library and the existing hooks/lib/assert.sh primitives,
# then call `run_workflow_tests` (instead of `run_all_tests`) at the end to
# get a workflow-aware fixture wired into setup/teardown.
#
# Goals:
#   - Per CC-06.5 every integration test is fully isolated — each test sees
#     its own freshly-built fixture (workspace + repo + tracker), and the
#     fixture is removed on EXIT regardless of pass / fail / SIGINT.
#   - Per CC-08.1 fixture composition is DRY — every test under
#     tests/integration/<phase>/ reads from this single library rather than
#     rebuilding workspace state inline.
#   - The fixture layout matches the canonical per-workflow paths
#     (CC-05.7): `ai/<YYYY-MM-DD>-<safe-id>/{plan.md,tracker.md}` and the
#     workspace-relative context dir `.claude/context/`.
#
# Created by: dev-workflow-plan.md [M-12] [IMPL-12-08-EXT]
# Reason: foundational shared driver — the per-phase tests under
# IMPL-12-01..-10 all share workspace setup, tracker composition, and
# metric-stamping primitives. Extracting them here keeps each per-phase
# test focused on the behaviour it actually asserts.
# CC conventions applied: CC-04.3, CC-06.1, CC-06.5, CC-08.1.
#
# Public API (functions prefixed `wf_`):
#
#   wf_setup [--story <id>] [--provider <name>] [--repo-branch <name>] [--no-repo]
#       Creates a fixture workspace at $WF_WORKSPACE (under mktemp), writes
#       canonical `.claude/context/` files (provider-config, repos-paths,
#       language-config, state), creates the per-workflow directory and
#       (unless --no-repo) initialises a real git repo at $WF_REPO_PATH.
#
#   wf_workspace        echoes the fixture workspace root.
#   wf_repo_path        echoes the fixture repo root (workspace/repo).
#   wf_workflow_dir     echoes the per-workflow directory.
#   wf_tracker_path     echoes the tracker.md path.
#   wf_plan_path        echoes the plan.md path.
#   wf_today            echoes the canonical date (UTC YYYY-MM-DD).
#   wf_story_id         echoes the story ID under fixture.
#
#   wf_write_tracker <task_count>
#       Writes a canonical tracker.md with <task_count> tasks (T1..Tn) in
#       Pending state under the standard Tasks table + Task Metrics + Workflow
#       Metrics sections per agents/shared/tracker-field-schema.md.
#
#   wf_write_plan
#       Writes a minimal canonical plan.md with the required sections
#       (Story metadata, Affected repos, Approach, Test Outline, Class
#       diagram, Flow chart, Sequence diagram, Risk/assumptions, Attribution).
#
#   wf_stamp_metric <metric_name> [timestamp]
#       Appends a `<metric_name>: <timestamp>` line under the Workflow
#       Metrics section of the tracker. Default timestamp is `wf_today`.
#       Idempotent — re-stamping replaces the existing line.
#
#   wf_assert_file_exists <path>
#       Pass if <path> exists; fail otherwise. <path> is workspace-relative
#       unless it starts with `/`.
#
#   wf_assert_metric <metric_name> [pattern]
#       Pass if the tracker contains `<metric_name>:` and the value matches
#       the optional regex <pattern>. Fail if the line is missing or the
#       pattern doesn't match.
#
#   wf_assert_tracker_field <field> <pattern>
#       Pass if the tracker's `<field>:` line value matches <pattern>.
#
#   wf_cleanup
#       Removes the fixture workspace. Called automatically by EXIT trap
#       installed by run_workflow_tests.
#
# Test-runner contract:
#   source the hook test lib first (for `_pass`/`_fail`/counters), then
#   source this lib, then define `test_*` functions, then call
#   `run_workflow_tests`.
set -uo pipefail

WF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF_REPO_ROOT="$(cd "$WF_LIB_DIR/../../.." && pwd)"

# State variables — populated by wf_setup, cleared by wf_cleanup.
WF_WORKSPACE=""
WF_REPO_PATH=""
WF_WORKFLOW_DIR=""
WF_TRACKER_PATH=""
WF_PLAN_PATH=""
WF_TODAY=""
WF_STORY_ID=""
WF_PROVIDER=""
WF_REPO_BRANCH=""

# ─── Setup ───────────────────────────────────────────────────────────────────

wf_setup() {
    local story_id="PROJ-1"
    local provider="local-markdown"
    local repo_branch="main"
    local create_repo=1

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --story) story_id="$2"; shift 2 ;;
            --provider) provider="$2"; shift 2 ;;
            --repo-branch) repo_branch="$2"; shift 2 ;;
            --no-repo) create_repo=0; shift ;;
            *) printf 'wf_setup: unknown option %s\n' "$1" >&2; return 1 ;;
        esac
    done

    WF_WORKSPACE="$(mktemp -d -t wf-fixture.XXXXXX)"
    WF_STORY_ID="$story_id"
    WF_PROVIDER="$provider"
    WF_REPO_BRANCH="$repo_branch"
    WF_TODAY="$(date -u +%Y-%m-%d)"
    WF_WORKFLOW_DIR="$WF_WORKSPACE/ai/${WF_TODAY}-${story_id}"
    WF_TRACKER_PATH="$WF_WORKFLOW_DIR/tracker.md"
    WF_PLAN_PATH="$WF_WORKFLOW_DIR/plan.md"

    mkdir -p "$WF_WORKSPACE/.claude/context" "$WF_WORKFLOW_DIR"
    _wf_write_provider_config
    _wf_write_repos_paths
    _wf_write_language_config
    _wf_write_state

    if [ "$create_repo" = 1 ]; then
        WF_REPO_PATH="$WF_WORKSPACE/repo"
        mkdir -p "$WF_REPO_PATH"
        (
            cd "$WF_REPO_PATH"
            git init -q -b "$repo_branch"
            git config user.email "wf-fixture@example.com"
            git config user.name "wf-fixture"
            printf 'seed\n' > seed.txt
            git add seed.txt
            git commit -q -m "seed"
        )
    fi
}

# ─── Accessors ───────────────────────────────────────────────────────────────

wf_workspace()    { printf '%s' "$WF_WORKSPACE"; }
wf_repo_path()    { printf '%s' "$WF_REPO_PATH"; }
wf_workflow_dir() { printf '%s' "$WF_WORKFLOW_DIR"; }
wf_tracker_path() { printf '%s' "$WF_TRACKER_PATH"; }
wf_plan_path()    { printf '%s' "$WF_PLAN_PATH"; }
wf_today()        { printf '%s' "$WF_TODAY"; }
wf_story_id()     { printf '%s' "$WF_STORY_ID"; }

# ─── Private writers (called by wf_setup) ────────────────────────────────────

_wf_write_provider_config() {
    cat > "$WF_WORKSPACE/.claude/context/provider-config.md" <<EOF
# Provider Configuration

work_item_provider: ${WF_PROVIDER}
git_provider: gh-cli
EOF
}

_wf_write_repos_paths() {
    cat > "$WF_WORKSPACE/.claude/context/repos-paths.md" <<EOF
# Repo Paths

| Repo | Path |
|---|---|
| repo | ${WF_WORKSPACE}/repo |
EOF
}

_wf_write_language_config() {
    cat > "$WF_WORKSPACE/.claude/context/language-config.md" <<'EOF'
# Language Configuration

## repo

language: python
toolchain: poetry
build_command: poetry build
test_command: poetry run pytest -q
format_command: poetry run ruff format .
restore_command: poetry install
coverage_threshold: 90
EOF
}

_wf_write_state() {
    cat > "$WF_WORKSPACE/.claude/context/state.md" <<EOF
# Workspace State

Bootstrap completed: ${WF_TODAY} 00:00 UTC
Workflow active: ai/${WF_TODAY}-${WF_STORY_ID}/
Last metric stamp: Bootstrap completed ${WF_TODAY} 00:00 UTC
EOF
}

# ─── Tracker + Plan composition ──────────────────────────────────────────────

wf_write_tracker() {
    local task_count="${1:-1}"
    local tasks_table=""
    local i
    for i in $(seq 1 "$task_count"); do
        tasks_table+="| T$i | example task $i | repo | ⬜ Pending | true | — | — | — | — |"$'\n'
    done

    cat > "$WF_TRACKER_PATH" <<EOF
# Tracker — ${WF_STORY_ID}

Story: ${WF_STORY_ID}
Story-State: Pending
Workflow-Dir: ai/${WF_TODAY}-${WF_STORY_ID}/

## Tasks

| Task | Description | Repo | Status | test-required | Started | Green At | Completed | Review Rounds |
|---|---|---|---|---|---|---|---|---|
${tasks_table}

## Task Metrics

## Workflow Metrics

EOF
}

wf_write_plan() {
    cat > "$WF_PLAN_PATH" <<EOF
# Plan — ${WF_STORY_ID}

## Story Metadata
- Story ID: ${WF_STORY_ID}
- Sprint: fixture

## Requirements Summary
A fixture story used by integration tests.

## Affected Repos
| Repo | Reason |
|---|---|
| repo | fixture |

## Approach
Sample plan content for fixture composition.

## Test Outline
### T1: example task 1
- test_seed_remains_present

## Class Diagram
\`\`\`mermaid
classDiagram
    class Example {
        +run() void
    }
\`\`\`

## Flow Chart
\`\`\`mermaid
flowchart TD
    A([Start]) --> B([End])
\`\`\`

## Sequence Diagram
\`\`\`mermaid
sequenceDiagram
    actor U as User
    U->>U: noop
\`\`\`

## Risk/Assumptions
None — fixture only.

🤖 Generated with [Claude Code](https://claude.ai/claude-code)
EOF
}

# ─── Metric stamping ─────────────────────────────────────────────────────────

wf_stamp_metric() {
    local metric="$1"
    local stamp="${2:-${WF_TODAY} 00:00 UTC}"

    if [ ! -f "$WF_TRACKER_PATH" ]; then
        printf 'wf_stamp_metric: tracker does not exist at %s — call wf_write_tracker first\n' "$WF_TRACKER_PATH" >&2
        return 1
    fi

    if grep -qE "^${metric}:" "$WF_TRACKER_PATH"; then
        # Replace in place. Use a temp file to avoid sed -i portability gotchas
        # between GNU and BSD sed.
        awk -v m="$metric" -v s="$stamp" \
            '$0 ~ "^" m ":" { print m ": " s; next } { print }' \
            "$WF_TRACKER_PATH" > "$WF_TRACKER_PATH.tmp"
        mv "$WF_TRACKER_PATH.tmp" "$WF_TRACKER_PATH"
    else
        # Append under the Workflow Metrics section. If section is missing,
        # append at end of file.
        if grep -q '^## Workflow Metrics' "$WF_TRACKER_PATH"; then
            awk -v line="${metric}: ${stamp}" \
                '/^## Workflow Metrics/ { print; print ""; print line; next } { print }' \
                "$WF_TRACKER_PATH" > "$WF_TRACKER_PATH.tmp"
            mv "$WF_TRACKER_PATH.tmp" "$WF_TRACKER_PATH"
        else
            printf '\n%s: %s\n' "$metric" "$stamp" >> "$WF_TRACKER_PATH"
        fi
    fi
}

# ─── Assertions (piggyback on assert.sh _pass/_fail) ────────────────────────

wf_assert_file_exists() {
    local rel="$1"
    local path
    if [ "${rel#/}" != "$rel" ]; then
        path="$rel"
    else
        path="$WF_WORKSPACE/$rel"
    fi
    if [ -e "$path" ]; then
        return 0
    fi
    _fail "expected file to exist: $rel (resolved: $path)"
    return 1
}

wf_assert_metric() {
    local metric="$1"
    local pattern="${2:-.+}"
    local line
    line="$(grep -E "^${metric}:" "$WF_TRACKER_PATH" || true)"
    if [ -z "$line" ]; then
        _fail "metric '$metric' not present in tracker"
        return 1
    fi
    local value="${line#${metric}:}"
    value="${value# }"
    if ! printf '%s' "$value" | grep -qE "$pattern"; then
        _fail "metric '$metric' value '$value' does not match pattern '$pattern'"
        return 1
    fi
    return 0
}

wf_assert_tracker_field() {
    local field="$1"
    local pattern="$2"
    local line
    line="$(grep -E "^${field}:" "$WF_TRACKER_PATH" || true)"
    if [ -z "$line" ]; then
        _fail "field '$field' not present in tracker"
        return 1
    fi
    local value="${line#${field}:}"
    value="${value# }"
    if ! printf '%s' "$value" | grep -qE "$pattern"; then
        _fail "field '$field' value '$value' does not match pattern '$pattern'"
        return 1
    fi
    return 0
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

wf_cleanup() {
    if [ -n "$WF_WORKSPACE" ] && [ -d "$WF_WORKSPACE" ]; then
        rm -rf "$WF_WORKSPACE"
    fi
    WF_WORKSPACE=""
    WF_REPO_PATH=""
    WF_WORKFLOW_DIR=""
    WF_TRACKER_PATH=""
    WF_PLAN_PATH=""
}

# ─── Test runner ─────────────────────────────────────────────────────────────

# Drop-in replacement for assert.sh's run_all_tests that wires per-test
# fixture setup + teardown into the discovery loop. Each test_* function
# starts with a fresh wf fixture.
run_workflow_tests() {
    local fns
    fns="$(declare -F | awk '$3 ~ /^test_/ {print $3}')"
    if [ -z "$fns" ]; then
        printf 'No tests found.\n' >&2
        return 1
    fi

    local fn before_fail
    for fn in $fns; do
        CURRENT_TEST="$fn"
        before_fail=$TEST_FAIL
        wf_setup
        "$fn"
        wf_cleanup
        if [ "$TEST_FAIL" = "$before_fail" ]; then
            _pass
        fi
    done

    printf '\n%d passed, %d failed\n' "$TEST_PASS" "$TEST_FAIL"
    if [ "$TEST_FAIL" -gt 0 ]; then
        printf '\nFailures:\n' >&2
        local f
        for f in "${TEST_FAILURES[@]}"; do
            printf '  - %s\n' "$f" >&2
        done
        return 1
    fi
    return 0
}
