#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/boringNotch.xcodeproj/project.pbxproj"
NEW_VERSION="${1:?Usage: release.sh <version> [remote] [branch]}"
REMOTE="${2:-origin}"
BRANCH="${3:-main}"

cd "$ROOT_DIR"

# Ensure clean working tree (or allow uncommitted changes with --force?)
if ! git diff-index --quiet HEAD --; then
  echo "Error: You have uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

# Read current version
CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION' "$PROJECT_FILE" | sed 's/.*= //;s/;//' | head -1)
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION' "$PROJECT_FILE" | sed 's/.*= //;s/;//' | head -1)

# Derive build number from version (strip dots)
NEW_BUILD=$(echo "$NEW_VERSION" | sed 's/[^0-9]//g' | awk '{printf "%d", $1}')

echo "Updating: $CURRENT_VERSION (build $CURRENT_BUILD) → $NEW_VERSION (build $NEW_BUILD)"

# Update project file
sed -i '' "s/MARKETING_VERSION = $CURRENT_VERSION;/MARKETING_VERSION = $NEW_VERSION;/g" "$PROJECT_FILE"
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURRENT_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" "$PROJECT_FILE"

# Commit
git add -A
git commit -m "Bump version to $NEW_VERSION"

# Tag
TAG="v$NEW_VERSION"
git tag "$TAG"

echo ""
echo "=== Released v$NEW_VERSION ==="
echo "Push command:"
echo "  git push $REMOTE $BRANCH --tags"
