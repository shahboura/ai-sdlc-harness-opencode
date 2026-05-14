#!/usr/bin/env bash
# Doc-grep regression for WS-4 task 4 — the key_dependencies scope decision
# (option (b): supported manifests are pom.xml / package.json / go.mod /
# pyproject.toml; unsupported repos mark `# manifest unsupported`;
# plan-generator omits the [API:] annotation rather than guessing a version).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LD="$REPO_ROOT/skills/init-workspace/language-discovery.md"
SU="$REPO_ROOT/skills/init-workspace/schema-upgrade.md"
PG="$REPO_ROOT/skills/plan-generator/SKILL.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

assert_contains_in() {
    local needle="$1" file="$2" label="$3"
    if grep -qF -- "$needle" "$file"; then _pass "$label"; else _fail "$label" "expected to find in $(basename "$file"): $needle"; fi
}
assert_absent_in() {
    local needle="$1" file="$2" label="$3"
    if grep -qF -- "$needle" "$file"; then _fail "$label" "must NOT appear in $(basename "$file"): $needle"; else _pass "$label"; fi
}

# --- language-discovery.md ----------------------------------------------------

assert_contains_in 'Scope is deliberately narrow' "$LD" \
    'language-discovery declares the scope-down posture'

assert_contains_in '# manifest unsupported' "$LD" \
    'language-discovery uses the canonical `# manifest unsupported` comment'

assert_absent_in 'extraction not yet implemented' "$LD" \
    'language-discovery drops the "extraction not yet implemented" future-tense framing'

# Supported set still names the four manifests.
for fmt in 'pom.xml' 'package.json' 'go.mod' 'pyproject.toml'; do
    assert_contains_in "$fmt" "$LD" "language-discovery still names $fmt as supported"
done

# --- schema-upgrade.md -------------------------------------------------------

assert_contains_in '# manifest unsupported' "$SU" \
    'schema-upgrade uses the canonical comment too (legacy migration path)'

# --- plan-generator/SKILL.md -------------------------------------------------

# Step 1c distinguishes deliberate-empty from never-initialised.
assert_contains_in '# manifest unsupported' "$PG" \
    'plan-generator distinguishes the canonical `# manifest unsupported` case'
assert_contains_in 'do not retry by reading the manifest yourself' "$PG" \
    'plan-generator does NOT fall back to direct manifest read when scope-down was declared'

# Annotation rule: omit, never guess.
assert_contains_in 'omit the annotation entirely' "$PG" \
    'plan-generator omits the [API:] annotation when no concrete version is available'
assert_contains_in 'a guessed version is worse than no annotation' "$PG" \
    'plan-generator forbids placeholder versions (v?, v0, v(unknown))'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
