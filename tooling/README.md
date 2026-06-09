# Tooling — build & push patches

Scripts that build your app into a Dart snapshot and push it to the dashboard.
All of them read **one file**: `config.env` (copy it from `config.env.example`).

```bash
cp config.env.example config.env
$EDITOR config.env            # set FLUTTER_BIN, APP_ID, ENGINE_SNAPSHOT, paths…
chmod +x *.sh
```

| Script | What it does |
| --- | --- |
| `dashboard-serve.sh` | Runs the dashboard server (`server/`) with config from `config.env`. |
| `push-branch.sh <branch>` | Builds a branch (or `--current`) and pushes it as the next patch. The dashboard's branch picker calls this. |
| `autopatch.sh` | Scheduled watcher: when `WATCH_BRANCH` moves, builds + pushes a patch. No-op when nothing changed. |
| `inject-updater.sh` | *Optional.* Wires `inhouse_updater.dart` into `main.dart` at build time (only if you don't commit it into the app). |
| `codepush-lib.sh` | Shared functions (build + verify snapshot + push). Sourced by the others. |

## Typical use

```bash
# 1. start the dashboard (one terminal)
./dashboard-serve.sh

# 2. ship a patch from a branch (another terminal)
./push-branch.sh my-feature-branch
#    …or build whatever is checked out right now:
./push-branch.sh --current
```

Every build is gated on `ENGINE_SNAPSHOT`: if the freshly built `libapp.so`
doesn't contain your installed engine's snapshot hash, the push is **refused**
(loading it would crash the app). See `../docs/PATCH-HOWTO.md`.

## Run it automatically (macOS launchd)

```bash
# replace __REPO__ with this repo's absolute path, then install both agents
sed "s|__REPO__|$(cd .. && pwd)|g" launchd/com.inhouse.codepush.dashboard.plist \
  > ~/Library/LaunchAgents/com.inhouse.codepush.dashboard.plist
sed "s|__REPO__|$(cd .. && pwd)|g" launchd/com.inhouse.codepush.autopatch.plist \
  > ~/Library/LaunchAgents/com.inhouse.codepush.autopatch.plist
launchctl load ~/Library/LaunchAgents/com.inhouse.codepush.dashboard.plist
launchctl load ~/Library/LaunchAgents/com.inhouse.codepush.autopatch.plist
```

> **macOS gotcha:** launchd jobs run under a sandbox that can't read
> `~/Desktop`, `~/Documents`, or `~/Downloads` without **Full Disk Access**.
> Either keep this repo + your worktree elsewhere (e.g. `~/code`), or grant
> Full Disk Access to `/bin/bash` in System Settings → Privacy & Security.

**Linux/cron alternative** (hourly autopatch):

```cron
0 * * * * /bin/bash /abs/path/inhouse-codepush/tooling/autopatch.sh
```

Logs and state live in `tooling/.state/` (gitignored).
