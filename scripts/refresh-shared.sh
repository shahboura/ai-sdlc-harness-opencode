#!/usr/bin/env bash
# refresh-shared.sh — copy the plugin's agents/shared/*.md files into the
# workspace at .claude/context/agents-shared/ so subagents can `Read` them via
# workspace-relative paths.
#
# Why this exists: `CLAUDE_PLUGIN_ROOT` is exported to hook scripts but NOT to
# the agent runtime (verified empirically + per Claude Code docs). When a
# subagent like the planner runs `Read agents/shared/engineering-principles.md`,
# the Read tool resolves the path against the user's project workspace cwd,
# not against the plugin install. The file isn't there, the Read fails, and
# the agent reports it as "not found" (non-blocking but noisy).
#
# Resolution: copy the shared files into a workspace-local mirror at
# `.claude/context/agents-shared/`. Idempotent — overwrites existing copies
# so plugin updates propagate on the next run.
#
# Usage:
#   scripts/refresh-shared.sh [<workspace-root>]
#     <workspace-root>  defaults to $PWD. Must contain `.claude/context/`.
#
# Exit codes:
#   0  success (files copied or already up to date)
#   1  plugin install path could not be discovered
#   2  workspace root invalid
set -uo pipefail

WORKSPACE_ROOT="${1:-$PWD}"

if [ ! -d "$WORKSPACE_ROOT/.claude/context" ]; then
    echo "refresh-shared: workspace root '$WORKSPACE_ROOT' lacks .claude/context/ — run /init-workspace first" >&2
    exit 2
fi

# Plugin discovery. The Claude Code plugin cache lives at
# ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/. We pick the
# highest installed version of ai-sdlc-harness — Claude Code itself loads the
# same one for current runs.
PLUGIN_NAME="ai-sdlc-harness"
PLUGIN_CACHE="$HOME/.claude/plugins/cache/$PLUGIN_NAME/$PLUGIN_NAME"

if [ ! -d "$PLUGIN_CACHE" ]; then
    echo "refresh-shared: plugin cache not found at $PLUGIN_CACHE — is the plugin installed?" >&2
    exit 1
fi

# `sort -V` (version sort) gives us the latest installed version directory.
PLUGIN_VERSION_DIR="$(ls -1d "$PLUGIN_CACHE"/*/ 2>/dev/null \
    | grep -E '/[0-9]+\.[0-9]+\.[0-9]+/$' \
    | sort -V \
    | tail -1)"

if [ -z "$PLUGIN_VERSION_DIR" ] || [ ! -d "$PLUGIN_VERSION_DIR/agents/shared" ]; then
    echo "refresh-shared: no installed version of $PLUGIN_NAME has agents/shared/ — checked $PLUGIN_CACHE/*" >&2
    exit 1
fi

SRC="${PLUGIN_VERSION_DIR%/}/agents/shared"
DST="$WORKSPACE_ROOT/.claude/context/agents-shared"

mkdir -p "$DST"
copied=0
for f in "$SRC"/*.md; do
    [ -e "$f" ] || continue
    cp "$f" "$DST/"
    copied=$((copied + 1))
done

if [ "$copied" -eq 0 ]; then
    echo "refresh-shared: no .md files found in $SRC" >&2
    exit 1
fi

echo "refresh-shared: copied $copied file(s) from $SRC → $DST"
echo "  source plugin version: $(basename "${PLUGIN_VERSION_DIR%/}")"
