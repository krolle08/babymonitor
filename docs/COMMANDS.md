# Command Recap — Baby Monitor Build Session (2026-07-17/18)

Every meaningful command from the build session, grouped by purpose, with what it did
and why. Windows 11 / PowerShell unless noted.

---

## 1. Environment repair (why Flutter wouldn't run)

Every `flutter` command on this machine hung forever. Root cause: the SDK lived in
`D:\Program Files\flutter`, where `bin\cache` is writable only by Administrators —
Flutter's launcher spins endlessly trying to open its startup lock file there.

```powershell
# Diagnosis
Get-CimInstance Win32_Process -Filter "name='cmd.exe'"   # found the hung flutter.bat, no dart child
icacls "D:\Program Files\flutter\bin\cache\flutter.bat.lock"  # Users have read-only → the smoking gun

# Fix: copy the SDK to a user-writable location (4.84 GB, ~2 min)
robocopy "D:\Program Files\flutter" "D:\flutter" /E /MT:16 /R:1 /W:1 /NFL /NDL /NP
# (robocopy exit code 1 = success-with-copies; 0–7 are all success)

# Point the user PATH at the new copy (old entry replaced)
$p = [Environment]::GetEnvironmentVariable('Path','User')
[Environment]::SetEnvironmentVariable('Path', ($p -replace [regex]::Escape('D:\Program Files\flutter\bin'), 'D:\flutter\bin'), 'User')

# Verify
D:\flutter\bin\flutter.bat --version   # Flutter 3.41.2 · Dart 3.11.0
```

> ⚠️ Terminals opened before the PATH change still see the broken entry — use the
> full path `D:\flutter\bin\flutter.bat` there. New terminals can use bare `flutter`.
> The stale SDK in Program Files can be deleted with admin rights whenever convenient.

---

## 2. Project scaffolding

```powershell
git init                                   # repo for the project
flutter create app --org dk.madsen --project-name babymonitor --platforms android,ios --no-pub
cd app
flutter pub add flutter_webrtc wakelock_plus flutter_local_notifications `
  web_socket_channel http shared_preferences path_provider fl_chart intl
```

- `--no-pub` skipped dependency resolution during create; `pub add` then pinned all 9
  runtime packages (88 total with transitive) in one resolve.

---

## 3. Server (Node.js — signaling + sleep-log REST)

```powershell
cd server
npm install                                # only dependency: ws (SQLite is Node-builtin node:sqlite)
node --test                                # run all 31 tests (run from server/ — see note)
$env:FAMILY_TOKEN = "pick-a-long-secret"; node src/index.js   # run locally on :8080

# quick probes
curl http://localhost:8080/healthz         # unauthenticated liveness
```

> Windows quirk: `node --test test/` (directory argument) fails on Node 24 for
> Windows paths. Plain `node --test` from `server/` — or the package script
> `npm test` (`node --test "test/*.test.js"`) — runs the same files.

---

## 4. App (Flutter)

```powershell
cd app
D:\flutter\bin\flutter.bat analyze         # static analysis → "No issues found!"
D:\flutter\bin\flutter.bat test            # all 61 tests (56 core + 5 widget)
D:\flutter\bin\flutter.bat test test\core  # core domain suite only
D:\flutter\bin\flutter.bat build apk --debug   # → app\build\app\outputs\flutter-apk\app-debug.apk
D:\flutter\bin\flutter.bat run             # run on a connected phone (pick device)
D:\flutter\bin\flutter.bat devices         # list connected phones/emulators
```

- The first APK build failed: `flutter_local_notifications` needs **core library
  desugaring**. Fixed in `app/android/app/build.gradle.kts`
  (`isCoreLibraryDesugaringEnabled = true` + `desugar_jdk_libs:2.1.4`); after that the
  debug APK builds (~183 MB debug; release will be far smaller).
- Gradle auto-installed Build-Tools 35 / Platforms 35+36 on first build.

---

## 5. Deployment (Fly.io — one deploy runs signaling + REST + SQLite)

```powershell
cd server
fly launch --no-deploy            # create the app from fly.toml (name: babymonitor-server)
fly volumes create data --size 1  # persistent volume for the SQLite file (/data)
fly secrets set FAMILY_TOKEN=pick-a-long-secret
fly secrets set TURN_URL=turns:... TURN_USERNAME=... TURN_CREDENTIAL=...   # Cloudflare TURN (optional but recommended)
fly deploy
```

Then in the app's **Settings** screen on every phone:
- Signaling URL: `wss://babymonitor-server.fly.dev/ws`
- API base URL: `https://babymonitor-server.fly.dev`
- Family token: the same secret

TURN credentials: Cloudflare dashboard → Calls → TURN keys (see `server/README.md`).
Served to the apps at runtime via `GET /api/ice-config`, so no secrets ship in the APK.

---

## 6. Git

```powershell
git add -A
git commit -m "..."               # 3 commits: docs → scaffold+contracts → implementation
git log --oneline
```

---

## 7. Watching the build (extras from this session)

```powershell
# Custom live dashboard (zero-dep Node script in the session scratchpad) → http://localhost:5599
node "<scratchpad>\agent-dashboard.mjs"

# Pixel Agents — animated pixel-art office of your Claude Code agents
code --install-extension pablodelucca.pixel-agents    # VS Code extension (the canonical distribution)
npx it-crowd-pixel-agents --port 3100                  # community fork with a working CLI (npm 'pixel-agents' package ships no executable)
```

---

## 8. Day-to-day cheatsheet

| I want to… | Command |
|---|---|
| Run the app on a phone | `cd app && flutter run` |
| Build an installable APK | `cd app && flutter build apk --release` |
| Run all app tests | `cd app && flutter test` |
| Run server tests | `cd server && npm test` |
| Run the server locally | `cd server && $env:FAMILY_TOKEN="…"; node src/index.js` |
| Deploy server changes | `cd server && fly deploy` |
| Check server health | `curl https://babymonitor-server.fly.dev/healthz` |
| Static analysis | `cd app && flutter analyze` |
