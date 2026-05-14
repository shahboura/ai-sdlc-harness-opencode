#!/usr/bin/env bash
# Capability lint — runs scripts/lint-capabilities.py and asserts it passes
# on the real tree. Also asserts two negative cases: a missing
# `## Capabilities` heading and a missing required-capability row both fail.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LINT="$REPO_ROOT/scripts/lint-capabilities.py"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# Build a tampered tree under $1; second arg is a python snippet that mutates
# files inside $1/skills. The lint script is copied alongside so REPO_ROOT
# resolves to $1.
make_tree() {
    local root="$1"
    mkdir -p "$root/scripts"
    cp -R "$REPO_ROOT/skills" "$root/skills"
    cp "$LINT" "$root/scripts/lint-capabilities.py"
}

# --- 1. Lint passes on the real tree ----------------------------------------
if out=$(python3 "$LINT" 2>&1); then
    _pass 'lint exits 0 on real tree'
else
    _fail 'lint exits 0 on real tree' "$out"
fi

# --- 2. Lint catches a missing `## Capabilities` heading -------------------
TMP1=$(mktemp -d)
trap 'rm -rf "$TMP1" "$TMP2"' EXIT
make_tree "$TMP1"
python3 - "$TMP1" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
p = root / "skills/providers/github/pull-requests.md"
text = p.read_text()
new = re.sub(r"## Capabilities.*?(?=\n## )", "", text, count=1, flags=re.DOTALL)
assert new != text, "expected to strip the Capabilities section"
p.write_text(new)
PY

if python3 "$TMP1/scripts/lint-capabilities.py" >/dev/null 2>&1; then
    _fail 'lint catches missing Capabilities section' \
        'lint exited 0 on a tree with the github pull-requests Capabilities section removed'
else
    _pass 'lint catches missing Capabilities section'
fi

# --- 3. Lint catches a missing required-capability row ----------------------
TMP2=$(mktemp -d)
make_tree "$TMP2"
python3 - "$TMP2" <<'PY'
import re, sys
from pathlib import Path
root = Path(sys.argv[1])
p = root / "skills/providers/github/pr-comments.md"
text = p.read_text()
# Match only the Capabilities-table row (status marker ✅ in the second column),
# not the descriptive row in the Operations table near the top of the file.
new = re.sub(r"^\|\s*`pr\.list_review_comments`\s*\|\s*✅.*\n", "", text, count=1, flags=re.MULTILINE)
assert new != text, "expected to strip the pr.list_review_comments Capabilities row"
p.write_text(new)
PY

if python3 "$TMP2/scripts/lint-capabilities.py" >/dev/null 2>&1; then
    _fail 'lint catches missing required capability row' \
        'lint exited 0 on a tree with the pr.list_review_comments row removed'
else
    _pass 'lint catches missing required capability row'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
