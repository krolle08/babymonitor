# Spec Addendum — v0.1.2

Extends `spec.md` with owner-requested features confirmed 2026-07-17 (F8–F12) and
2026-08-16 (F13–F15). Same conventions.

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

## F13 — Sound Filter (ignore snoring and breathing)

**Purpose:** A parent should be woken by a baby who needs them, not by snoring,
breathing, a cough or the fan. F7's single level threshold is not enough: the loudest
sound in a nursery at 3 a.m. is often the one you least want an alert for. And an
ignored sound must not be *played* either — filtering the alert while the speaker
still carries the snoring is not filtering at all.

**Behaviour:**
- Three independent filters on the camera's noise gate (PROTOCOL §5.2), because
  "ignore snoring" is three different problems:
  1. **The bar** — a level 0.05–0.95, dragged directly with a live meter next to it.
     The F7 low/medium/high presets stay as one-tap shortcuts.
  2. **Minimum duration** — ignore sound that does not *hold* above the bar
     (default 2 s). A snore burst, a cough or a creaking floorboard is over in a
     second or two; a baby who needs someone keeps going.
  3. **Steady-background rejection** (default on) — the gate learns the room's quiet
     level and requires a margin above it, so breathing, a fan or a white-noise
     machine cannot creep over the bar.
- The gate learns its quiet floor **only from sound below the bar**, so a long cry can
  never train it into silence (NTR1).
- **The filter governs the speaker, not just the alert** (the squelch, PROTOCOL §4.2):
  the parent's phone plays the room only while the gate is open, and keeps playing for
  a configurable hang time (default 15 s) after it goes quiet, so the tail of a real
  event is never clipped and the speaker does not chatter between sobs. The audio
  track keeps flowing — only playback is gated — so re-opening is instant.
- Each parent device chooses its own **listen mode**: *Filtered* (default), *Always
  on* (everything, classic monitor) or *Muted*. Mum can filter while dad listens to
  everything. Plus a playback volume per device.
- **Silence is never the failure mode:** if a parent has heard nothing about the gate
  for 10 s — dead channel, camera gone — the audio opens back up and stays open.
- The parent UI always says *why* it is quiet ("the room is below the bar"), so a
  filtered monitor is never mistaken for a broken one.
- Adjustable from the camera unit *and* live from a watching parent (F15 transport),
  with the same live level meter on both, so you can watch the baby breathe and put
  the bar just above it.
- Everything else about F7 is unchanged: 30 s cooldown, snackbar foregrounded,
  notification backgrounded, `noise` events still logged (F9).

**Known limitation (inherited from F7):** the camera reads its audio level from the
*outbound* WebRTC stats, so sampling — and therefore the meter and the gate — only
runs while at least one parent is connected. The camera unit says so instead of
showing a meter stuck at zero. Sampling without a peer connection would mean running
a loopback peer connection purely for stats, which the old camera phone cannot afford
(TR5).

**Acceptance criteria:**
- [ ] Repeated 1–2 s bursts at any volume raise no alert at the default 2 s setting
- [ ] Continuous crying still alerts within 5 s of crossing the bar (F7 AC preserved)
- [ ] Sustained crying keeps re-alerting every 30 s — the filter never goes silent
- [ ] A background hum that rises towards the bar does not start alerting
- [ ] The bar, the duration and the steady toggle can all be changed from a parent
      unit while watching, and take effect on the camera's next sample
- [ ] The live meter shows the current level against the bar in force on both units,
      and explains itself when there is nothing to sample
- [ ] Snoring is **not played** on the parent phone in the default filtered mode
- [ ] Crying is played, and stays played through pauses and through the 30 s alert
      cooldown, until the room has been quiet for the hang time
- [ ] Switching a parent to "Always on" plays everything immediately; "Muted" plays
      nothing while alerts and the picture keep working
- [ ] Killing the data channel while the speaker is filtered-quiet opens the audio
      within 10 s rather than leaving that phone deaf
- [ ] One parent on "Always on" does not change what the other parent hears

---

## F14 — Full-Screen View (both units)

**Purpose:** Setting the camera up means checking the framing from the doorway, and
watching means seeing the crib, not the app around it.

**Behaviour:**
- Both the camera unit's local preview and the parent's live stream have a
  full-screen mode: system bars hidden (immersive), overlay chrome fading out after
  4 s, a tap anywhere bringing it back
- Landscape works in both roles (already permitted by both platform manifests)
- Full-screen shows the **whole** frame rather than cropping to fill — the point is
  to confirm the crib is in shot
- Camera unit's overlay keeps the essentials: parents-watching count, room code,
  sound meter, controls and exit
- Leaving the screen, leaving the room or disposing always restores the system bars

**Acceptance criteria:**
- [ ] Camera unit shows a full-screen preview that makes the framing checkable from
      across the room before leaving
- [ ] Parent unit shows the stream full-screen with no app bar and fading chrome
- [ ] Tapping the picture toggles the overlay; it re-hides after 4 s
- [ ] System bars are restored on exit, on leave and on dispose — never left hidden
- [ ] Health badge, reconnect banner and the frozen/failed overlays still appear in
      full screen (NTR1: an alert is never hidden by a viewing mode)

---

## F15 — Camera Controls from the App (brightness & night mode)

**Purpose:** A monitor you cannot see through at night is not a monitor. The camera
phone must be adjustable from either unit, without walking into the nursery.

**Behaviour:**
- One control sheet, same widget on both roles: brightness, night mode, camera light
  and the F13 sound filter
- **Brightness** is a render gain (−100 % … +100 %) applied by *both* units, so the
  framing check on the camera matches what parents see
- **Night mode** lowers the capture frame rate (adjustable 5–15 fps, longer exposure
  per frame) and applies a night render curve — extra gain, lifted blacks,
  desaturated, because in low light the colour channels are mostly sensor noise
- **Tap-to-meter**: long-press the picture on either unit to put the auto-exposure
  region there. A bright doorway or window otherwise fools the meter into
  underexposing the crib — the one thing you need to see. The chosen point is drawn
  as a reticle, survives restarts, and resets to automatic from the control sheet
- **Lens picker**: on a phone with more than one camera, choose which one captures.
  This exists for infrared: rear sensors sit behind an IR-cut filter, front ones
  often do not, so an IR illuminator is only usable with the right lens selected
- **Camera light** switches the camera phone's torch, off by default and never
  persisted; greyed out on phones without one (capabilities are reported to parents)
- Changes travel P2P on the `health` data channel (PROTOCOL §4.1): no server involved,
  works on LAN with the internet down (NTR7)
- The camera is the single source of truth — it applies what the hardware allows and
  broadcasts the result, so a refused control snaps back on every unit
- Any re-capture (night mode, lens, frame rate) falls back to the previous working
  settings and warns, rather than leaving the crib dark (NTR3)

**On night vision, honestly:** none of this is true night vision. Phone rear cameras
sit behind an IR-cut filter, and WebRTC capture bypasses the computational night
modes phones are marketed on — the app gets a raw Camera2 stream, no frame stacking.
In a pitch-black room there is no signal to amplify. What these controls do is make
the most of *some* light: the reliable fix is a dim amber night light (~1–5 lux), and
the infrared route needs both an IR illuminator (940 nm, invisible) and a lens that
can see it — hence the lens picker. USB IR cameras are not an option: the plugin has
no external-camera support.

**Acceptance criteria:**
- [ ] A parent changes brightness and night mode while watching; the camera unit's
      own preview shows the same picture
- [ ] Night mode visibly brightens a dim room, and the fallback keeps a picture if
      the re-capture fails
- [ ] The camera light can be switched from either unit and is off after a restart
- [ ] A phone with no torch shows the switch disabled, not broken
- [ ] Controls are unavailable (with an explanation) until the stream is up, and
      never block or delay the stream itself
- [ ] Long-pressing the crib from a parent phone visibly re-exposes the picture for
      it, and the reticle shows where the camera is metering
- [ ] A long-press on a letterbox bar changes nothing (rather than metering a spot
      the user never chose)
- [ ] Selecting the front lens from a parent phone switches the capture, and a lens
      that fails to open falls back to the working one
- [ ] Dropping the night frame rate to 5 fps visibly brightens a dim room

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
