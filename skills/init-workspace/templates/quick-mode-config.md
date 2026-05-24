# Quick-Mode Configuration

> **Owner:** workspace (per-developer)
> **Written by:** `/init-workspace` — do not hand-edit unless you understand all three consumers.
> **Consumers:** `scripts/quick-mode-classify.py` (QPhaseGuard + Planner heuristics + gate-policy tiering)
> **Authority:** ADR-011, FR-1.4, FR-10.2, CC-09

This file configures both quick-mode entry thresholds (FR-1.4 quantitative guards)
and TDD-skip categories (FR-10 categorical heuristics). Both sections are consumed by
the same `classify_change()` helper — single source of truth per ADR-011.

---

## Quantitative thresholds (FR-1.4 hard aborts)

`QPhaseGuard` aborts quick-mode and prompts to restart in full pipeline if any
threshold below is exceeded. Values are read at runtime — edit here to tune for
your team.

loc_max: 80
files_max: 5
abort_on_public_api: true
abort_on_migration: true
abort_on_security_paths: true

---

## Categorical heuristics (FR-1 / FR-10 shared)

Categories that are always considered quick-mode safe (test-required: false is valid).
Planner cites these in its TDD-skip worked examples (planner/index.md).
The `is_quick_mode_safe_category()` helper returns true for any value listed here.

quick_mode_safe_categories:
  - ui-style-copy
  - infra-config
  - exploratory-data
  - doc-only

---

## Public-API path patterns

Files matching these glob patterns set `public_api_touched: true`, which triggers
a hard abort in quick-mode and a `high` tier for gate-policy.

public_api_patterns:
  - */__init__.py
  - */index.ts
  - */index.js
  - *.d.ts
  - */api/*.py
  - */api/*.ts

---

## Migration path patterns

Files matching these patterns set `migration_touched: true`.

migration_patterns:
  - */migrations/*
  - */migrate/*
  - *_migration.py
  - *_migration.ts
  - *migration_*.py

---

## Security-sensitive path prefixes

Path prefixes (trailing `/`) or basename patterns that set
`security_paths_touched: true`. Quick-mode aborts on any match,
regardless of LOC count.

security_paths:
  - auth/
  - crypto/
  - security/
  - .env
  - secrets/
  - credentials/
