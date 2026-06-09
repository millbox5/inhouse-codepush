#!/bin/bash
# Build the app from ANY git branch (or the current worktree) and push it as a
# code-push patch — on demand. autopatch.sh watches one branch automatically;
# this is for ad-hoc / feature branches you want to ship a patch from right now.
# The dashboard's branch picker calls this script.
#
#   ./push-branch.sh <branch>     # reset the worktree to origin/<branch> and build
#   ./push-branch.sh --current    # build the worktree exactly as-is (WIP ok)
#
# Override the targeted release without editing config.env:
#   TARGET_RELEASE=2.0.0 ./push-branch.sh my-feature
set -o pipefail
# shellcheck source=codepush-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/codepush-lib.sh"
load_config

BRANCH="${1:?usage: push-branch.sh <branch> | --current}"
RELEASE="${TARGET_RELEASE:-$RELEASE_VERSION}"

preflight_dashboard
cd "$WORKTREE_DIR" || { log "worktree missing: $WORKTREE_DIR"; exit 1; }

if [ "$BRANCH" = "--current" ]; then
  log "building worktree as-is ($(git rev-parse --abbrev-ref HEAD 2>/dev/null))"
else
  git fetch origin "$BRANCH" || { log "git fetch origin $BRANCH failed"; exit 1; }
  git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1 \
    || { log "branch '$BRANCH' not found on origin"; exit 1; }
  # reset --hard (not checkout): discards prior inject edits and handles a dirty
  # worktree + odd branch names, which `git checkout` refuses.
  git reset --hard "origin/$BRANCH" || { log "could not reset to origin/$BRANCH"; exit 1; }
  log "building '$BRANCH' ($(git rev-parse --short HEAD))"
fi

build_app || exit 1
push_patch "$BUILT_LIBAPP" "$BUILT_APK" "$RELEASE" || exit 1
