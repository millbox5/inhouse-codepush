#!/bin/bash
# OPTIONAL convenience. Copies flutter/inhouse_updater.dart into your app and
# wires two lines into main.dart using the anchors in config.env. Idempotent.
#
# You only need this if you DON'T commit the updater into your app (e.g. you
# build patches from an upstream branch that doesn't carry it). The recommended
# path is to commit inhouse_updater.dart + the two lines once and delete this.
#
# Usage: ./inject-updater.sh   (reads APP_DIR etc. from config.env)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/config.env"
: "${APP_DIR:?set APP_DIR}" "${APP_PACKAGE_NAME:?set APP_PACKAGE_NAME}"
: "${INJECT_IMPORT_ANCHOR:?set INJECT_IMPORT_ANCHOR}" "${INJECT_CALL_ANCHOR:?set INJECT_CALL_ANCHOR}"

MAIN="$APP_DIR/${MAIN_DART:-lib/main.dart}"
SRC="$HERE/../flutter/inhouse_updater.dart"
[ -f "$MAIN" ] || { echo "main.dart not found: $MAIN" >&2; exit 1; }

# Portable in-place edit (GNU sed has --version, BSD/macOS sed does not).
sedi() { if sed --version >/dev/null 2>&1; then sed -i "$1" "$2"; else sed -i '' "$1" "$2"; fi; }

cp "$SRC" "$APP_DIR/lib/inhouse_updater.dart"
IMPORT="import 'package:$APP_PACKAGE_NAME/inhouse_updater.dart';"

grep -qF "inhouse_updater.dart" "$MAIN" \
  || sedi "s|$INJECT_IMPORT_ANCHOR|$IMPORT\n$INJECT_IMPORT_ANCHOR|" "$MAIN"
grep -qF "InhouseUpdater.check()" "$MAIN" \
  || sedi "s|$INJECT_CALL_ANCHOR|$INJECT_CALL_ANCHOR\n      InhouseUpdater.check();|" "$MAIN"

if grep -qF "inhouse_updater.dart" "$MAIN" && grep -qF "InhouseUpdater.check()" "$MAIN"; then
  echo "updater injected into $MAIN"
else
  echo "ERROR: injection failed — check INJECT_*_ANCHOR values match main.dart verbatim." >&2
  exit 1
fi
