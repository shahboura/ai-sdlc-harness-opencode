#!/usr/bin/env bash
# Doc-grep regression for the story-intake WS-4 slice (task 3):
# parent + comments fetch, closed-state guard, canonical AC schema.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILE="$REPO_ROOT/skills/story-intake/SKILL.md"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

assert_contains() {
    if grep -qF -- "$1" "$FILE"; then _pass "$2"; else _fail "$2" "expected to find: $1"; fi
}
assert_regex() {
    if grep -qE -- "$1" "$FILE"; then _pass "$2"; else _fail "$2" "expected to match regex: $1"; fi
}

# --- Step 1b: parent + comments fetch --------------------------------------
assert_contains '### 1b. Fetch Related Context (Comments + Parent)' \
    'story-intake declares Step 1b'
assert_contains 'work_item.list_comments' \
    'Step 1b gates comment fetch on the capability declaration'
assert_contains 'last 20 comments' \
    'Step 1b caps comment fetch at 20'
assert_contains 'one level only' \
    'Step 1b caps parent fetch to one level'
# Per-provider tools listed.
assert_contains 'wit_list_work_item_comments' 'Step 1b names the ADO comments tool'
assert_contains 'get_issue_comments'          'Step 1b names the Jira comments tool'
assert_contains 'list_issue_notes'            'Step 1b names the GitLab comments tool'
assert_contains 'list_issue_comments'         'Step 1b names the GitHub comments tool'
# Bot filter mentioned (the value of bounding the input).
assert_contains 'Bot comments' \
    'Step 1b filters out bot comments before display'

# --- Step 1c: closed-state guard -------------------------------------------
assert_contains '### 1c. Closed-State Guard' 'story-intake declares Step 1c'
assert_contains 'closed/done/resolved' 'Step 1c lists the closed-state family'
assert_regex '\[1\] Continue anyway' \
    'Step 1c presents [1] Continue option'
assert_regex '\[2\] Stop' \
    'Step 1c presents [2] Stop option'

# --- Step 5: canonical AC schema -------------------------------------------
assert_contains '**canonical schema**' \
    'Step 5 calls out the canonical AC schema'
assert_contains 'Given / When / Then sub-fields are optional' \
    'Step 5 declares Given/When/Then sub-fields as optional'
assert_contains 'Do not synthesise Given/When/Then from' \
    'Step 5 forbids synthesising Given/When/Then'
assert_contains 'no AC-ID prefixes (`AC-1:`)' \
    'Step 5 forbids AC-1: prefixes (plan-generator parses the numbered shape)'

# Summary template gained the new fields.
assert_regex '\*\*Parent\*\*:' 'Requirements Summary template has Parent field'
assert_regex '\*\*State\*\*:'  'Requirements Summary template has State field (for closed-confirmed)'
assert_contains '### Comments Reviewed' \
    'Requirements Summary template has Comments Reviewed section'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
