# Patch how-to (operating the system)

## Find your engine snapshot hash (one time)

`ENGINE_SNAPSHOT` is the Dart snapshot-version hash baked into every
`libapp.so` built with your Flutter version. The build pipeline refuses to push
a patch whose snapshot doesn't match it, so set it once:

```bash
# Build a release APK with the SAME flutter you'll ship, then:
unzip -j build/app/outputs/flutter-apk/app-release.apk \
  lib/arm64-v8a/libapp.so -d /tmp
strings -a /tmp/libapp.so | grep -oiE '\b[0-9a-f]{32}\b' | sort | uniq -c | sort -rn | head
```

The snapshot-version hash is the 32-char hex string that stays the same across
builds of the same Flutter version and **changes when you upgrade Flutter**.
Put it in `tooling/config.env` as `ENGINE_SNAPSHOT`. If you guess wrong the push
is refused (and, had it shipped, the app would `SIGABRT`) — so it's self-checking.

## Ship a patch

```bash
cd tooling

# from a branch (resets a dedicated worktree to origin/<branch>):
./push-branch.sh my-feature-branch

# or whatever is checked out right now (uncommitted WIP ok):
./push-branch.sh --current
```

What happens: copy signing files → (optional) codegen → `pub get` → release
build → extract `libapp.so` → **verify snapshot** → upload as the next patch
number → keep the full APK alongside for sideloading. The build is rejected
before upload if the snapshot doesn't match.

Manual upload (no build pipeline) also works from the dashboard: drag a
`libapp.so` onto the upload card and set `app_id` + `release_version`.

## Verify it landed

- **Dashboard** → the active-patch card shows the new number.
- **Device** (Android logs):
  ```bash
  adb logcat -s flutter | grep inhouse-updater
  # [inhouse-updater] installed patch #7 via http://10.0.2.2:8080 -> next launch
  ```
- Relaunch the app: launch one downloads, launch two runs the patched code.

## Roll back

Dashboard → the patches table → **Roll back** on the offending patch. The check
API stops offering it; devices move to the next valid patch on their next
launch. The updater only moves forward, so also push a fixed higher patch to
supersede a bad one already on devices.

## Recover a device stuck on a crashing patch

A patch that violates the [hard rules](../README.md#hard-rules-read-this) can
crash on launch *and* be re-applied each boot. Clear the app's data to drop the
patch and boot the shipped snapshot:

```bash
adb shell pm clear <your.package.id>
```

## Troubleshooting

| Symptom | Cause → fix |
| --- | --- |
| Push refused: *"snapshot mismatch"* | Patch built with a different Flutter than installed. Use the exact `FLUTTER_BIN`; re-check `ENGINE_SNAPSHOT`. |
| App `SIGABRT`s right after a patch | Snapshot or release mismatch (shipped a bad patch). `adb shell pm clear`, then roll back + push a correct patch. |
| Patch never downloads | `release_version` in the updater ≠ the installed app's release, so the check API doesn't match. Align them. |
| Release build can't reach the server (*EPERM / "Operation not permitted"*) | Release builds lack INTERNET — the Flutter template only adds it to the debug/profile manifests. Add `<uses-permission android:name="android.permission.INTERNET"/>` to `src/main/AndroidManifest.xml` (plus `android:usesCleartextTraffic="true"` for a plain-HTTP server). |
| Patch downloads but the app keeps running old code | Built without the engine hook. The Gradle build logs `building WITHOUT the code-push hook` when `LOCAL_ENGINE_MAVEN` is unset — set it (see `engine/`). |
| `branch not found` on build | The worktree had local edits and `git checkout` refused. The scripts use `git reset --hard origin/<branch>` — make sure `WORKTREE_DIR` is a dedicated worktree, not your main clone. |
| Dashboard won't start headless (*terminal echo mode*) | `dart_frog dev` needs a TTY. `dashboard-serve.sh` auto-wraps it in `script` when run without one. |
| `dart_frog dev` fails: *Address already in use :8181* | Another `dart_frog dev` already holds the Dart VM-service port. Run `dashboard-serve.sh --prod` (compiled server, no VM service). |
| launchd job does nothing on macOS | Sandbox can't read `~/Desktop`/`~/Documents` without **Full Disk Access**. Move the repo to `~/code`, or grant `/bin/bash` Full Disk Access. |
| Device fetches over a tunnel get an HTML interstitial | ngrok's browser-warning page. The updater already sends `ngrok-skip-browser-warning`; if you use a different tunnel, disable its interstitial. |
| Emulator shows *"No Internet"* but host is online | Emulator DNS went stale. Cold-restart it with a forced DNS: `emulator -avd <name> -dns-server 8.8.8.8`. |

## When NOT to code-push (ship a full build instead)

- new or upgraded plugins / native dependencies
- new assets, fonts, or `AndroidManifest` / permission changes
- a Flutter or engine version bump
- anything touching Kotlin/Java/C++

For those, rebuild the app and update via the store — or use
`flutter/apk_updater.dart` to self-update the whole APK (the user taps the
system installer; Android requires consent for app-driven installs).
