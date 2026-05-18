#!/usr/bin/env bash
# E1 regression: `format_command` is a self-contained shell command — no
# placeholder substitution by any hook. The pre-E1 schema documented
# `{FILE}` / `{PROJECT_ROOT}` placeholders for an "auto-format hook" that
# was never implemented; agents that invoked the literal `poetry run ruff
# format {FILE}` would try to format a file named `{FILE}` and fail.
#
# Locks the rule across language-discovery.md (the schema), schema-upgrade.md
# (the legacy migration path), and hooks.json (no auto-format hook present).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

LANG_DISC="$REPO_ROOT/skills/init-workspace/language-discovery.md"
SCHEMA_UPG="$REPO_ROOT/skills/init-workspace/schema-upgrade.md"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"

# --- 1. language-discovery.md declares format_command as self-contained. ---
if grep -qF -- 'All commands are self-contained shell strings' "$LANG_DISC"; then
    _pass 'language-discovery declares all commands self-contained'
else
    _fail 'language-discovery declares all commands self-contained' \
        "expected 'All commands are self-contained shell strings' note"
fi

# The historical placeholder requirement must not appear as a live spec.
# Two checks: the imperative "must include" phrasing, and the schema row.
if grep -qF -- "\`format_command\` must include \`{FILE}\` and \`{PROJECT_ROOT}\`" "$LANG_DISC"; then
    _fail 'language-discovery drops the placeholder "must include" requirement' \
        'pre-E1 requirement still in language-discovery.md'
else
    _pass 'language-discovery drops the placeholder "must include" requirement'
fi
if grep -qF -- 'cmd with {FILE} and {PROJECT_ROOT} placeholders' "$LANG_DISC"; then
    _fail 'language-discovery schema row drops placeholders' \
        'pre-E1 schema row still references the placeholders as required'
else
    _pass 'language-discovery schema row drops placeholders'
fi

# The example block in Phase 3 (the negotiate prompt) must use a real command,
# not `{FILE}`.
if grep -qF -- 'poetry run ruff format {FILE}' "$LANG_DISC"; then
    _fail 'language-discovery Phase 3 example drops `{FILE}`' \
        'example output still shows the placeholder form'
else
    _pass 'language-discovery Phase 3 example drops `{FILE}`'
fi

# --- 2. schema-upgrade.md handles legacy `{FILE}` strip on migration. -----
if grep -qF -- '`format_command` placeholder strip' "$SCHEMA_UPG"; then
    _pass 'schema-upgrade documents the legacy placeholder strip rule'
else
    _fail 'schema-upgrade documents the legacy placeholder strip rule' \
        'expected `format_command` placeholder strip rule for --keep-legacy migrations'
fi

# --- 3. No auto-format hook is registered (still — the rationale).
# This isn't proof-positive (someone could register it under a different
# name), but it's the simplest tripwire: if a future change adds an
# auto-format hook, the schema needs to be reverted to include the
# placeholders again.
if grep -q '"command".*auto-format\|"command".*format-substitute' "$HOOKS_JSON"; then
    _fail 'no auto-format hook is registered' \
        'an auto-format hook appears in hooks.json — the E1 schema (no placeholders) is now incorrect; revisit the rationale'
else
    _pass 'no auto-format hook is registered (E1 rationale holds)'
fi

# --- 4. The developer/tester pre-commit step still references format_command
# verbatim (no per-agent substitution added either). If a future change
# pushes substitution into the agent prompts, the E1 fix needs to be
# revisited.
DEV="$REPO_ROOT/agents/developer/index.md"
TESTER="$REPO_ROOT/agents/tester/index.md"
for f in "$DEV" "$TESTER"; do
    name="$(basename "$f")"
    if grep -qF -- 'run the `format_command` from `.claude/context/language-config.md`' "$f"; then
        _pass "$name still invokes format_command verbatim (no per-agent substitution)"
    else
        _fail "$name still invokes format_command verbatim" \
            'pre-commit step changed — re-check whether the E1 schema is still consistent'
    fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
