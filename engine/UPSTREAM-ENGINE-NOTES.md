# In-house Code Push — Hosting & Production Pipeline

This is the production path for shipping our custom-engine code-push system. It
has four pieces:

| Piece | What | Where |
| --- | --- | --- |
| **Custom engine** | Stock Flutter engine + our `FlutterLoader` hook (loads a downloaded `libapp.so`) | built here, on Linux |
| **Hosting** | The hook'd engine artifacts, served to app builds | internal Maven repo |
| **Backend** | Serves patches to devices (`/api/v1/patches/check` + storage) | the Dart Frog server in repo root |
| **Updater** | In-app: downloads the patch to the app's files dir | Dart code in the app |

> **Scope:** Android (proven end-to-end). iOS needs a Dart interpreter (the one
> piece Shorebird keeps private) and is deferred.

---

## Why build on Linux

The engine must be built **at the exact Flutter version the app uses** (e.g.
3.35.2). Building a ~year-old engine on a brand-new macOS/Xcode SDK fails
(deprecation-as-error, swift-testing macro plugins). **Linux cross-compiles the
Android engine cleanly** and is what Flutter/Shorebird CI actually use. So the
engine build belongs in CI/Docker, not on a dev Mac.

---

## 1. Build the hook'd engine (per Flutter version)

```bash
# from repo root
docker build -t inhouse-engine-builder hosting/
docker run --rm \
  -v "$PWD/hosting:/work" \
  -v "$PWD/engine-artifacts:/artifacts" \
  inhouse-engine-builder <flutter-framework-rev>      # e.g. 05db9689… for 3.35.2
```

Outputs to `engine-artifacts/`:
- **`flutter_embedding_release.jar`** ← the only artifact that carries our hook
- `libflutter-arm64-release.so`, `arm64_v8a_release.jar` (native; identical to stock)
- `ENGINE_VERSION.txt` (the `1.0.0-<hash>` maven coordinate to publish under)

The hook itself is `hosting/flutter-loader-hook.patch` (applied by the build).

> **Pin per version.** Each Flutter version the app ships on needs its own engine
> build. Re-run with that version's rev. This is the ongoing maintenance cost of
> owning a fork — keep it in CI and trigger on Flutter bumps.

---

## 2. Host the artifacts (internal Maven repo)

Because our hook is **Java-only**, you only need to override **one** artifact:
`io.flutter:flutter_embedding_release`. Everything else (native `.so`, host
tooling) comes from stock `download.flutter.io`.

Publish the hook'd jar to an internal Maven repo (Artifactory / Nexus / GCS /
S3-static), at the **same coordinate** as the stock one so the POM's transitive
deps are reused:

```
<your-maven>/io/flutter/flutter_embedding_release/1.0.0-<ENGINE_VERSION>/
    flutter_embedding_release-1.0.0-<ENGINE_VERSION>.jar     # ours (with hook)
    flutter_embedding_release-1.0.0-<ENGINE_VERSION>.pom     # copy of the stock POM
```

(Grab the stock POM from
`https://storage.googleapis.com/download.flutter.io/io/flutter/flutter_embedding_release/1.0.0-<hash>/…pom`.)

For a quick local proof this is just a directory — see `local-engine-maven/` in
the repo root, which is exactly this layout.

---

## 3. Consume it in the app (Gradle override — verified)

Add the repo **first** in the app's `android/build.gradle` so it shadows
`download.flutter.io` for that one artifact:

```groovy
allprojects {
    repositories {
        maven { url 'https://your-internal-maven' }   // or file path for local
        google()
        mavenCentral()
    }
}
```

That's it — `flutter build apk --release` then bundles our hook'd embedding while
pulling native libs + host tooling from stock. No `--local-engine`, no engine on
the dev machine. (This is the exact mechanism proven locally against
`local-engine-maven/`.)

---

## 4. Runtime — deliver patches (backend + updater)

- **Backend** (`../` Dart Frog server): `POST /api/v1/patches/check` returns
  `{patch_available, patch:{number, hash, download_url, hash_signature}}`; the
  patch file (a release `libapp.so`, later a binary diff) is served from object
  storage / CDN. Swap the in-memory store for Postgres and local disk for R2/S3
  (see `lib/src/dependencies.dart`).
- **Updater** (in-app Dart): on launch, calls `/check`, downloads the patch to
  `<filesDir>/inhouse_patches/libapp.so`, verifies `hash` (+ signature), and the
  engine hook loads it on the **next** launch. Package this as a small Dart
  helper (replace the hardcoded paths from the PoC with `path_provider`).

### Producing a patch (per release)
1. Build the release app (baseline) → archive its `libapp.so`.
2. Change Dart → rebuild → new `libapp.so` (built with the **same** engine/version).
3. Upload to the backend (`POST /admin/patches`), sign it, mark the rollout.
4. Devices on that release download it on next `/check` and apply on relaunch.

> Today a "patch" is the full `libapp.so` (a few MB). Optimization: ship a binary
> diff against the baseline and reconstruct on-device (smaller downloads).

---

## Production hardening checklist
- **Sign every patch** (RSA-2048; the backend supports it). Embed the public key
  in the release; the updater rejects unsigned/tampered patches.
- **Rollback / kill-switch:** the backend's `rolled_back_patch_numbers` +
  boot-success tracking (revert if a patch fails to boot).
- **Reproducible builds:** pin `pubspec.lock` and the engine version per release
  so a patch's baseline is byte-identical (non-determinism silently breaks patches).
- **Store policy:** code push = Dart/asset fixes only. Native/plugin/Flutter-version
  changes still require a Play Store release.
