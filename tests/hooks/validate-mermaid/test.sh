#!/usr/bin/env bash
# validate-mermaid R11 regression — sequence-diagram parse-breakers.
#
# Locks the contract that R11 fires on the three character classes Mermaid's
# sequence parser mis-tokenises:
#   - `&lt;` / `&gt;` HTML entities (parse failure on the partial-arrow match)
#   - `&amp;` and similar named entities (parse failure on the next message)
#   - literal `;` in Note / message text (treated as statement separator)
#
# Also asserts the rule is sequenceDiagram-only — flowcharts using HTML
# entities or semicolons must NOT trip R11.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/_validate_mermaid_syntax.py"
TMPDIR="$(mktemp -d -t validate-mermaid-r11-XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

_run_validator() {
    # $1 = file content; returns: stderr+stdout via the global VALIDATOR_OUT,
    # exit code via VALIDATOR_RC.
    local content="$1"
    local fixture="$TMPDIR/fixture.md"
    printf '%s' "$content" > "$fixture"
    VALIDATOR_OUT=$(python3 "$VALIDATOR" "$fixture" 2>&1)
    VALIDATOR_RC=$?
}

# ─── R11 violations (sequenceDiagram) ─────────────────────────────────────

_run_validator '```mermaid
sequenceDiagram
    participant A
    Note over A: under ai/&lt;date&gt;-&lt;id&gt;/
```'
if [ "$VALIDATOR_RC" = "1" ] && echo "$VALIDATOR_OUT" | grep -q 'R11: HTML entity'; then
    _pass 'R11 fires on `&lt;`/`&gt;` in sequenceDiagram Note'
else
    _fail 'R11 fires on `&lt;`/`&gt;` in sequenceDiagram Note' "rc=$VALIDATOR_RC; out=$VALIDATOR_OUT"
fi

_run_validator '```mermaid
sequenceDiagram
    participant A
    participant B
    Note over A,B: Planning &amp; Approval
```'
if [ "$VALIDATOR_RC" = "1" ] && echo "$VALIDATOR_OUT" | grep -q 'R11: HTML entity'; then
    _pass 'R11 fires on `&amp;` in sequenceDiagram Note'
else
    _fail 'R11 fires on `&amp;` in sequenceDiagram Note' "rc=$VALIDATOR_RC; out=$VALIDATOR_OUT"
fi

_run_validator '```mermaid
sequenceDiagram
    participant A
    Note over A: hello; world
```'
if [ "$VALIDATOR_RC" = "1" ] && echo "$VALIDATOR_OUT" | grep -q 'R11: literal'; then
    _pass 'R11 fires on literal `;` in sequenceDiagram Note'
else
    _fail 'R11 fires on literal `;` in sequenceDiagram Note' "rc=$VALIDATOR_RC; out=$VALIDATOR_OUT"
fi

_run_validator '```mermaid
sequenceDiagram
    participant A
    participant B
    A->>B: payload &ge; threshold
```'
if [ "$VALIDATOR_RC" = "1" ] && echo "$VALIDATOR_OUT" | grep -q 'R11: HTML entity'; then
    _pass 'R11 fires on `&ge;` in sequenceDiagram message text'
else
    _fail 'R11 fires on `&ge;` in sequenceDiagram message text' "rc=$VALIDATOR_RC; out=$VALIDATOR_OUT"
fi

# ─── R11 negative cases (must NOT fire) ───────────────────────────────────

_run_validator '```mermaid
sequenceDiagram
    participant A
    participant B
    Note over A,B: under ai/{date}-{id}/ per CC-05.7
    A->>B: payload size 100 percent
```'
if [ "$VALIDATOR_RC" = "0" ]; then
    _pass 'R11 does NOT fire on `{placeholder}` syntax'
else
    _fail 'R11 does NOT fire on `{placeholder}` syntax' "rc=$VALIDATOR_RC; out=$VALIDATOR_OUT"
fi

_run_validator '```mermaid
flowchart LR
    A[under ai/&lt;date&gt;-&lt;id&gt;/]
    A --> B[hello; world]
```'
if [ "$VALIDATOR_RC" = "0" ]; then
    _pass 'R11 does NOT fire on HTML entities or `;` in a flowchart'
else
    _fail 'R11 does NOT fire on HTML entities or `;` in a flowchart' "rc=$VALIDATOR_RC; out=$VALIDATOR_OUT"
fi

_run_validator '```mermaid
sequenceDiagram
    %% comment with ; semicolon and &lt; entity — should be skipped
    participant A
    Note over A: clean text
```'
if [ "$VALIDATOR_RC" = "0" ]; then
    _pass 'R11 does NOT fire on `%%` comments containing `;` or entities'
else
    _fail 'R11 does NOT fire on `%%` comments containing `;` or entities' "rc=$VALIDATOR_RC; out=$VALIDATOR_OUT"
fi

# ─── Report ───────────────────────────────────────────────────────────────

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
