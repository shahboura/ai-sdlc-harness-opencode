#!/usr/bin/env bash
# Hook: migrate-ai-layout (one-shot migration, NOT a lifecycle hook)
# Policy: fail-open (script — exits non-zero only on filesystem errors the caller must see)
# Enforces: one-time migration from legacy `ai/plans/` + `ai/tasks/` layout to
#           `ai/<YYYY-MM-DD>-<work-item-id>/{plan,tracker,test-outline,...}.md`.
# Reads context from: ai/plans/, ai/tasks/, .claude/context/state.md
# Writes side-effects to: ai/<YYYY-MM-DD>-<work-item-id>/ (new directories)
#
# Created by: dev-workflow-plan.md [M-14] [IMPL-14-04]
# Reason: Per CC-01.5 idempotent — re-running on an already-migrated workspace
#         is a no-op. Per CC-05.7 the new layout is the canonical per-workflow
#         path; legacy paths are deprecated for new writes (existing files are
#         migrated by this script and the read-side compatibility in hooks
#         covers the transition window).
# CC conventions applied: CC-01.5 (idempotent), CC-05.7 (canonical layout).

set -uo pipefail

WS_ROOT="${1:-$(pwd)}"
LEGACY_PLANS="${WS_ROOT}/ai/plans"
LEGACY_TASKS="${WS_ROOT}/ai/tasks"

# Helper: derive a canonical per-workflow directory name from a story file's
# filename + mtime date. Files like `ai/tasks/PROJ-123.md` are paired with the
# matching plan file in `ai/plans/`. The directory is named
# `<YYYY-MM-DD>-<story-id>` where the date is the earliest mtime of the two files.

if [ ! -d "$LEGACY_TASKS" ] && [ ! -d "$LEGACY_PLANS" ]; then
    echo "migrate-ai-layout: nothing to migrate (no legacy directories at $WS_ROOT/ai/)."
    exit 0
fi

migrated=0
skipped=0
errors=0

if [ -d "$LEGACY_TASKS" ]; then
    while IFS= read -r -d '' tracker_file; do
        base=$(basename "$tracker_file" .md)
        plan_file="$LEGACY_PLANS/${base}.md"

        # Parse the harness's actual legacy filename convention:
        #     <YYYY-MM-DD>_<story-id>_<slug>.md   (preferred — date prefix included)
        #     <story-id>_<slug>.md                (fallback — date derived from mtime)
        #     <story-id>.md                       (rare — bare ID; date from mtime)
        if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})_([^_]+)(_.*)?$ ]]; then
            date_segment="${BASH_REMATCH[1]}"
            story_id="${BASH_REMATCH[2]}"
        elif [[ "$base" =~ ^([^_]+)_(.*)$ ]]; then
            story_id="${BASH_REMATCH[1]}"
            mtime=$(stat -f %m "$tracker_file" 2>/dev/null || stat -c %Y "$tracker_file")
            date_segment=$(date -u -r "$mtime" +"%Y-%m-%d" 2>/dev/null || date -u -d "@$mtime" +"%Y-%m-%d")
        else
            story_id="$base"
            mtime=$(stat -f %m "$tracker_file" 2>/dev/null || stat -c %Y "$tracker_file")
            date_segment=$(date -u -r "$mtime" +"%Y-%m-%d" 2>/dev/null || date -u -d "@$mtime" +"%Y-%m-%d")
        fi

        # Per CC-05.7.1 safe_id normalisation (defensive — IDs from harness are already path-safe).
        story_id_safe=$(echo "$story_id" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g')

        new_dir="${WS_ROOT}/ai/${date_segment}-${story_id_safe}"

        if [ -d "$new_dir" ]; then
            # Already migrated — idempotent no-op.
            skipped=$((skipped + 1))
            continue
        fi

        mkdir -p "$new_dir" || { errors=$((errors + 1)); continue; }
        # Move tracker → new location. Use mv -n (no-clobber) for safety.
        if ! mv -n "$tracker_file" "$new_dir/tracker.md"; then
            errors=$((errors + 1))
            rmdir "$new_dir" 2>/dev/null || true
            continue
        fi
        if [ -f "$plan_file" ]; then
            mv -n "$plan_file" "$new_dir/plan.md" 2>/dev/null || true
        fi
        migrated=$((migrated + 1))
        echo "migrated: $base → ${new_dir}/"
    done < <(find "$LEGACY_TASKS" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
fi

# Clean up empty legacy directories (preserve them when non-empty, e.g. if
# in-flight stories were skipped due to errors).
if [ -d "$LEGACY_TASKS" ] && [ -z "$(ls -A "$LEGACY_TASKS" 2>/dev/null)" ]; then
    rmdir "$LEGACY_TASKS" 2>/dev/null || true
fi
if [ -d "$LEGACY_PLANS" ] && [ -z "$(ls -A "$LEGACY_PLANS" 2>/dev/null)" ]; then
    rmdir "$LEGACY_PLANS" 2>/dev/null || true
fi

echo "migrate-ai-layout: $migrated migrated, $skipped already-migrated, $errors errors."
exit $(( errors > 0 ? 1 : 0 ))
