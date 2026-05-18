#!/usr/bin/env bash
# E2 regression: the four story-workflow command files (improve / refine /
# analyze / groom) each have a "post as a comment" final step. Pre-E2 they
# unconditionally said "use the **add comment** tool from the active provider
# adapter" — which broke for `local-markdown` (the adapter has no
# work_item.add_comment capability; refinements are saved by overwriting
# the source .md file via the Write tool). Post-E2 each command branches
# explicitly on local-markdown vs other providers.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0
fail=0
fail_msgs=()

_pass() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
_fail() { fail=$((fail + 1)); fail_msgs+=("$1: $2"); printf '  FAIL  %s\n' "$1" >&2; printf '        %s\n' "$2" >&2; }

# Each command file must contain a `local-markdown` branch in its post-back step.
for cmd in improve refine analyze groom; do
    f="$REPO_ROOT/skills/story-workflow/commands/$cmd.md"
    if grep -qF -- '`local-markdown`' "$f"; then
        _pass "$cmd.md branches explicitly on local-markdown"
    else
        _fail "$cmd.md branches explicitly on local-markdown" \
            "no `local-markdown` mention in $f — the local-markdown adapter has no add_comment tool"
    fi
done

# `improve` and `refine` route local-markdown to the adapter's "Save Refined
# Story" Write-tool path (overwriting the source file is the expected action).
for cmd in improve refine; do
    f="$REPO_ROOT/skills/story-workflow/commands/$cmd.md"
    if grep -qF -- 'Post Back / Save Refined Story' "$f"; then
        _pass "$cmd.md cross-references local-markdown adapter's Save Refined Story section"
    else
        _fail "$cmd.md cross-references local-markdown adapter's Save Refined Story section" \
            'expected reference to `Post Back / Save Refined Story` in local-markdown/work-items.md'
    fi
done

# `analyze` MUST NOT overwrite the source story — analyze produces a readiness
# report which is a separate artifact. The doc must explicitly forbid the
# overwrite for local-markdown to avoid an LLM "helpfully" doing it.
if grep -qF -- "Do NOT overwrite the source story file with the readiness report" "$REPO_ROOT/skills/story-workflow/commands/analyze.md"; then
    _pass 'analyze.md forbids overwriting the source story file for local-markdown'
else
    _fail 'analyze.md forbids overwriting the source story file for local-markdown' \
        "expected explicit 'Do NOT overwrite' rule in analyze.md"
fi

# `groom` offers two persistence paths for local-markdown (sibling file or
# Edit-append into existing ## Technical Notes section).
if grep -qF -- '`<story-basename>-technical-notes.md`' "$REPO_ROOT/skills/story-workflow/commands/groom.md"; then
    _pass 'groom.md offers the sibling-file path for local-markdown'
else
    _fail 'groom.md offers the sibling-file path for local-markdown' \
        'expected `<story-basename>-technical-notes.md` recommendation'
fi
if grep -qF -- 'if and only if the source file already has a `## Technical Notes` heading' "$REPO_ROOT/skills/story-workflow/commands/groom.md"; then
    _pass 'groom.md gates the in-place append on the existing ## Technical Notes heading'
else
    _fail 'groom.md gates the in-place append on the existing ## Technical Notes heading' \
        'expected "if and only if the source file already has" qualifier on the in-place append path'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
    printf '\nFailures:\n' >&2
    for m in "${fail_msgs[@]}"; do printf '  - %s\n' "$m" >&2; done
    exit 1
fi
exit 0
