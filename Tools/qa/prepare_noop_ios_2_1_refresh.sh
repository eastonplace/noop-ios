#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  echo "Not inside a Git repository." >&2
  exit 1
fi
cd "$ROOT"

EXPECTED_BRANCH="release/noop-ios-2.1"
BASE_REF="origin/release/noop-ios-2.0"
CURRENT_BRANCH="$(git branch --show-current)"

if [[ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]]; then
  echo "Expected $EXPECTED_BRANCH, found ${CURRENT_BRANCH:-detached HEAD}." >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree is not clean; refusing to fetch/rebase or overwrite local work." >&2
  git status --short --branch >&2
  exit 1
fi

git fetch --all --prune

if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  echo "Missing $BASE_REF after fetch." >&2
  exit 1
fi

OLD_HEAD="$(git rev-parse HEAD)"
BASE_HEAD="$(git rev-parse "$BASE_REF")"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
ARCHIVE_BRANCH="archive/release-noop-ios-2.1-before-refresh-$STAMP"

printf 'Feature before refresh: %s\n' "$OLD_HEAD"
printf 'Base for refresh:       %s\n' "$BASE_HEAD"
printf 'Archive branch:         %s\n' "$ARCHIVE_BRANCH"

git branch "$ARCHIVE_BRANCH" "$OLD_HEAD"
git push origin "$ARCHIVE_BRANCH:$ARCHIVE_BRANCH"

# The published archive above is the non-negotiable rollback point. Rebase the WHOOP-only 2.1 delta onto
# the moving 2.0 release line; a conflict exits immediately without reset, checkout, or data destruction.
git rebase "$BASE_REF"

NEW_HEAD="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$BASE_REF" HEAD
git diff --check

cat <<EOF

Refresh completed locally.
Old head:     $OLD_HEAD
Archived at:  origin/$ARCHIVE_BRANCH
Base head:    $BASE_HEAD
New head:     $NEW_HEAD

Do not force-push yet. Apply the remaining app-file integrations documented in:
  docs/qa/noop-ios-2.1-implementation-handoff.md

Then run:
  docs/qa/noop-ios-2.1-local-verification.md

Only after exact-head verification, publish with the preserved-tip-safe command:
  git push --force-with-lease origin $EXPECTED_BRANCH
EOF
