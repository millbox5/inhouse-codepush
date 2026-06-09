#!/usr/bin/env bash
# Build the in-house custom Flutter engine for Android, at a pinned Flutter
# version, with the code-push hook applied. Designed to run on LINUX (CI/Docker)
# — Linux cross-compiles the Android engine cleanly and avoids the macOS-SDK /
# Xcode-version incompatibilities you hit building an older engine on a new Mac.
#
# Usage:  build-engine.sh <flutter-framework-rev>
#   e.g.  build-engine.sh 05db9689081f091050f01aed79f04dce0c750154   # Flutter 3.35.2
#
# Find the rev for your app's Flutter version:
#   <flutter-sdk>/bin/internal/engine.version   (engine artifact hash)
#   OR the framework commit the app's CI uses (app/.metadata / CI flutter-version).
set -euo pipefail

FLUTTER_REV="${1:?usage: build-engine.sh <flutter-framework-rev>}"
HOOK="${HOOK_PATCH:-/work/flutter-loader-hook.patch}"
SRC=/work/engine
ART=/artifacts

export PATH="/opt/depot_tools:${PATH}"

echo "==> [1/5] gclient checkout of flutter/flutter @ ${FLUTTER_REV}"
mkdir -p "$SRC" && cd "$SRC"
cat > .gclient <<EOF
solutions = [
  { "name": ".", "url": "https://github.com/flutter/flutter.git",
    "deps_file": "DEPS", "managed": False, "custom_deps": {}, "custom_vars": {} },
]
EOF
gclient sync -D --no-history --revision "@${FLUTTER_REV}"

echo "==> [2/5] apply in-house code-push hook"
# Hook lives in FlutterLoader.java (AOT branch): load a downloaded libapp.so
# from <filesDir>/inhouse_patches/ first, falling back to the bundled one.
git apply "$HOOK" || patch -p1 < "$HOOK"

echo "==> [3/5] build Android release engine (+ Linux host tooling)"
export PATH="$SRC/engine/src/flutter/bin:$PATH"
# On Linux these build cleanly with no test/SDK hacks needed.
et build -c android_release_arm64
et build -c host_release          # frontend_server + flutter_patched_sdk_product
# Add more target ABIs/modes as needed, e.g.:
#   et build -c android_release_arm    (armeabi-v7a)
#   et build -c android_profile_arm64

echo "==> [4/5] collect artifacts"
OUT="$SRC/engine/src/out"
mkdir -p "$ART"
cp "$OUT/android_release_arm64/flutter_embedding_release.jar" "$ART/"   # <-- contains the hook
cp "$OUT/android_release_arm64/arm64_v8a_release.jar"        "$ART/" 2>/dev/null || true
cp "$OUT/android_release_arm64/libflutter.so"                "$ART/libflutter-arm64-release.so" 2>/dev/null || true
# Record the engine hash for the maven coordinate (1.0.0-<engineHash>).
( cd "$SRC" && git rev-parse HEAD ) > "$ART/FRAMEWORK_REV.txt"
cat "$SRC/bin/internal/engine.version" > "$ART/ENGINE_VERSION.txt" 2>/dev/null || true

echo "==> [5/5] done. Artifacts in $ART:"
ls -lah "$ART"
echo "Next: publish flutter_embedding_release.jar to your internal maven repo at"
echo "  io/flutter/flutter_embedding_release/1.0.0-<ENGINE_VERSION>/  (see hosting/README.md)"
