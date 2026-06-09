#!/bin/bash
# Code-push autopatch. Run on a schedule (launchd/cron, e.g. hourly). Each run:
#   1. fetches origin/$WATCH_BRANCH
#   2. if HEAD moved since the last build: sync the worktree, build a release
#      Dart snapshot, verify it matches the installed engine, push it as the
#      next patch number
#   3. records the built commit so the next run is a no-op until the branch moves
#
# Only Dart-only changes are code-pushable. If the branch changes native code,
# plugins, or the Flutter version, rebuild + reinstall the base app instead.
set -o pipefail
# shellcheck source=codepush-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/codepush-lib.sh"
load_config
: "${WATCH_BRANCH:?set WATCH_BRANCH in config.env}"

STATE_DIR="$TOOLING_DIR/.state"; mkdir -p "$STATE_DIR"
LAST_SHA_FILE="$STATE_DIR/last_built_sha"
LOCK="$STATE_DIR/lock"
LOG="$STATE_DIR/autopatch.log"

# Override log() to add timestamps + tee to the log file.
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

# Single-run lock (mkdir is atomic).
mkdir "$LOCK" 2>/dev/null || { log "another autopatch run is in progress — skipping."; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

log "=== autopatch run start ==="
preflight_dashboard

cd "$WORKTREE_DIR" || { log "cannot cd $WORKTREE_DIR"; exit 1; }
git fetch --quiet origin "$WATCH_BRANCH" 2>>"$LOG"
REMOTE_SHA=$(git rev-parse "origin/$WATCH_BRANCH" 2>/dev/null)
LAST_SHA=$(cat "$LAST_SHA_FILE" 2>/dev/null || echo none)
log "origin/$WATCH_BRANCH=${REMOTE_SHA:0:10}  last_built=${LAST_SHA:0:10}"

[ -z "$REMOTE_SHA" ] && { log "could not resolve origin/$WATCH_BRANCH — aborting."; exit 0; }
[ "$REMOTE_SHA" = "$LAST_SHA" ] && { log "no change on $WATCH_BRANCH — nothing to build."; exit 0; }

log "change detected -> building from ${REMOTE_SHA:0:10}"
git reset --hard "origin/$WATCH_BRANCH" >>"$LOG" 2>&1

build_app >>"$LOG" 2>&1 || { log "build failed — not pushing (see $LOG)."; exit 1; }
push_patch "$BUILT_LIBAPP" "$BUILT_APK" >>"$LOG" 2>&1 || { log "push failed."; exit 1; }
echo "$REMOTE_SHA" > "$LAST_SHA_FILE"
log "=== autopatch run done (pushed patch #$PUSHED_NUMBER for ${REMOTE_SHA:0:10}) ==="
