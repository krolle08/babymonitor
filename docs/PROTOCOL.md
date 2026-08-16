# Baby Monitor — Wire Contracts (v0.1)

This document is the **single source of truth** for every interface shared between the
Flutter app and the Node.js server, and between modules inside the app. All code MUST
conform to it. If an implementation needs to deviate, update this document in the same
change.

---

## 1. Roles & topology

- **Camera device** ("camera"): one per room. Old phone pointed at the baby.
- **Parent device** ("parent"): N per room (mom + dad + …). Each parent gets its own
  `RTCPeerConnection` from the camera (camera is the offerer for every parent).
- **Server**: one Node.js process. Two responsibilities:
  1. WebSocket signaling (`/ws`) — SDP/ICE relay only, no media (TR2).
  2. REST API (`/api/*`) — sleep-session log storage + flags (SQLite).

---

## 2. Signaling protocol (WebSocket `/ws`)

All messages are JSON text frames: `{ "type": string, ...fields }`.
Unknown message types MUST be ignored by both sides (forward compatibility, NTR6).

### 2.1 Room lifecycle

| Direction | Message | Fields | Notes |
|---|---|---|---|
| camera → server | `create-room` | `roomId?`, `reclaimToken?` | Without fields: new room. With both: reclaim an existing room after reconnect. |
| server → camera | `room-created` | `roomId`, `reclaimToken` | `roomId` is a 6-char A–Z/2–9 code (no 0/O/1/I). `reclaimToken` is a UUID the camera stores for reconnects. |
| parent → server | `join-room` | `roomId`, `peerId?`, `auth?` | `peerId` present = rejoin after reconnect (server reuses it if free). `auth` (§8.2): `{deviceId, pk, nonce}` — trusted-device authentication; relayed to the camera inside `peer-joined`. |
| server → parent | `room-joined` | `roomId`, `peerId` | `peerId` is a UUID identifying this parent in the room. |
| server → camera | `peer-joined` | `peerId`, `auth?` | Camera responds with `auth-challenge` (§8.2) when `auth` present, else (guest mode) directly with an `offer`. |
| server → camera | `peer-left` | `peerId` | Parent socket closed/left. Camera closes that PC. |
| server → parents | `camera-left` | — | Camera socket closed. Parents show RECONNECTING and wait; room persists 10 min for reclaim. |
| both → server | `leave` | — | Graceful exit; same effects as socket close. |
| server → client | `error` | `code`, `message` | Codes: `ROOM_NOT_FOUND`, `ROOM_FULL`, `BAD_RECLAIM`, `BAD_MESSAGE`, `NOT_IN_ROOM`. |

Room capacity: 1 camera + max 4 parents. Rooms are garbage-collected 10 minutes after
both sides are gone.

### 2.2 WebRTC negotiation (relayed verbatim)

| Direction | Message | Fields |
|---|---|---|
| camera → server → parent | `offer` | `peerId`, `sdp` (string), `sdpType` ("offer") |
| parent → server → camera | `answer` | `peerId`, `sdp`, `sdpType` ("answer") |
| both → server → other side | `ice` | `peerId`, `candidate` (`{candidate, sdpMid, sdpMLineIndex}`) |
| parent → server → camera | `ice-restart` | `peerId` | Parent detected FROZEN (F5); camera performs ICE restart + new offer for that peer. |
| camera → server → parent | `auth-challenge` | `peerId`, `nonce`, `sig` | §8.2. Relayed verbatim like `offer`. |
| parent → server → camera | `auth-response` | `peerId`, `deviceId`, `pk`, `sig` | §8.2. Relayed verbatim like `answer`. |

`pair-request`/`pair-response` (§8.1) are **never relayed by the cloud server** — pairing
is a LAN-only ceremony. New error code: `NOT_TRUSTED` (camera rejects an
unauthenticated or unknown device; sent to that parent, then the peer is dropped).

The server never parses SDP — it routes on (`roomId` from the socket's session, `peerId`).

### 2.3 Heartbeat fallback + noise alert relay

Primary heartbeat travels over a WebRTC **data channel** labelled `health` (see §4).
When the data channel is not open, the camera falls back to signaling relay:

| Direction | Message | Fields |
|---|---|---|
| camera → server → parents | `hb` | `seq` (int), `ts` (ms epoch), `audioLevel` (0.0–1.0) |
| camera → server → parents | `noise` | `ts`, `audioLevel` | Noise gate fired (F7). Also sent on data channel; parents dedupe on `ts`. |

---

## 3. REST API (`/api`, JSON)

Auth: every request carries `Authorization: Bearer <FAMILY_TOKEN>`.
`FAMILY_TOKEN` is a shared secret set as a server env var and typed once into each app's
settings (no accounts — NTR2/NTR4). `401` on mismatch. `GET /healthz` is unauthenticated.

Timestamps: ISO-8601 UTC strings. IDs: server-generated integers.

### 3.1 Sleep sessions

A **session** = one continuous monitoring run on the camera device.

- `POST /api/sessions` → `201 {id}`
  body: `{deviceId: string, roomId: string, startedAt: iso}`
- `PATCH /api/sessions/:id` → `200 {id}`
  body: `{endedAt: iso}` — close a session.
- `GET /api/sessions?from=iso&to=iso` → `200 [{id, deviceId, roomId, startedAt, endedAt, eventCounts: {noise: n, freeze: n, reconnect: n}}]`
- `GET /api/sessions/:id` → `200 {id, ..., events: [...]}` — full event list.

### 3.2 Session events

- `POST /api/sessions/:id/events` → `201 {inserted: n}`
  body: an **array** (batch upload from the offline queue):
  `[{type: "noise"|"freeze"|"reconnect"|"state"|"latency", at: iso, data: object}]`
  - `noise` data: `{audioLevel}`
  - `state` data: `{from, to}` (HealthState transition)
  - `latency` data: `{ms}` (measured at session start, F1)
  - Unknown `type` values are stored verbatim (forward compatible).

### 3.3 Flags (why sleep was off — "Teething", "Sick", …)

Flags attach to a **date** (not a session) so parents can annotate any night.

- `POST /api/flags` → `201 {id}`
  body: `{date: "YYYY-MM-DD", label: string, note?: string}`
- `GET /api/flags?from=YYYY-MM-DD&to=YYYY-MM-DD` → `200 [{id, date, label, note}]`
- `DELETE /api/flags/:id` → `204`

Suggested built-in labels the UI offers (free text also allowed):
`Teething`, `Sick`, `Vaccination`, `Travel`, `Growth spurt`, `New routine`.

### 3.4 Errors

`{error: {code: string, message: string}}` with appropriate HTTP status.
Server unreachable / non-2xx → client keeps events in its offline queue and retries
with backoff (NTR3 — never crash, never block the stream).

---

## 4. Data channel `health` (camera → each parent)

Created by the camera on every parent PC, label `health`, ordered, reliable.
JSON text messages:

| Message | Fields | Cadence |
|---|---|---|
| `{t: "hb", seq, ts, audioLevel}` | seq int, ts ms epoch, audioLevel 0–1 | every `heartbeatInterval` (3 s) |
| `{t: "noise", ts, audioLevel}` | — | on noise-gate fire (30 s cooldown) |
| `{t: "camera-state", controls, caps}` | see §4.1 | when the channel opens, on `get-camera-state`, and after every applied control change |

Parent → camera on the same channel:

| Message | Fields | Purpose |
|---|---|---|
| `{t: "talk", on: bool}` | — | Push-to-talk indicator (F6); camera may show "parent talking". |
| `{t: "camera-control", controls}` | see §4.1 | Change picture or sound-filter settings (F13/F15). |
| `{t: "get-camera-state"}` | — | Ask for the current `camera-state` (sent when the parent's channel opens). |

Unknown `t` values MUST be ignored by both sides (forward compatibility, NTR6).

### 4.1 Camera controls (F13/F15)

Camera controls travel **only** on the data channel — P2P, no relay, so neither
signaling server needs to know about them and a cloud outage cannot touch them
(NTR7). They are therefore available exactly when a stream is: no open `health`
channel, no controls.

```jsonc
{
  "brightness": 0.0,      // -1.0 … 1.0 render gain, 0.0 = untouched
  "nightMode": false,     // low-light capture profile + night render curve
  "light": false,         // camera phone torch
  "sound": {
    "threshold": 0.30,    // 0.05 … 0.95 — the bar (F7 presets: .50/.30/.15)
    "sustainMs": 2000,    // 0 … 15000 — ignore sound shorter than this
    "ignoreSteady": true  // reject sound only just above the learned floor
  }
}
```

`caps` reports what the hardware can do: `{"torch": bool}`. Parents grey out
what is not supported instead of offering a switch that does nothing.

Rules:

- **The camera is the single source of truth.** A `camera-control` message is a
  *partial patch*: absent fields keep their current value. The camera applies
  what it can, persists the result, and broadcasts `camera-state` to every
  parent — so a knob the hardware refuses (a phone with no torch) visibly snaps
  back, and all units always agree on the render settings.
- `brightness`/`nightMode` are applied at **render** time by both roles, so the
  camera operator's framing check matches what the parents see. `nightMode`
  additionally re-captures at `nightCaptureFrameRate` (longer exposure per
  frame); the swap briefly interrupts the picture and falls back to the normal
  profile if the re-capture fails.
- `sound` reconfigures the camera's `NoiseGate` live (F7 AC) — the gate is still
  the single decision point, and noise alerts (§2.3) are unchanged.
- The torch is never persisted: a camera that restarts must not light the room
  on its own.

---

## 5. App module contracts (Dart)

### 5.1 `lib/config/app_config.dart` — ALL tunables live here (NTR5)

```dart
class AppConfig {
  static const heartbeatInterval = Duration(seconds: 3);      // TR4
  static const degradedAfterMissed = 1;                        // 1–2 missed → DEGRADED
  static const reconnectingAfterMissed = 3;                    // 3+ missed → RECONNECTING
  static const freezeSampleInterval = Duration(seconds: 5);    // TR4
  static const freezeIdenticalSamples = 2;                     // 2 identical → FROZEN
  static const maxReconnectRetries = 5;                        // TR4
  static const backoffSchedule = [3, 6, 12, 30];               // seconds; last repeats
  static const noiseCooldown = Duration(seconds: 30);          // F7
  // Preset bars: 'low' alerts on loud sound only, 'high' also on quiet sound.
  static const noiseThresholds = {'low': 0.50, 'medium': 0.30, 'high': 0.15};
  static const defaultNoiseSustain = Duration(seconds: 2);     // F13
  static const maxNoiseSustain = Duration(seconds: 15);        // F13
  static const defaultIgnoreSteadySound = true;                // F13
  static const steadySoundMargin = 0.08;                       // F13
  static const quietFloorAlpha = 0.05;                         // F13
  static const captureFrameRate = 15;                          // F15
  static const nightCaptureFrameRate = 8;                      // F15
  static const latencyAlertMs = 5000;                          // F1
  static const roomGraceMinutes = 10;
  // Runtime-configurable (persisted in SharedPreferences, editable in Settings):
  // signalingUrl, apiBaseUrl, familyToken, noiseThreshold, noiseSustainMs,
  // ignoreSteadySound, cameraBrightness, cameraNightMode
}
```

### 5.2 `lib/core/` — pure Dart, **no Flutter imports** (NTR5)

- `health_state.dart` — `enum HealthState { connecting, connected, degraded, reconnecting, frozen, failed }`
  (`connecting` is the pre-first-heartbeat initial state; the spec's five operational
  states are unchanged.)
- `health_monitor.dart` — the FSM. Constructor takes a `Clock`-style `DateTime Function() now`
  plus thresholds; inputs are `onHeartbeat(seq)`, `tick()` (called by a timer),
  `onFreezeDetected()`, `onFreezeRecovered()`, `onReconnectExhausted()`,
  `onReconnected()`; output is `Stream<HealthState>` + current state getter.
- `backoff_scheduler.dart` — yields 3, 6, 12, 30, 30… seconds; `reset()`;
  `attemptsExhausted` after `maxRetries`.
- `freeze_detector.dart` — fed `int framesDecoded` samples every 5 s (from WebRTC
  `getStats()`); identical for 2 consecutive samples → frozen. **Deliberate deviation
  from "frame hash"**: decoded-frame-count delta cannot false-positive on a static
  sleeping baby (spec F5 open question) because the encoder keeps emitting frames while
  the pipeline is alive.
- `noise_gate.dart` — `bool feed(double level, DateTime now)`; true when the level
  clears the bar, has cleared it for `sustain`, and the cooldown has elapsed
  (F13). The gate learns the room's quiet floor from **sub-threshold samples
  only** — deliberately, so a long cry can never train it into silence (NTR1) —
  and, when `ignoreSteady` is on, also requires `steadySoundMargin` above that
  floor. `effectiveThreshold` exposes the bar in force for the UI meter.
- `camera_controls.dart` — `SoundFilter` / `CameraControls` / `CameraCapabilities`
  / `CameraState` value objects (§4.1) with partial-patch JSON, plus
  `videoColorMatrix()`, the 4x5 render matrix for brightness/night mode.
- `heartbeat_tracker.dart` — tracks last-seen seq/time, exposes `missedCount(now)`.

### 5.3 `lib/services/` — Flutter/plugin-facing

- `signaling_client.dart` — WebSocket wrapper over §2; auto-reconnect with
  `BackoffScheduler`; `Stream<SignalMessage>`; never throws to UI (NTR3).
- `webrtc_service.dart` — two facades: `CameraSession` (multi-peer map
  `peerId → RTCPeerConnection`, local media, data channels, ICE-restart handling,
  wakelock acquire/release) and `ParentSession` (single PC, remote renderer,
  push-to-talk mic track toggle, stats sampling for `FreezeDetector`, `ice-restart` send).
- `sleep_log_service.dart` — session/event/flag REST client + on-disk JSON queue
  (`path_provider`), flushed with backoff whenever connectivity returns.
- `noise_monitor.dart` — samples outbound audio level on the camera
  (via `getStats()` audio source level), feeds `NoiseGate` and publishes every
  sample on `levels` for the live meter (F13).
- `notification_service.dart` — `flutter_local_notifications` init + `showNoiseAlert`,
  `showConnectionAlert` (F7 AC: works backgrounded).

### 5.4 `lib/screens/`

`role_picker_screen.dart`, `camera_screen.dart`, `parent_screen.dart`,
`history_screen.dart` (sessions timeline + per-night bars + flags),
`settings_screen.dart` (server URLs, family token, sound filter).

Both role screens offer a full-screen view with fading chrome (F14) and open the
same `CameraControlsPanel` (F13/F15) — locally on the camera, over the data
channel from a parent. Video is rendered through `AdjustableVideoView`, which
applies `videoColorMatrix()`; a neutral setting skips the filter layer entirely.

---

## 6. Server env vars

| Var | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | HTTP + WS listen port |
| `FAMILY_TOKEN` | — (required) | REST bearer token |
| `DB_PATH` | `./data/babymonitor.db` | SQLite file |
| `TURN_URL`, `TURN_USERNAME`, `TURN_CREDENTIAL` | — | Optional: served to clients via `GET /api/ice-config` (authenticated) so TURN creds never ship in the app binary. |
| `STUN_URL` | `stun:stun.cloudflare.com:3478` | Default STUN |

`GET /api/ice-config` → `200 {iceServers: [{urls, username?, credential?}]}` — both app
roles fetch this at session start; on failure they fall back to the default STUN-only
config (NTR3).

---

## 7. LAN transport — camera-hosted signaling (F11)

The camera app embeds its own WebSocket signaling endpoint so that pairing and
(re)connection at home — or on a phone hotspot — need **no internet and no cloud**.

- **Endpoint:** `ws://<camera-ip>:<port>/ws`. Default port `47800`; if taken, the next
  free port is used — the *advertised* port is authoritative.
- **Discovery:** mDNS/DNS-SD service type **`_babymonitor._tcp`**, instance name = the
  camera's display name, TXT records: `id` (deviceId), `name`, `proto=1`, `port`.
- **Protocol:** identical JSON messages to §2 with these deltas:
  - There is exactly one implicit room; `create-room` is not used (the camera *is* the
    room). `join-room` accepts two `roomId` forms: **`"LOCAL"`** (trusted join — must
    carry `auth`, §8.2) or **the current room code** (guest bootstrap, see below). All
    other flows (`offer`, `answer`, `ice`, `ice-restart`, `hb`, `noise`, `auth-*`,
    capacity, `peer-left`) behave exactly as in §2 with the camera playing the server
    role.
  - `pair-request`/`pair-response` (§8.1) are accepted **only** on this transport.
- **Parent connection order** (every initial connect *and* every reconnect attempt):
  1. last-known LAN address of a trusted camera → 2. mDNS discovery (2 s budget) →
  3. cloud signaling (§2). First success wins; the order guarantees the same-network
  case never depends on the internet.
- Untrusted `join-room` on the LAN transport is rejected with `NOT_TRUSTED` unless the
  camera has pairing mode active (§8.1) or the join uses the current room code as its
  `roomId` (guest bootstrap, same as cloud, gated by "allow room-code joins").
- **Code provenance:** the 6-char room code is minted by the *cloud* server
  (`room-created`); the camera reuses it for LAN guest joins. A camera with no cloud
  connectivity therefore has **no guest code** — fully-offline LAN access is for
  trusted devices (§8.2) or via pairing mode (§8.1). *(Future option, not implemented:
  camera-minted local codes.)*

## 8. Device identity & trust (F12)

- Every install generates an **Ed25519 keypair** on first run. The private key lives in
  platform secure storage (Android Keystore-backed / iOS Keychain); it never leaves the
  device. `pk` fields are the base64url-encoded 32-byte public key.
- `deviceId` = the existing 16-hex identifier (§5.3 settings).
- **Trust store** (per device): list of `{deviceId, name, pk, role: camera|parent,
  addedAt}`. Public data — stored in normal preferences. Removing an entry (revocation)
  takes effect on the next auth attempt; the camera additionally drops live peers whose
  `deviceId` is revoked.

### 8.1 Pairing ceremony (QR + LAN, one-time)

1. Camera enters *pairing mode* (UI action): generates a one-time `token`
   (32 random bytes, base64url, valid 5 minutes, single use) and shows a QR encoding:
   `{"v":1,"t":"pair","deviceId":…,"name":…,"pk":…,"port":…,"addrs":[…],"token":…}`
2. Parent scans the QR → immediately adds the camera to its trust store (public key
   obtained optically = MITM-proof) → connects to the LAN endpoint → sends
   `pair-request {deviceId, name, pk, proof}` where
   `proof = base64url( Ed25519-sign(privKey_parent, utf8(token) ∥ utf8(deviceId_parent)) )`.
3. Camera verifies the token is outstanding + the signature verifies with the presented
   `pk` → stores the parent in its trust store, consumes the token → replies
   `pair-response {accepted: true, deviceId, name, pk}`.
   On failure: `pair-response {accepted: false, reason}` — parent removes the
   provisional camera entry.

### 8.2 Session authentication (every connection, both transports)

Sequence per parent join (camera drives it; the cloud server just relays §2.2):

1. Parent → `join-room` with `auth: {deviceId, pk, nonce_p}` (`nonce_p` = fresh 32-byte
   base64url challenge for the camera).
2. Camera → `auth-challenge {peerId, nonce_c, sig}` where
   `sig = sign(privKey_camera, nonce_p ∥ utf8(peerId))`.
   The parent verifies `sig` against its trusted camera `pk`; mismatch → disconnect +
   user alert "Camera identity changed — re-pair" (possible MITM or reinstalled camera).
3. Parent → `auth-response {peerId, deviceId, pk, sig}` where
   `sig = sign(privKey_parent, nonce_c ∥ utf8(peerId))`.
4. Camera checks `pk` is in its trust store (by `deviceId`) and the signature verifies
   → proceeds with the `offer` (§2.2). Otherwise → `error {code: NOT_TRUSTED}` to that
   peer and drops it.

**Signature byte layout (normative for any future client):** all signed material is a
concatenation of UTF-8 strings — nonces are signed as their **base64url string form**,
not decoded bytes. Concretely: `auth-challenge.sig` signs
`utf8(nonce_p_base64url) ∥ utf8(peerId)`; `auth-response.sig` signs
`utf8(nonce_c_base64url) ∥ utf8(peerId)`; `pair-request.proof` signs
`utf8(token) ∥ utf8(deviceId_parent)`.

Guest mode (bootstrap, NTR2): a `join-room` **without** `auth` is served only when the
camera's "allow room-code joins" setting is on (default **on**) — the room code typed by
the guest is the authorization. Trusted devices never need to *see or type* a code; note
that on the **cloud** transport rooms are still code-addressed, so the parent app
remembers the last room code per trusted camera and supplies it silently — the trust
guarantee is "zero input", not "code-free wire format".

## 9. Golden path — monitoring never depends on the server (NTR7)

Monitoring (capture → stream → watch → auto-heal) is the **golden path**. Everything
involving the cloud backend is a **parallel, best-effort flow** that may fail silently
(logged + retried with backoff) without ever touching the golden path.

Camera session start order (normative):

1. **Golden path first, all local:** acquire media → wakelock → start LAN signaling
   endpoint → advertise via mDNS. The camera is now fully watchable at home — even with
   the internet down.
2. **In parallel, detached:** connect to cloud signaling + `create-room`/reclaim (for
   remote viewers) · start the sleep-log session · flush queued events. Each of these
   retries independently; a permanent cloud outage degrades exactly one capability
   (remote viewing) and delays log sync — it must never delay, interrupt, or error the
   local stream, and it must never surface as a monitoring failure in the UI (a small
   "cloud offline" indicator is permitted; NTR1 alerts are reserved for the golden path).

Implementation rule: no code on the golden path may `await` a cloud call. `ApiClient` /
`SleepLogService` calls from monitoring code are fire-and-forget; `fetchIceConfig()`
has a hard timeout and a STUN-only fallback; LAN operation uses no ICE config fetch.
