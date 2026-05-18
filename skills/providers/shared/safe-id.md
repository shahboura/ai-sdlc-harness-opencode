# Safe ID Normalisation

> Owner: cross-cutting
> Version: 1.0

<!-- Created by: dev-workflow-plan.md [M-01] [IMPL-01-14]
     Reason: Canonical safe_id() normalisation rule per CC-05.7.1 (RAG-29) — consumed by every provider adapter's work-items.md.
     CC conventions applied: CC-04.2, CC-04.4, CC-05.7.1 -->

## Purpose

Deterministic, idempotent normalisation of provider-native work-item IDs to a path-safe form. Per CC-05.7.1 the per-workflow directory uses `ai/<YYYY-MM-DD>-<work-item-id>/`; the segment must be filesystem-safe across macOS / Linux / Windows. RAG-29 makes this the single source so every provider adapter normalises identically.

## Rule

Replace every character outside `[A-Za-z0-9._-]` with `-`. Specifically:

- `/` → `-`
- `:` → `-`
- `\` → `-`
- (space) → `-`
- Every other character that does not match `[A-Za-z0-9._-]` → `-`

The rule is **applied character-by-character**; no consolidation of consecutive dashes (consecutive-dash collapse was considered and rejected — it would make `Backlog//123` and `Backlog/123` produce the same path, which loses information).

## Reference implementation (Python)

```python
import re

_SAFE_ID_PATTERN = re.compile(r'[^A-Za-z0-9._-]')

def safe_id(raw: str) -> str:
    """Normalise a provider-native work-item ID to a path-safe form.

    Idempotent: safe_id(safe_id(x)) == safe_id(x) for any x.
    Deterministic: same input always produces the same output.
    Raises ValueError on empty or None input — callers must reject ambiguous IDs upstream.
    """
    if not raw:
        raise ValueError("safe_id: empty or None input")
    return _SAFE_ID_PATTERN.sub('-', raw)
```

## Reference implementation (Bash)

```bash
safe_id() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    echo "safe_id: empty input" >&2
    return 1
  fi
  echo "$raw" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g'
}
```

## Examples (per CC-05.7.1)

| Provider | Raw ID | `safe_id()` output |
|---|---|---|
| ADO | `Backlog/123` | `Backlog-123` |
| Jira Cloud | `PROJ:123` | `PROJ-123` |
| GitHub | `org/repo#42` | `org-repo-42` |
| GitLab | `group/sub/proj!17` | `group-sub-proj-17` |
| Linear | `ENG-456` | `ENG-456` *(no change)* |

## Adapter responsibilities

Each provider adapter's `work-items.md` must:

1. Call `safe_id()` on the provider-native ID before any path is constructed.
2. **Reject** at fetch time any ID that would collapse ambiguously after normalisation (e.g. two distinct provider IDs that produce the same `safe_id()` — typically impossible, but defensive).
3. **Never** silently produce a divergent path for a normalisable ID.

## Citation form

Per CC-04.3, every consumer cites this file with:

```markdown
> Authoritative reference: [safe-id](../../providers/shared/safe-id.md)
```

Inlining the regex pattern in an adapter is a CC-04.5 drift signal.
