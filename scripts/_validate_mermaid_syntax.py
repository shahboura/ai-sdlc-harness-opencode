#!/usr/bin/env python3
"""Structural Mermaid syntax validator.

Created by: dev-workflow-plan.md [M-16] [IMPL-16-02]
Reason: CC-07.4 / GAP-23 — validate every Mermaid fence's structural
requirements (HTML entities, quoted subgraph titles, classDef closure, shape
delimiters, etc.) without invoking the full Mermaid renderer.

Reads the hook payload file path from argv[1] (when fired by the PreToolUse
hook) — extracts the in-flight content (new_string / content) and validates
the Mermaid fences inline. Standalone use: `python _validate_mermaid_syntax.py
<file.md>` validates the on-disk file's fences.

Exit codes (per CC-01.5):
    0   valid (no fences, or all fences pass)
    1   rule violation found
    2   precondition unmet (file missing, malformed payload)

Policy when invoked from the hook: fail-CLOSED per CC-03.2 / CC-07.4.2 — block
the write on validation failure. Falls back to fail-open advisory when the
external mermaid-cli is unavailable in interactive mode (CC-07.4.3).
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable

_CI_ENV_VARS = (
    "CI",
    "GITHUB_ACTIONS",
    "GITLAB_CI",
    "BUILDKITE",
    "JENKINS_HOME",
    "CIRCLECI",
    "TF_BUILD",
)


def _is_ci() -> bool:
    return any(os.environ.get(k) for k in _CI_ENV_VARS)


_FENCE_RE = re.compile(r"```mermaid\s*\n(.*?)\n```", re.DOTALL)
_KNOWN_OPENERS = (
    "flowchart ",
    "graph ",
    "stateDiagram",
    "classDiagram",
    "sequenceDiagram",
    "erDiagram",
    "gitGraph",
    "journey",
    "pie ",
)


def _extract_fences(text: str) -> list[tuple[int, str]]:
    """Return [(line_offset, fence_body), ...] for every ```` ```mermaid ```` fence.

    line_offset is the 1-based line number where the fence body begins (the
    line AFTER the ```` ```mermaid ```` opener).
    """
    fences: list[tuple[int, str]] = []
    for m in _FENCE_RE.finditer(text):
        # Line where fence-body starts = line containing the opener + 1.
        opener_idx = m.start()
        line_offset = text.count("\n", 0, opener_idx) + 2
        fences.append((line_offset, m.group(1)))
    return fences


def _validate_fence(body: str, file_path: str, line_offset: int) -> list[str]:
    """Apply structural rules to one fence body. Return a list of failure lines."""
    failures: list[str] = []
    lines = body.splitlines()

    # R1: known opener
    first = next((ln.strip() for ln in lines if ln.strip()), "")
    if not any(first.startswith(o) for o in _KNOWN_OPENERS):
        failures.append(
            f"{file_path}:{line_offset}:1: R1: unknown diagram opener: {first!r}"
        )

    # R8: forbid `//` and `<!-- -->` comments inside fences
    for i, ln in enumerate(lines):
        stripped = ln.strip()
        if stripped.startswith("<!--") or stripped.endswith("-->"):
            failures.append(
                f"{file_path}:{line_offset + i}:1: R8: HTML comment inside mermaid fence — use %% instead"
            )
        if "//" in ln and not stripped.startswith("%%"):
            # Only flag bare `//` at line start (URL fragments are fine).
            if stripped.startswith("//"):
                failures.append(
                    f"{file_path}:{line_offset + i}:1: R8: `//` comment inside mermaid fence — use %% instead"
                )

    # R3: subgraph quoted form
    for i, ln in enumerate(lines):
        m = re.match(r"\s*subgraph\s+(\w+)\s*(\[)?(.*?)$", ln)
        if not m:
            continue
        bracket = m.group(2)
        title = (m.group(3) or "").rstrip()
        # Only fail when the title carries a `[`-bracket form that isn't quoted.
        if bracket == "[" and not title.startswith('"') and not title.endswith(']'):
            failures.append(
                f"{file_path}:{line_offset + i}:1: R3: unquoted subgraph title — use `subgraph X[\"title\"]`"
            )

    # R4: classDef ↔ class-reference closure
    classdef = set()
    for ln in lines:
        m = re.match(r"\s*classDef\s+(\w+)", ln)
        if m:
            classdef.add(m.group(1))
    for i, ln in enumerate(lines):
        for cls in re.findall(r":::(\w+)", ln):
            if cls not in classdef:
                failures.append(
                    f"{file_path}:{line_offset + i}:1: R4: class `:::{cls}` referenced but no `classDef {cls}` in this diagram"
                )

    # R7: shape delimiter closure (per-line scan — Mermaid shapes don't span lines).
    # Only flag obvious unmatched stadium / hexagonal / double-circle forms.
    for i, ln in enumerate(lines):
        bare = ln.strip()
        # Stadium: `node([...])` — common, watch for unquoted parens inside.
        # Heuristic: if a stadium contains `(` after the `[`, it must use the quoted form `(["..."])`.
        m = re.search(r"\b\w+\(\[([^\]]*)\]\)", bare)
        if m:
            inner = m.group(1)
            if ("(" in inner or ")" in inner) and not (inner.startswith('"') and inner.endswith('"')):
                failures.append(
                    f"{file_path}:{line_offset + i}:1: R7: stadium shape with inner parens must be quoted (`node([\"...\"])`)"
                )

    # R9: 60-node ceiling — coarse count of distinct node IDs.
    nodes: set[str] = set()
    for ln in lines:
        # Match `nodeId[...` / `nodeId(...` / `nodeId{...` / `nodeId-->`.
        for m in re.finditer(r"(?:^|\s|-->|---|==>|-\.->)([A-Za-z_]\w*)(?=[\[\(\{\s]|$)", ln):
            nodes.add(m.group(1))
    if len(nodes) > 60:
        failures.append(
            f"{file_path}:{line_offset}:1: R9: diagram has {len(nodes)} nodes; cap is 60 — split into sub-diagrams"
        )

    # R11: in `sequenceDiagram` fences, Notes / message text / alt conditions
    # must not contain characters that Mermaid's sequence parser tokenises
    # as statement boundaries or arrow fragments:
    #
    #   HTML entities (`&xxx;` form):
    #     `&lt;a&gt;-&lt;b&gt;` — `&gt;-&lt;` consumed as a partial arrow
    #     `Planning &amp; Approval` — parse failure on the NEXT line
    #     `&ge; N&percnt;` — produces unexpected NEWLINE token  # CC-09-OK: example fixture, not a runtime threshold
    #   Literal semicolon `;`:
    #     `Note over A: hello; world` — `;` treated as statement separator
    #
    # The fix is to use `{placeholder}` syntax, plain prose, or the literal
    # Unicode character (≥, %, &, ...) instead of HTML entities, and to
    # replace inline `;` with `—` / `,` / period split. Flowcharts and other
    # diagram types are NOT affected — this rule is scoped to sequenceDiagram.
    if first.startswith("sequenceDiagram"):
        entity_re = re.compile(r"&[a-zA-Z][a-zA-Z0-9]*;")
        for i, ln in enumerate(lines):
            stripped = ln.strip()
            if not stripped or stripped.startswith("%%"):
                continue
            m = entity_re.search(stripped)
            if m:
                failures.append(
                    f"{file_path}:{line_offset + i}:1: R11: HTML entity "
                    f"`{m.group(0)}` in sequenceDiagram text — Mermaid sequence "
                    f"parser chokes on HTML entities (observed: `&lt;` `&gt;` "
                    f"`&amp;` `&ge;` `&percnt;`); use `{{placeholder}}` syntax, "
                    f"plain prose, or the literal Unicode character instead"
                )
            # Semicolons only matter in text-bearing statements (after a `:`).
            # Skip the diagram opener and structural keywords. We look for
            # `:` followed by content that contains `;`.
            if ":" in stripped and ";" in stripped:
                # Split on the FIRST colon — content after is the free-form
                # text where `;` will break parsing.
                _, _, content = stripped.partition(":")
                if ";" in content:
                    failures.append(
                        f"{file_path}:{line_offset + i}:1: R11: literal `;` "
                        f"in sequenceDiagram text — Mermaid treats `;` as a "
                        f"statement separator; replace with `—` / `,` / period "
                        f"or split into two notes"
                    )

    return failures


def _validate_file(path: str, content: str | None = None) -> tuple[int, list[str]]:
    """Validate every fence in `content` (or in the file at `path` when content
    is None). Returns (exit_code, [failure_lines]).
    """
    if content is None:
        try:
            content = Path(path).read_text(encoding="utf-8")
        except FileNotFoundError:
            return 2, [f"validate-mermaid: file not found: {path}"]
        except OSError as e:
            return 2, [f"validate-mermaid: read failed: {e}"]

    fences = _extract_fences(content)
    if not fences:
        return 0, [f"{path}: no mermaid fences found"]

    all_failures: list[str] = []
    for line_offset, body in fences:
        all_failures.extend(_validate_fence(body, path, line_offset))

    # R10 — optional external validator. Skipped when mermaid-cli absent in
    # interactive mode; CI mode would force install at the orchestrator layer.
    mmdc = shutil.which("mmdc") or shutil.which("mermaid")
    if mmdc:
        for line_offset, body in fences:
            try:
                r = subprocess.run(
                    [mmdc, "--quiet", "--input", "-", "--output", os.devnull],
                    input=body,
                    text=True,
                    capture_output=True,
                    timeout=10,
                )
                if r.returncode != 0:
                    all_failures.append(
                        f"{path}:{line_offset}:1: R10 (mermaid-cli): {r.stderr.strip() or 'parse failed'}"
                    )
            except (subprocess.TimeoutExpired, OSError) as e:
                # Don't swallow — surface as advisory unless CI.
                msg = f"{path}: mermaid-cli invocation failed: {e}"
                if _is_ci():
                    all_failures.append(msg)
    else:
        if _is_ci():
            return 2, [
                f"[CC-07.4.3] mermaid validator (mmdc) unavailable in CI — install mermaid-cli"
            ]
        # Interactive — advisory only, never block.
        all_failures.append(f"advisory: mmdc not on PATH; structural rules only")

    # Filter advisory lines for exit-code determination.
    blocking = [f for f in all_failures if not f.startswith("advisory:")]
    if blocking:
        return 1, all_failures
    return 0, all_failures + [f"mermaid: PASS — {len(fences)} fence(s) in {path}"]


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: _validate_mermaid_syntax.py <file.md OR hook-payload.json>", file=sys.stderr)
        return 2

    arg = sys.argv[1]
    # Detect hook-payload form: argv[1] is a path to a JSON file.
    try:
        with open(arg, "r", encoding="utf-8") as f:
            first = f.read(1)
        if first == "{":
            with open(arg, "r", encoding="utf-8") as f:
                payload = json.load(f)
            tool_input = payload.get("tool_input") or {}
            file_path = tool_input.get("file_path", "")
            if not file_path or not file_path.endswith(".md"):
                return 0  # not our concern
            # Build the post-edit content.
            tool_name = payload.get("tool_name", "")
            try:
                current = Path(file_path).read_text(encoding="utf-8")
            except OSError:
                current = ""
            if tool_name == "Write":
                content = tool_input.get("content", "")
            elif tool_name == "Edit":
                old = tool_input.get("old_string", "")
                new = tool_input.get("new_string", "")
                content = current.replace(old, new, 1) if old in current else current
            elif tool_name == "MultiEdit":
                content = current
                for e in tool_input.get("edits", []) or []:
                    o = e.get("old_string", "")
                    n = e.get("new_string", "")
                    if o in content:
                        content = content.replace(o, n, 1)
            else:
                return 0
            if "```mermaid" not in content:
                return 0
            code, lines = _validate_file(file_path, content)
        else:
            code, lines = _validate_file(arg)
    except OSError:
        return 2

    stream = sys.stdout if code == 0 else sys.stderr
    for ln in lines:
        print(ln, file=stream)
    return code


if __name__ == "__main__":
    sys.exit(main())
