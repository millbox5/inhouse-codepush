#!/bin/bash
# Run the dashboard with config from config.env.
#   ./dashboard-serve.sh          dart_frog dev (hot reload) — the usual choice
#   ./dashboard-serve.sh --prod   compiled server: no Dart VM-service port, so it
#                                 runs alongside another dart_frog dev, and is how
#                                 you'd deploy it.
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/config.env"

cd "${SERVER_DIR:?set SERVER_DIR in config.env}" || exit 1
PORT="${SERVER_PORT:-8080}"

# Hand the server its configuration via the environment it reads (see
# server/lib/src/config/env.dart). PORT is read by the production server.
export PORT
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

# --prod: compiled production server (no Dart VM-service port, so it can run
# alongside another `dart_frog dev`; also how you'd deploy).
if [ "$1" = "--prod" ]; then
  dart_frog build || exit 1
  exec dart build/bin/server.dart
fi

# dev mode needs a TTY (terminal echo for hot-reload keys); wrap in `script`
# when launched headless (launchd/cron).
if [ -t 0 ]; then
  exec dart_frog dev --port "$PORT"
else
  exec script -q -e -c "dart_frog dev --port $PORT" /dev/null
fi
