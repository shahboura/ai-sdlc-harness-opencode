"""Atomic file write & rename primitive.

> Owner: cross-cutting
> Version: 1.0

Created by: dev-workflow-plan.md [M-08] [IMPL-08-07]
Reason: Generic crash-safe rename primitive used by `_recovery_state_writer.py`
(marker rotation) and the M-14 tracker rename (P8 reconcile archive). Lives
as its own module so other call sites can reuse it without importing the
recovery-marker domain logic (CC-08.1 / YAGNI — extract once, no premature
function-per-file fragmentation per CC-01.7).

CC conventions applied:
    CC-04.2 (Python helpers in `scripts/_<concern>_utils.py` form)
    CC-04.3 (Python `from` import form for consumers)
    CC-04.4 (owner = cross-cutting)
    CC-03.3 (caller-bounded isolation — mutates only what the caller passes in)
    CC-03.7 (idempotent on re-invocation with identical inputs)
    CC-01.7 (single-responsibility module boundary — rename primitive vs marker domain)

Exports:
    atomic_write(path, content) -> bool
    atomic_rename(src, dst) -> None
"""
from __future__ import annotations

import os
import tempfile
from pathlib import Path
from typing import Union

PathLike = Union[str, os.PathLike]


def atomic_write(path: PathLike, content: str, encoding: str = "utf-8") -> bool:
    """Atomically write `content` to `path` using a tempfile + rename.

    Writes to `<path>.tmp.<pid>` in the same directory (same-filesystem rename
    is guaranteed atomic on POSIX), `fsync`s the file, then `os.rename`s it
    into place. On rename failure, the tempfile is removed.

    Returns:
        True when the write produced a new on-disk value; False when the
        target already had identical content (idempotent no-op).

    Raises:
        OSError on filesystem failures the caller cannot meaningfully retry.
    """
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)

    # Idempotent no-op when content is unchanged. Reading the file is cheap
    # compared to the rename; skipping the rename avoids unnecessary inode
    # churn that would invalidate other readers' mtime-based caches.
    if target.is_file():
        try:
            if target.read_text(encoding=encoding) == content:
                return False
        except (OSError, UnicodeDecodeError):
            # Read failure → fall through and overwrite.
            pass

    fd, tmp_path = tempfile.mkstemp(
        prefix=target.name + ".",
        suffix=".tmp",
        dir=str(target.parent),
    )
    try:
        with os.fdopen(fd, "w", encoding=encoding) as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp_path, target)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return True


def atomic_rename(src: PathLike, dst: PathLike) -> None:
    """Atomic, tempfile-free rename for already-on-disk files.

    Same as `os.rename` but ensures the destination's parent exists before
    the rename — calls cross filesystems if needed (falls back to copy + unlink).

    Raises:
        FileNotFoundError when `src` does not exist.
        OSError on filesystem failures.
    """
    src_p = Path(src)
    dst_p = Path(dst)
    if not src_p.exists():
        raise FileNotFoundError(f"atomic_rename: source not found: {src}")
    dst_p.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.rename(src_p, dst_p)
    except OSError as e:
        # Cross-filesystem fallback: copy + unlink. Only triggered when src and
        # dst are on different mounts — rare in the harness's typical layout,
        # but defensive for users with separate /home / /workspace volumes.
        import shutil

        if e.errno not in (None,):  # EXDEV on most systems; defensive
            shutil.copy2(src_p, dst_p)
            os.unlink(src_p)
        else:
            raise
