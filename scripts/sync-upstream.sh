#!/usr/bin/env bash
# Sync from upstream MostAshraf/ai-sdlc-harness
# Standard fork sync — no submodule involved
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "=== Fetching upstream ==="
git fetch upstream

echo "=== Current branch ==="
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "On branch: $BRANCH"

echo "=== Merging upstream changes ==="
git merge upstream/main --no-edit || {
  echo "Merge conflict detected. Resolve conflicts, then run:"
  echo "  git commit && git push origin $BRANCH"
  exit 1
}

echo "=== Updating versions.json (core_ref) ==="
CORE_SHA=$(git rev-parse HEAD)
CURRENT_VERSION=$(node -e "console.log(require('./versions.json').version)")
cat > versions.json <<EOF
{
  "version": "$CURRENT_VERSION",
  "core_ref": "$CORE_SHA"
}
EOF

git add versions.json
git commit --amend --no-edit

echo "=== Done. Push: git push origin $BRANCH ==="
