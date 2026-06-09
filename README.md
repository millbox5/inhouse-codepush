# In-House Code Push

A **self-hosted over-the-air (OTA) code-push system for Flutter (Android)** —
ship Dart changes to installed apps without a Play Store release. It's a
do-it-yourself alternative to Shorebird/CodePush: you run the dashboard, you
patch the engine, you own every byte.

> **Status:** works end-to-end (emulator + real devices). Android-only.
> Self-hosted and dependency-light. Read the **[Hard rules](#hard-rules-read-this)**
> before shipping — a patch built against the wrong engine or release will crash.

---

## How it works

A Flutter Android *release* build compiles your Dart to a native AOT snapshot,
`libapp.so`, baked into the APK. This project lets the engine load a **newer
`libapp.so` downloaded at runtime** instead.

```
  ┌────────────┐   build & push    ┌─────────────────┐
  │  your app  │  ───────────────► │  dashboard /    │   tooling/push-branch.sh
  │  (a branch)│                   │  server (Dart   │   builds libapp.so, gates on
  └────────────┘                   │  Frog)          │   the engine snapshot, uploads
                                   └────────┬────────┘
                                            │ GET /api/v1/patches/check
                                            │ GET /libapp.so
                                   ┌────────▼────────┐
   on next launch the patched     │  installed app  │  inhouse_updater.dart asks
   engine loads the downloaded    │  on the device  │  "newer patch?", downloads the
   libapp.so instead of the       └─────────────────┘  new libapp.so to the app's
   one shipped in the APK                               files dir (atomic write)
```

Three pieces make that happen:

1. **The engine hook** (`engine/flutter-loader-hook.patch`) — ~16 lines added to
   the engine's `FlutterLoader.java`. Before loading the APK's bundled snapshot,
   it checks for `<filesDir>/inhouse_patches/libapp.so` and, if present, registers
   it as the **first** AOT library candidate. The engine tries candidates in order
   and falls back, so a missing or corrupt patch is safe — the app just runs its
   shipped code.
2. **The in-app updater** (`flutter/inhouse_updater.dart`) — fire-and-forget at
   startup. Calls the dashboard's check API; if a newer patch exists, downloads
   the new `libapp.so` into the app's files dir. Takes effect on the next launch.
3. **The dashboard + tooling** (`server/`, `tooling/`) — a Dart Frog server with a
   web dashboard (upload a patch, pick a branch to build, roll back, download the
   APK) plus scripts that build your app into a snapshot and push it.

---

## Repository layout

| Path | What's in it |
| --- | --- |
| `server/` | Dart Frog dashboard + API. Serves `/libapp.so`, the check API, `/admin/*`, branch picker, `/latest` APK manifest. |
| `flutter/` | Drop-in for **your** app: `inhouse_updater.dart` (code-push) and `apk_updater.dart` (optional full-APK self-update). |
| `engine/` | The engine hook: `flutter-loader-hook.patch` + a Dockerized `build-engine.sh` for building a patched engine. |
| `tooling/` | `config.env`-driven scripts: `dashboard-serve.sh`, `push-branch.sh`, `autopatch.sh`, launchd templates. |
| `example/` | A runnable stock-Flutter demo wired for code push — proves the loop end-to-end. See [`example/README.md`](example/README.md). |
| `docs/` | [`ARCHITECTURE.md`](docs/ARCHITECTURE.md) (deep dive) and [`PATCH-HOWTO.md`](docs/PATCH-HOWTO.md) (operate it). |
| `.env.example` | The server's environment contract. |

---

## Requirements

- **Flutter SDK** pinned to a single version for your app + engine (e.g. via
  [`fvm`](https://fvm.app)). The patched engine and every patch must use the
  **same** version.
- **Dart Frog CLI** for the server: `dart pub global activate dart_frog_cli`.
- **Android SDK + a release signing config** for your app.
- A way to reach the server from the device: USB (`adb reverse`), LAN IP, or a
  tunnel (ngrok / cloudflared / your domain).

---

## Quickstart

### 1. Patch the engine (one time, per Flutter version)

The hook lives in `engine/flutter-loader-hook.patch`. Two ways to apply it:

- **Jar-swap (fast, no full engine build).** Compile the patched
  `FlutterLoader.java` into a jar and override the embedding via a local Maven
  repo in your app's `android/build.gradle`. See
  [`engine/UPSTREAM-ENGINE-NOTES.md`](engine/UPSTREAM-ENGINE-NOTES.md).
- **Full engine build (proper, heavier).** `engine/build-engine.sh` +
  `engine/Dockerfile` check out the engine at your Flutter revision, apply the
  patch, and build the artifacts.

> The patched engine changes **only** the loader's fallback order — it has no
> effect until a patch file actually exists on the device.

### 2. Add the updater to your app

Copy `flutter/inhouse_updater.dart` into your app, set the three constants at
the top (`_bases`, `_appId`, `_releaseVersion`), and call it once early in
`main()`:

```dart
import 'package:your_app/inhouse_updater.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  InhouseUpdater.check();   // fire-and-forget; never blocks the first frame
  runApp(const MyApp());
}
```

(Prefer not to commit it? `tooling/inject-updater.sh` wires it in at build time.)

### 3. Run the dashboard

```bash
cd tooling
cp config.env.example config.env     # fill in FLUTTER_BIN, APP_ID, ENGINE_SNAPSHOT, paths…
./dashboard-serve.sh                 # http://localhost:8080
```

Open <http://localhost:8080> — upload a patch by hand, or use the branch picker.

### 4. Build & ship a patch

```bash
cd tooling
./push-branch.sh my-feature-branch   # build that branch and push it
# or build whatever is checked out:
./push-branch.sh --current
```

Relaunch the app twice: launch one downloads the patch, launch two runs it.
To do this automatically on every branch change, schedule `autopatch.sh`
(see [`tooling/README.md`](tooling/README.md)).

---

## Hard rules (read this)

Code push replaces Dart, nothing else. Three constraints are **non-negotiable** —
break them and the app crashes (recover a stuck device with `adb shell pm clear`):

1. **Engine/snapshot must match.** A patch must be built with the **exact** same
   Flutter/engine version as the installed app. The Dart snapshot format is
   version-specific; a mismatch is an immediate `SIGABRT`. `push-branch.sh`
   refuses to push unless the built `libapp.so` contains your `ENGINE_SNAPSHOT`.
2. **Release version must match.** A patch's `release_version` must equal the
   release **installed on the device** — not necessarily the branch's pubspec
   version. A patch built against a different release may load but crash at
   runtime (native/asset ABI drift). Bump the base app + reinstall when you
   change releases.
3. **Dart-only changes.** Business logic, UI, bug fixes — yes. Native code,
   new/updated plugins, new assets, or a Flutter version bump — **no**; those
   need a full app rebuild and store update (or the full-APK self-updater in
   `flutter/apk_updater.dart`).

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the why.

---

## Configuration

Everything is environment-driven — no code edits to deploy.

- **Server:** [`.env.example`](.env.example) — `ADMIN_TOKEN`, `PUBLIC_BASE_URL`,
  `PATCH_STORAGE_DIR`, `CODEPUSH_APP_ID`, `CODEPUSH_RELEASE_VERSION`,
  `PATCH_PRIVATE_KEY_PATH`, branch-picker hooks.
- **Tooling:** [`tooling/config.env.example`](tooling/config.env.example) — one
  file the build scripts read: `FLUTTER_BIN`, `ENGINE_SNAPSHOT`, `APP_DIR`,
  `WORKTREE_DIR`, build flavor, signing files, dashboard URL + token.

For local dev, `dashboard-serve.sh` reads `tooling/config.env` and exports the
server vars for you, so you only edit one file.

---

## Security

This system lets a server replace the executable Dart in your app. Treat it
accordingly:

- **Use TLS** for `PUBLIC_BASE_URL`. Anyone who can MITM the download or write
  the patch dir can run arbitrary code in your app.
- **Enable patch signing** (`PATCH_PRIVATE_KEY_PATH`) and verify signatures in
  the updater before trusting a download.
- **Guard `/admin`** with a strong, rotated `ADMIN_TOKEN`. Never expose the admin
  surface to the public internet unprotected. A tunnel (ngrok/cloudflared) is
  fine for testing but publishes your dashboard — lock it down for production.
- **Never commit** `config.env`, `.env`, signing keys, or tokens (`.gitignore`
  already excludes them).

## Policy

This is a technical tool. Make sure your OTA update mechanism complies with the
policies of the stores you ship under (e.g. Google Play's rules on runtime code).
Not legal advice.

## Acknowledgements

Inspired by [Shorebird](https://shorebird.dev) and Microsoft CodePush. Built on
[Dart Frog](https://dartfrog.vgv.dev). The engine hook patches Flutter's own
`FlutterLoader`.

## License

[MIT](LICENSE).
