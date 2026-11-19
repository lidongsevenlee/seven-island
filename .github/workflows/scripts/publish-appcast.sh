#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DMG_PATH="${1:?DMG path required}"
VERSION="${2:?Version required}"
BUILD="${3:?Build required}"
TAG="${4:?Tag required}"
REPOSITORY="${5:?Repository required}"

WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/seven-island-appcast.XXXXXXXX")"
cleanup() {
    git worktree remove --force "$WORKTREE" 2>/dev/null || rmdir "$WORKTREE"
}
trap cleanup EXIT

previous_base=""
for attempt in 1 2 3; do
    git fetch origin refs/heads/main
    base="$(git rev-parse FETCH_HEAD)"
    if [[ "$attempt" == 1 ]]; then
        git worktree add --detach "$WORKTREE" "$base"
    elif [[ "$base" == "$previous_base" ]]; then
        echo "Appcast push failed at the current main revision." >&2
        exit 1
    else
        git -C "$WORKTREE" checkout --detach "$base"
    fi

    python3 "$SCRIPT_DIR/update-appcast.py" "$WORKTREE/updater/appcast.xml" \
        "$DMG_PATH" "$VERSION" "$BUILD" "$TAG" "$REPOSITORY"
    if git -C "$WORKTREE" diff --quiet -- updater/appcast.xml; then
        echo "Appcast already contains the published DMG for $TAG."
        exit 0
    fi

    git -C "$WORKTREE" add updater/appcast.xml
    git -C "$WORKTREE" -c user.name="$GIT_USER" -c user.email="$GIT_EMAIL" \
        commit -m "Update appcast for $TAG"
    if git -C "$WORKTREE" push origin HEAD:refs/heads/main; then
        exit 0
    fi
    previous_base="$base"
done

echo "Could not publish the Appcast after three attempts." >&2
exit 1
