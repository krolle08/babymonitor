# Spec Addendum — v0.1.1

Extends `spec.md` with owner-requested features confirmed 2026-07-17. Same conventions.

---

## F8 — Multi-Parent Viewing

**Purpose:** Both mom and dad have a parent unit that can watch the same camera feed
simultaneously.

**Behaviour:**
- Camera device maintains one `RTCPeerConnection` per joined parent (max 4)
- Each parent joins with the same 6-char room code
- A parent joining/leaving must not interrupt other parents' streams
- Health FSM runs independently per parent device

**Acceptance criteria:**
- [ ] Two parents stream the same camera concurrently, each <10s to connect on WiFi
- [ ] Parent B joining does not glitch parent A's stream
- [ ] Parent B leaving does not affect parent A
- [ ] Push-to-talk from either parent reaches the camera speaker

*Deviation note:* `spec.md` scopes v0.1 to "one camera, one parent"; multi-parent is a
confirmed owner requirement and is in scope. NTR6 already required it not be blocked.

---

## F9 — Sleep History Logging

**Purpose:** Track sleep history over time on a backend, so parents can see how the
baby slept and correlate bad nights with real-world causes.

**Behaviour:**
- Camera device logs a **session** (start/end) for every monitoring run
- During a session, events are logged: noise (with level), health-state transitions,
  freezes, reconnects, measured latency
- Events are queued on-device (JSON file) and uploaded in batches; upload failure never
  affects the stream (NTR3) — queue drains when connectivity returns
- Parent app shows a **History** screen: per-night timeline, noise-event bars,
  session durations

**Acceptance criteria:**
- [ ] Session appears in history within 60s of camera session start (when online)
- [ ] Events logged offline are delivered after connectivity returns — none lost
- [ ] History renders 30 days of sessions without jank
- [ ] Logging failure is invisible to the live stream (no crash, no stall)

---

## F10 — Sleep Flags

**Purpose:** Annotate why a period of sleep was off — e.g. **"Teething"**, "Sick",
"Travel" — so patterns in the history make sense later.

**Behaviour:**
- From the History screen, a parent adds a flag to any date
- Flag = date + label + optional note; suggested labels offered, free text allowed
- Flags from either parent are visible to both (stored on the backend)
- Flags render inline on the history timeline

**Acceptance criteria:**
- [ ] Flag added on parent A's phone visible on parent B's history after refresh
- [ ] Flag can be deleted
- [ ] Suggested labels: Teething, Sick, Vaccination, Travel, Growth spurt, New routine

---

## F11 — LAN-Autonomous Pairing & Streaming

**Purpose:** At home (or on a phone hotspot when traveling), establishing and healing
the monitor link must need **no internet and no cloud server**. WiFi router (or
hotspot) on = monitor works.

**Behaviour:**
- The camera app hosts its own signaling endpoint on the local network
  (`ws://<camera-ip>:47800/ws`, PROTOCOL §7) and advertises it via mDNS
  (`_babymonitor._tcp`)
- Parent devices connect LAN-first on every connect **and every reconnect attempt**:
  last-known LAN address → mDNS discovery → cloud fallback
- Same wire protocol on both transports — the app's session logic cannot tell them apart
- Works on: home WiFi, travel hotspot (camera tethered to a parent's phone), any
  network where the devices share a subnet

**Acceptance criteria:**
- [ ] With the internet down (router offline from WAN), a trusted parent pairs to the
      stream in <10 s on shared WiFi
- [ ] Mid-session WiFi blip heals via LAN with no cloud reachable
- [ ] Camera start does not wait for cloud connectivity (see NTR7)
- [ ] Hotspot topology (camera tethered to parent phone) streams without internet
- [ ] Remote (different networks) still works via cloud signaling + TURN

---

## F12 — Trusted Devices (Key-Based Pairing)

**Purpose:** Two devices add each other as trusted **once** (QR ceremony); every later
connection authenticates silently with device keys. No typing codes at bedtime, and
not even the signaling server has to be trusted.

**Behaviour:**
- Each install generates an Ed25519 keypair; private key in Android
  Keystore / iOS Keychain, never leaves the device (PROTOCOL §8)
- Pairing: camera shows a QR (public key + one-time 5-min token); parent scans and
  proves possession over the LAN link; both sides store each other in a trust list
- Every session: mutual challenge–response signatures before any offer is sent
  (PROTOCOL §8.2) — a stolen room code or a compromised relay is not enough to watch
- Trust management UI: list ("Mom's phone", "Dad's phone"), rename, revoke; revoked
  devices are rejected on next auth and dropped if live
- Camera-identity mismatch on the parent (key changed) → hard alert, re-pair required
- Guest bootstrap (room-code join without keys) remains available behind a camera
  setting, default on (NTR2)

**Acceptance criteria:**
- [ ] Pairing ceremony completes in <60 s (NTR2), entirely offline on LAN
- [ ] Paired parent connects with zero input: open app → tap camera → watching
- [ ] Unknown device joining with a stale/guessed room code while code-joins are
      disabled is rejected (`NOT_TRUSTED`)
- [ ] Revoking a device prevents its next connection and drops it if currently live
- [ ] Parent alerts loudly if the camera's key changes (MITM/reinstall detection)
- [ ] Pairing messages are never relayed by the cloud server

---

## TR7 — Backend storage

- The signaling server also hosts the REST API (one Fly.io deploy)
- SQLite via Node's built-in `node:sqlite` (`DatabaseSync`, Node ≥ 22.5 — no native build); file path via `DB_PATH` env var (Fly volume)
- Shared-secret `FAMILY_TOKEN` bearer auth — no accounts (NTR2), no media stored (NTR4)
- Full wire contract: `docs/PROTOCOL.md`

## TR8 — Platforms (confirmed)

- Camera role: Android (the old phone), min API 26
- Parent role: Android **and** iOS (min iOS 14)
- Single Flutter codebase with a role picker on first launch

## TR9 — Identity, discovery & crypto stack (F11/F12)

| Concern | Choice |
|---|---|
| Signatures | Ed25519 via `cryptography` (Dart) |
| Private-key storage | `flutter_secure_storage` (Keystore / Keychain) |
| mDNS advertise + discovery | `bonsoir` (`_babymonitor._tcp`, TXT: id/name/proto/port) |
| QR render / scan | `qr_flutter` / `mobile_scanner` |
| LAN signaling endpoint | `dart:io` `HttpServer` + WebSocket upgrade in the camera app, port 47800 (dynamic fallback) |
| Cloud relay additions | `auth-challenge`/`auth-response` relayed like offer/answer (Node + Java servers); `pair-*` never relayed |
| iOS entitlements | `NSLocalNetworkUsageDescription` + `NSBonjourServices: [_babymonitor._tcp]` in Info.plist |

## NTR7 — Monitoring is the golden path; the server is never a dependency

The primary task — **monitoring** (capture → stream → watch → auto-heal) — must work
and stay stable with the backend completely unreachable. Every server-facing flow
(cloud signaling registration, sleep-log upload, flag sync, ICE-config fetch) is a
**parallel best-effort flow**: it may fail, retry with backoff, and recover silently,
but it must never block, delay, interrupt, or surface errors into the monitoring flow.

Normative rules (PROTOCOL §9):
- No golden-path code may `await` a cloud call
- Camera start order: media → wakelock → LAN endpoint → mDNS **before** any cloud I/O
- Cloud outage degrades exactly one capability — remote viewing — and postpones log
  sync (offline queue, F9); the UI may show a quiet "cloud offline" chip, never an
  NTR1-style alert, which is reserved for golden-path failures
