#!/bin/bash
# Run the dashboard (Dart Frog dev server) with config from config.env.
#
# `dart_frog dev` wants a TTY (it toggles terminal echo for hot-reload keys), so
# when launched headless (launchd/cron) we wrap it in `script`, which allocates a
# pseudo-TTY. `dev` runs in place — unlike `dart_frog build` it does NOT bundle
# the project directory, so it can't accidentally fill your disk.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/config.env"

cd "${SERVER_DIR:?set SERVER_DIR in config.env}" || exit 1
PORT="${SERVER_PORT:-8080}"

# Hand the server its configuration via the environment it reads (see
# server/lib/src/config/env.dart).
export PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-http://10.0.2.2:$PORT}"
export ADMIN_TOKEN="${ADMIN_TOKEN:?set ADMIN_TOKEN}"
export PATCH_STORAGE_DIR
export CODEPUSH_APP_ID="$APP_ID"
export CODEPUSH_RELEASE_VERSION="$RELEASE_VERSION"
export PUSH_BRANCH_SCRIPT="$HERE/push-branch.sh"
export WORKTREE_DIR

command -v dart_frog >/dev/null 2>&1 || {
  echo "dart_frog not found. Install it: dart pub global activate dart_frog_cli" >&2
  exit 1
}

echo "[dashboard] http://localhost:$PORT  (public: $PUBLIC_BASE_URL)"
if [ -t 0 ]; then
  exec dart_frog dev --port "$PORT"
else
  exec script -q /dev/null dart_frog dev --port "$PORT"
fi
