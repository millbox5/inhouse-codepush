# Example — a stock Flutter app with code push

A vanilla `flutter create` counter app wired for in-house code push, so you can
watch a patch land end-to-end. The home screen shows a build label + color in
`lib/main.dart`; change them, push a patch, and watch the banner flip — no
reinstall, no store.

## What's wired (and where)

| Piece | File |
| --- | --- |
| Updater (checks + downloads patches at startup) | `lib/inhouse_updater.dart`, called from `lib/main.dart` |
| Engine hook (jar-swap) | `android/build.gradle.kts` — reads the `LOCAL_ENGINE_MAVEN` env var |
| INTERNET + cleartext (release builds need these!) | `android/app/src/main/AndroidManifest.xml` |
| `path_provider` (writes the patch into the files dir) | `pubspec.yaml` |

## Run the demo

Build with the **same Flutter version as your hook'd engine** (here, 3.35.2).

```bash
# 1. Configure ../tooling/config.env: FLUTTER_BIN, ENGINE_SNAPSHOT,
#    LOCAL_ENGINE_MAVEN, APP_DIR (= this dir), DASHBOARD_URL, etc.

# 2. Serve the dashboard
( cd ../tooling && ./dashboard-serve.sh )          # http://localhost:8080

# 3. Build + install the baseline (v1)
LOCAL_ENGINE_MAVEN=/path/to/local-engine-maven \
  ~/fvm/versions/3.35.2/bin/flutter build apk --release --target-platform android-arm64
adb install -r build/app/outputs/flutter-apk/app-release.apk

# 4. Ship a patch: edit kBuildLabel / kBuildColor in lib/main.dart, then
( cd ../tooling && ./push-branch.sh --current )

# 5. Reopen the app twice — launch one downloads, launch two runs it. Banner flips.
```

> **No hook = silent no-op.** Without `LOCAL_ENGINE_MAVEN` the app still builds,
> but with the stock engine — downloaded patches are ignored and the Gradle
> build prints `building WITHOUT the code-push hook`. The hook'd jar is
> engine-version-specific; see [`../engine/`](../engine).
