# Baby Monitor

Turn two phones into a reliable baby monitor. One old phone is the **camera unit**
pointed at the crib; mom's and dad's phones are **parent units** watching the same
live feed. Built to be honest about its own health — a silent failure is worse than
an alert (spec NTR1).

## Repo layout

| Path | What |
|---|---|
| `app/` | Flutter app (Android + iOS) — both roles in one codebase, role picker on launch |
| `server/` | Node.js signaling (WebSocket) + sleep-log REST API (SQLite) — one Fly.io deploy |
| `spec.md` | Feature specs F1–F7, technical + non-technical requirements, acceptance tests |
| `docs/SPEC-ADDENDUM.md` | F8 multi-parent, F9 sleep-history logging, F10 flags ("Teething"…) |
| `docs/PROTOCOL.md` | **Binding wire contract**: signaling messages, REST API, module APIs |
| `babymonitor-architecture.html` | Architecture diagram (open in a browser) |

## How it works

- **Streaming:** WebRTC via `flutter_webrtc`. P2P (STUN) first, Cloudflare TURN relay
  as automatic fallback. Camera creates one peer connection per parent (max 4).
- **Pairing:** camera shows a 6-character room code; parents type it. No accounts.
- **Health:** camera sends a heartbeat every 3 s over a data channel. Parent runs a
  pure-Dart FSM: `CONNECTED → DEGRADED → RECONNECTING → FROZEN/FAILED`, with
  exponential backoff reconnect (3/6/12/30 s) and freeze detection from decoded-frame
  stats.
- **Sleep history:** the camera logs sessions + events (noise, reconnects, freezes,
  latency) to the server through an offline-safe queue. Parents browse history and
  flag dates with reasons like *Teething* or *Sick*.

## Quick start

### Server
```powershell
cd server
npm install
$env:FAMILY_TOKEN = "pick-a-long-secret"; node src/index.js
# tests:
node --test test/
```
Deploy: see `server/README.md` (Fly.io + Cloudflare TURN credentials).

### App
```powershell
cd app
flutter pub get
flutter run    # pick role on first launch
```
Point Settings → Server at your server URL (`wss://…/ws` + `https://…`) and enter the
same family token.

### Tests
```powershell
cd app; flutter test          # core FSM/backoff/freeze/noise + widget smoke tests
cd server; node --test test/  # signaling + REST API
```
