#!/usr/bin/env bash
# CC07-04-4-5-failure-mode-parity.convention-check.test.sh — TEST-187
#
# Per CC-07.4.4.5, every per-phase Mermaid diagram in
# `dev-workflow-phases.md` must contain a `:::error` node for every row
# in the corresponding `Failure Modes` table in
# `dev-workflow-phase-specs.md`, EXCEPT rows whose `Response` column
# routes to R (ABANDON / STALL / generic "R takes over" wording) —
# those live in the high-level overview per CC-07.4.4 rule 1.
#
# Matching uses the canonicalised slug rules from CC-07.4.4.5:
#   - Spec-row slug: lowercase Failure-cell text, strip backticks +
#     parenthetical `(e.g. …)` examples, collapse whitespace.
#   - Diagram-node slug: strip leading `FAIL:` / `ADVISORY:` / `WARNING:`
#     prefix, replace `<br/>` with space, truncate at first `;` (response
#     text after `;` is description, not the cause), lowercase, collapse.
#   - Match rule: whole-word contiguous sub-sequence match (the smaller
#     token-list must be a contiguous sub-sequence of the larger one;
#     character substring is NOT enough — eliminates the
#     `lock` ⊂ `block` class of false positives).
#
# Authority docs live in `../harness-mgm/` (one level up from the harness
# root). When that directory isn't reachable (end-user clone of the
# harness plugin without the parent design corpus), the script exits 0
# with a `skipped` message — the parity check is only meaningful during
# harness development.
#
# Created by: dev-workflow-plan.md [M-24] [IMPL-24-02 + TEST-187 closure]
# Maps to: TEST-187 (CC-07.4.4.5 Failure-Mode parity scan).
# CC conventions applied: CC-07.4.4.5, CC-06.2, CC-08.4.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

python3 - "$REPO_ROOT" <<'PY'
import os
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
authority_dir = repo.parent / "harness-mgm"
phases_md = authority_dir / "dev-workflow-phases.md"
specs_md = authority_dir / "dev-workflow-phase-specs.md"

if not authority_dir.is_dir() or not phases_md.is_file() or not specs_md.is_file():
    print(
        "CC-07.4.4.5 failure-mode parity: SKIPPED — authority docs not "
        f"reachable at {authority_dir} (end-user clone or detached harness)"
    )
    sys.exit(0)

phases_text = phases_md.read_text(encoding="utf-8")
specs_text = specs_md.read_text(encoding="utf-8")

# Scope: the 5 per-phase diagrams that CC-07.4.4.5 requires parity for.
# IG is INCLUDED but its "request stuck > 1h" row is excluded per the
# routing-to-R clause (see the `%% Note (CC-07.4.4.5):` comment in the
# IG diagram).
SCOPED_PHASES = ("P5.5", "P7", "P8", "P9", "IG", "R")

# Phrases in the spec's Response column that route to R / overview.
ROUTING_TO_R = (
    "→ Recovery",
    "→ R",
    "R takes over",
    "Route to R",
    "Recovery abandoned",
    "tracker.aborted.md",
    "stop-failure marker",
)


def _slugify_spec_failure(cell: str) -> str:
    """Canonicalise a spec-table Failure cell per CC-07.4.4.5."""
    s = cell.lower().strip()
    s = re.sub(r"`", "", s)
    # Strip parenthetical `(e.g. ...)` examples (the rule explicitly names
    # this form; generic parentheticals are NOT in scope per the spec).
    s = re.sub(r"\(e\.g\.[^)]*\)", "", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s


def _slugify_diagram_label(label: str) -> str:
    """Canonicalise an `:::error` node label per CC-07.4.4.5."""
    s = label
    # Replace <br/> with single space.
    s = re.sub(r"<br\s*/?>", " ", s, flags=re.IGNORECASE)
    # Strip leading FAIL: / ADVISORY: / WARNING:
    s = re.sub(r"^\s*(fail|advisory|warning)\s*:\s*", "", s, flags=re.IGNORECASE)
    # HTML-unescape entities like `&ge;` / `&lt;` BEFORE truncating at `;`,
    # so the entity terminator isn't mistaken for a response separator.
    import html as _html
    s = _html.unescape(s)
    # Truncate at first `;` (response text after `;` is description).
    if ";" in s:
        s = s.split(";", 1)[0]
    s = re.sub(r"`", "", s)
    s = s.lower().strip()
    s = re.sub(r"\s+", " ", s)
    return s


def _is_subseq(short: list[str], long: list[str]) -> bool:
    """Whole-word contiguous sub-sequence match (CC-07.4.4.5 VAG-18-bis)."""
    if not short:
        return False
    if len(short) > len(long):
        return False
    for i in range(len(long) - len(short) + 1):
        if long[i:i + len(short)] == short:
            return True
    return False


def _match(spec_slug: str, diagram_slug: str) -> bool:
    a = spec_slug.split()
    b = diagram_slug.split()
    if not a or not b:
        return False
    # The smaller list must be a contiguous sub-sequence of the larger.
    if len(a) <= len(b):
        return _is_subseq(a, b)
    return _is_subseq(b, a)


def _extract_spec_failure_rows(phase_id: str) -> list[tuple[str, str]]:
    """Return [(failure_text, response_text), ...] for a phase's Failure Modes."""
    # Locate the phase heading.
    heading_re = re.compile(
        rf"^###\s+{re.escape(phase_id)}\s+—\s+", re.MULTILINE
    )
    m = heading_re.search(specs_text)
    if not m:
        return []
    # Locate the *next* `### ` heading to bound the section.
    end_match = re.search(r"^###\s", specs_text[m.end():], re.MULTILINE)
    end = m.end() + (end_match.start() if end_match else len(specs_text) - m.end())
    section = specs_text[m.start():end]
    # Find the Failure Modes table.
    fm_match = re.search(r"\*\*Failure Modes\*\*:\s*\n", section)
    if not fm_match:
        return []
    after = section[fm_match.end():]
    rows: list[tuple[str, str]] = []
    for line in after.splitlines():
        stripped = line.strip()
        if not stripped:
            # Blank line ends the table.
            if rows:
                break
            continue
        if not stripped.startswith("|"):
            break
        cells = [c.strip() for c in stripped.strip("|").split("|")]
        if len(cells) < 3:
            continue
        if cells[0].lower() == "failure":
            continue
        if cells[0].startswith("---") or all(c.replace("-", "") == "" for c in cells):
            continue
        rows.append((cells[0], cells[2]))
    return rows


def _extract_diagram_error_labels(phase_id: str) -> list[str]:
    """Return the labels of `:::error` nodes in the phase's Mermaid block."""
    heading_re = re.compile(
        rf"^###\s+{re.escape(phase_id)}\s+—\s+", re.MULTILINE
    )
    m = heading_re.search(phases_text)
    if not m:
        return []
    end_match = re.search(r"^###\s", phases_text[m.end():], re.MULTILINE)
    end = m.end() + (end_match.start() if end_match else len(phases_text) - m.end())
    section = phases_text[m.start():end]
    fence_match = re.search(r"```mermaid\n(.*?)\n```", section, re.DOTALL)
    if not fence_match:
        return []
    body = fence_match.group(1)
    labels: list[str] = []
    # Match `NODE[/" ... "/]:::error` (parallelogram) and `NODE["..."]:::error`.
    # Labels are quote-bounded and on a single line in the harness corpus,
    # so `[^"]*` avoids the DOTALL runaway that would otherwise span node
    # definitions. CC-07.4.4 declares :::error as parallelogram but the
    # parity rule is shape-agnostic.
    pattern = re.compile(r'\[\s*/?\s*"([^"]*)"\s*/?\s*\]\s*:::error')
    for m2 in pattern.finditer(body):
        labels.append(m2.group(1))
    return labels


def _routes_to_R(response_text: str) -> bool:
    low = response_text.lower()
    return any(token.lower() in low for token in ROUTING_TO_R)


total_missing: list[str] = []
total_silent: list[str] = []
scanned = 0

for phase in SCOPED_PHASES:
    spec_rows = _extract_spec_failure_rows(phase)
    diagram_labels = _extract_diagram_error_labels(phase)
    if not spec_rows or not diagram_labels:
        # Phase missing from one of the docs — that's a structural issue
        # but outside CC-07.4.4.5 scope (CC-07.4.4 rule 0 covers it).
        continue
    scanned += 1
    # Filter spec rows: drop ABANDON-only rows + STALL routing-to-R rows.
    # Word-boundary match avoids in**stall**ed / **abandon**ware false hits.
    _has_word = lambda txt, w: re.search(rf"\b{w}\b", txt.lower()) is not None
    in_phase_rows = [
        (f, r) for (f, r) in spec_rows
        if not _routes_to_R(r)
        and not _has_word(f, "abandon")
        and not _has_word(f, "stall")
        and not _has_word(f, "abandons")
        and not _has_word(f, "stalled")
    ]
    spec_slugs = [_slugify_spec_failure(f) for (f, _) in in_phase_rows]
    diagram_slugs = [_slugify_diagram_label(lbl) for lbl in diagram_labels]
    # Missing nodes — every spec slug must match at least one diagram slug.
    for s in spec_slugs:
        if not any(_match(s, d) for d in diagram_slugs):
            total_missing.append(
                f'[CC-07.4.4.5] phase {phase} spec declares failure "{s}" — '
                f'no matching :::error node in diagram'
            )
    # Advisory: silent nodes — diagram slugs that match no spec slug.
    for d in diagram_slugs:
        if not any(_match(s, d) for s in spec_slugs):
            total_silent.append(
                f'phase {phase} diagram error node "{d}" not declared in spec '
                f'Failure Modes table — either add to spec or remove from diagram'
            )

print(
    f"CC-07.4.4.5 failure-mode parity: scanned {scanned} per-phase diagram(s); "
    f"{len(total_missing)} missing node(s); {len(total_silent)} silent node(s) "
    f"— STRICT (fail-closed on missing; silent are advisory)"
)
for line in total_missing[:30]:
    print(f"  ✗ {line}", file=sys.stderr)
if len(total_missing) > 30:
    print(f"  ... and {len(total_missing) - 30} more", file=sys.stderr)
for line in total_silent[:10]:
    print(f"  ⚠ {line}")
if not total_missing and not total_silent:
    print("  every spec-declared in-phase failure has a matching :::error node ✓")

sys.exit(1 if total_missing else 0)
PY
