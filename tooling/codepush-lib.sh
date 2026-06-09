#!/bin/bash
# Shared helpers for the code-push tooling. Sourced by push-branch.sh and
# autopatch.sh. Not meant to be run directly.

CODEPUSH_TOOLING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[codepush] $*"; }

load_config() {
  TOOLING_DIR="$CODEPUSH_TOOLING_DIR"
  [ -f "$TOOLING_DIR/config.env" ] || {
    echo "[codepush] missing $TOOLING_DIR/config.env — copy config.env.example and fill it in." >&2
    exit 1
  }
  # shellcheck disable=SC1090
  source "$TOOLING_DIR/config.env"
  : "${FLUTTER_BIN:?set FLUTTER_BIN in config.env}"
  : "${APP_ID:?set APP_ID in config.env}"
  : "${RELEASE_VERSION:?set RELEASE_VERSION in config.env}"
  : "${ENGINE_SNAPSHOT:?set ENGINE_SNAPSHOT in config.env}"
  : "${DASHBOARD_URL:?set DASHBOARD_URL in config.env}"
  : "${ADMIN_TOKEN:?set ADMIN_TOKEN in config.env}"
  : "${APP_DIR:?set APP_DIR in config.env}"
  ARCH="${ARCH:-arm64}"
  BUILD_TARGET_PLATFORM="${BUILD_TARGET_PLATFORM:-android-arm64}"
  export GRADLE_OPTS="${GRADLE_OPTS:--Dorg.gradle.workers.max=8}"
}

preflight_dashboard() {
  curl -fsS -o /dev/null "$DASHBOARD_URL/" || {
    log "dashboard not reachable at $DASHBOARD_URL — start it first (dashboard-serve.sh)."
    exit 1
  }
}

copy_signing_files() {
  [ -n "$SIGNING_FILES" ] && [ -n "$SIGNING_SRC_DIR" ] || return 0
  local f
  for f in $SIGNING_FILES; do
    [ -f "$SIGNING_SRC_DIR/$f" ] && cp "$SIGNING_SRC_DIR/$f" "$APP_DIR/$f" && log "copied build file $f"
  done
  return 0
}

# Build the app and verify the snapshot. On success sets BUILT_LIBAPP + BUILT_APK.
# Returns non-zero on any failure (so we NEVER push a snapshot that would crash).
build_app() {
  copy_signing_files
  if [ -x "$TOOLING_DIR/inject-updater.sh" ] && [ -n "$APP_PACKAGE_NAME" ]; then
    bash "$TOOLING_DIR/inject-updater.sh" >/dev/null 2>&1 || { log "updater injection failed"; return 1; }
  fi
  cd "$APP_DIR" || { log "cannot cd $APP_DIR"; return 1; }
  if [ -n "$PRE_BUILD_CMD" ]; then
    log "pre-build: $PRE_BUILD_CMD"
    eval "$PRE_BUILD_CMD" || { log "pre-build command failed"; return 1; }
  fi
  log "flutter pub get…"
  "$FLUTTER_BIN" pub get || { log "pub get failed"; return 1; }
  local flavor=()
  [ -n "$BUILD_FLAVOR" ] && flavor=(--flavor "$BUILD_FLAVOR")
  log "building (release / ${BUILD_FLAVOR:-default} / $BUILD_TARGET_PLATFORM)… a few minutes"
  "$FLUTTER_BIN" build apk --release "${flavor[@]}" --target-platform "$BUILD_TARGET_PLATFORM" \
    || { log "flutter build failed"; return 1; }

  BUILT_APK=$(ls -t build/app/outputs/flutter-apk/app-*release.apk 2>/dev/null | head -1)
  [ -f "$BUILT_APK" ] || { log "APK not found after build"; return 1; }

  local work; work=$(mktemp -d)
  unzip -o -j "$BUILT_APK" "lib/$ARCH-v8a/libapp.so" -d "$work" >/dev/null 2>&1
  BUILT_LIBAPP="$work/libapp.so"
  [ -f "$BUILT_LIBAPP" ] || { log "libapp.so missing in APK"; return 1; }

  # grep -a directly on the binary (no `strings | grep -q`: grep closes the pipe
  # early -> strings dies with SIGPIPE -> pipefail false-fails the build).
  grep -a -q "$ENGINE_SNAPSHOT" "$BUILT_LIBAPP" || {
    log "snapshot mismatch (expected $ENGINE_SNAPSHOT) — would crash the app. NOT pushing."
    return 1
  }
  log "verified snapshot $ENGINE_SNAPSHOT ($(du -h "$BUILT_LIBAPP" | cut -f1))"
}

next_patch_number() {
  local maxn
  maxn=$(curl -fsS -H "Authorization: Bearer $ADMIN_TOKEN" "$DASHBOARD_URL/admin/patches" \
    | grep -o '"number":[0-9]*' | grep -o '[0-9]*' | sort -n | tail -1)
  echo $(( ${maxn:-0} + 1 ))
}

# push_patch <libapp.so> <apk> [release_version]. Sets PUSHED_NUMBER on success.
push_patch() {
  local libapp="$1" apk="$2" rel="${3:-$RELEASE_VERSION}" n
  n=$(next_patch_number)
  log "pushing patch #$n (release $rel, $ARCH)"
  local http
  http=$(curl -s -o /tmp/codepush-resp.json -w "%{http_code}" -X POST "$DASHBOARD_URL/admin/patches" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -F "patch=@$libapp" \
    -F "app_id=$APP_ID" -F "release_version=$rel" \
    -F "platform=android" -F "arch=$ARCH" -F "channel=stable" \
    -F "number=$n" -F "rollout_percentage=100")
  [ "$http" = "201" ] || { log "push failed HTTP $http: $(head -c 200 /tmp/codepush-resp.json)"; return 1; }
  if [ -n "$PATCH_STORAGE_DIR" ] && [ -d "$PATCH_STORAGE_DIR" ] && [ -f "$apk" ]; then
    cp "$apk" "$PATCH_STORAGE_DIR/${APP_ID}_${rel}_android_${ARCH}_${n}.apk" 2>/dev/null \
      && log "kept installable APK alongside the patch (sideload via dashboard)"
  fi
  PUSHED_NUMBER="$n"
  log "OK: pushed patch #$n — devices download it on next launch."
}
