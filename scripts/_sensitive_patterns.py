#!/usr/bin/env python3
"""Shared sensitive-file pattern list used by both bash-write-guard and
sensitive-file-guard. Single source of truth — change a pattern here and
both guards pick it up.
"""
from __future__ import annotations

import fnmatch
import os

# Patterns matched against the file's basename. `fnmatch` semantics:
# `.env`        matches exactly `.env`
# `.env.*`      matches `.env.local`, `.env.production`, etc.
# `*.env`       matches `local.env`, `prod.env`, etc.
SENSITIVE_PATTERNS: list[str] = [
    ".env", ".env.*", "*.env",
    "*.pem", "*.key", "*.p12", "*.pfx", "*.kdbx", "*.crt",
    "id_rsa", "id_rsa.*", "id_ed25519", "id_ed25519.*",
    "*.tfstate", "*.tfstate.*",
    ".netrc", ".npmrc", ".pypirc",
    "credentials", "credentials.*",
    "secrets", "secrets.*",
]


def matches_sensitive(path: str) -> bool:
    """True if `path`'s basename matches any sensitive pattern."""
    base = os.path.basename(path.strip().strip('"').strip("'"))
    if not base:
        return False
    for pat in SENSITIVE_PATTERNS:
        if fnmatch.fnmatch(base, pat) or fnmatch.fnmatch(base.lower(), pat):
            return True
    return False
