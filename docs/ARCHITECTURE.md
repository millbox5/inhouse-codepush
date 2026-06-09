# Architecture

## The snapshot model

A Flutter **release** build for Android compiles Dart ahead-of-time into a
native shared library, `libapp.so` (the "AOT snapshot"), and bundles it inside
the APK at `lib/<abi>/libapp.so`. At launch the engine loads that library and
runs your Dart from it. There is no Dart source or kernel on the device — just
this compiled snapshot.

Code push works by getting the engine to load a **different `libapp.so`** —
one downloaded after install — instead of the one shipped in the APK.

## The engine hook

`engine/flutter-loader-hook.patch` adds ~16 lines to the engine's
`FlutterLoader.java`. In release mode the loader builds the list of engine
arguments, including `--aot-shared-library-name=<path>`. The hook inserts, just
before the default:

```java
File patchedAotLib = new File(applicationContext.getFilesDir(),
                              "inhouse_patches/libapp.so");
if (patchedAotLib.exists()) {
  shellArgs.add("--" + AOT_SHARED_LIBRARY_NAME + "=" + patchedAotLib.getAbsolutePath());
}
```

`--aot-shared-library-name` can be passed **multiple times**; the engine tries
each candidate in order and falls back to the next if one fails to load. Because
the hook adds the downloaded patch *first* and the APK's bundled library
*second*, the result is:

- **patch present + valid** → the patch runs;
- **patch missing or corrupt** → the engine silently falls back to the shipped
  snapshot. The app never bricks itself on a bad download.

This is the only engine change. It does nothing until a file appears at that
path.

## The updater flow

`flutter/inhouse_updater.dart`, called once at startup (fire-and-forget):

1. Reads the locally applied patch number from
   `<filesDir>/inhouse_patches/applied_number` (if any).
2. `POST /api/v1/patches/check` with `{app_id, release_version, platform, arch,
   channel, current_patch_number}`.
3. If the server reports a newer patch, `GET` the new `libapp.so`, write it to a
   temp file, then `rename()` it into place (atomic — the hook never sees a
   half-written file) and record the new number.
4. The patch takes effect on the **next** launch (the engine reads the file at
   startup).

The updater is host-agnostic: it tries each base URL in `_bases` in order and
uses the first that responds, downloading the patch from that same base. One
build therefore works over USB (`adb reverse`), the emulator alias
(`10.0.2.2`), and a public tunnel without rebuilding.

## Why the three rules exist

**1. Engine/snapshot must match.** The AOT snapshot's binary format is tied to a
specific Dart VM / engine build. The engine memory-maps the snapshot and jumps
into it; if the format doesn't match the running VM, you get an immediate native
abort (`SIGABRT`), not a catchable exception. The build pipeline guards this by
grepping the freshly built `libapp.so` for the installed engine's snapshot hash
(`ENGINE_SNAPSHOT`) and refusing to push on mismatch.

**2. Release version must match.** A snapshot is compiled against the rest of the
app — method channels, plugin registrations, asset keys, native symbols. Those
live in the APK, not the patch. A patch built from a different release can load
(same engine) yet crash when its Dart calls into native code or assets that
changed. So a patch targets the release **installed on the device**; the check
API matches on `release_version`. When you change releases, ship a new base APK.

**3. Dart-only changes.** Only the snapshot is replaced. Anything outside Dart —
native/Kotlin/Java, plugins, NDK libs, assets, `AndroidManifest`, the Flutter
engine version — is fixed at install time and cannot be code-pushed. Those need
a full app rebuild (store update, or the full-APK self-updater).

## Storage

**Server** (`PATCH_STORAGE_DIR`, default `server/_patches/`):

- patch artifacts named `<app>_<release>_<platform>_<arch>_<number>.so`
- optional full APKs alongside (for sideloading via the dashboard)
- `registry.json` — patch metadata, persisted so the server survives restarts

**Device** (`<app filesDir>/inhouse_patches/`):

- `libapp.so` — the currently applied patch
- `applied_number` — its patch number

## Rollback

Each patch has a number and a rolled-back flag. The server serves the highest
non-rolled-back patch for a release. Rolling back in the dashboard makes the
check API stop offering it; devices that already downloaded it keep running it
until a higher patch supersedes it (the updater only moves forward). For a
device stuck on a crashing patch, `adb shell pm clear <package>` wipes the
files dir (and the patch) so it boots the shipped snapshot again.

A boot-success handshake (auto-rollback if a patch fails to reach first frame)
is a natural next step but is **not** implemented here.
