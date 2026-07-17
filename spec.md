# Baby Monitor — Spec Driven Development Kit

## Purpose

Turn two phones into a reliable baby monitor using existing hardware. No dedicated device required. Works over WiFi and mobile data. Built in Flutter for Android and iOS from a single codebase.

Primary user: parent monitoring a child in another room or remotely. The system must be honest about its own health — a silent failure is worse than an alert.

---

## Scope

**v0.1 — Personal use.** Two devices, one camera, one parent. No accounts, no cloud storage, no subscriptions.

**Future / Enterprise.** Architecture must allow swapping the signaling layer for a managed service (LiveKit, 100ms) without rewriting WebRTC or app logic. Multi-feed, auth, and cloud recording are out of scope for v0.1 but must not be architecturally blocked.

---

## Feature Specifications

### F1 — Live Video + Audio Stream

**Purpose:** Parent sees and hears the baby in near real-time from any network.

**Behaviour:**
- Camera device captures video and audio and streams to parent device
- Stream works on local WiFi and mobile data (3G/4G/5G)
- Target latency: 2–4 seconds end-to-end
- Stream attempts P2P (STUN) first, falls back to relay (TURN) automatically
- No user interaction required for network fallback

**Acceptance criteria:**
- [ ] Stream established within 10 seconds of session start on WiFi
- [ ] Stream established within 20 seconds on mobile data
- [ ] P2P path used when both devices on same network
- [ ] TURN relay used automatically when P2P fails — no user prompt
- [ ] Latency measured and logged at session start; alert if >5s

---

### F2 — Wakelock (Camera Device Stays Alive)

**Purpose:** The OS must not kill the camera process when the screen locks or the app backgrounds.

**Behaviour:**
- Camera device acquires wakelock on session start
- Wakelock released on session end or app termination
- If wakelock cannot be acquired, user is warned before session starts

**Acceptance criteria:**
- [ ] Camera stream continues after device screen locks (Android + iOS)
- [ ] Stream continues after 30 minutes idle
- [ ] Wakelock failure surfaced to user with clear message
- [ ] Wakelock released cleanly on session end

---

### F3 — Health Check System (Heartbeat)

**Purpose:** The system must detect and report its own failures. A frozen or dropped stream must never appear healthy.

**Behaviour:**
- Camera device sends a heartbeat ping to parent every 3 seconds
- Parent device tracks missed heartbeats and transitions state accordingly
- State machine governs connection health:

| State | Trigger | User-facing |
|---|---|---|
| `CONNECTED` | Heartbeat arriving normally | Green indicator |
| `DEGRADED` | 1–2 missed heartbeats (3–6s) | Silent — no alert |
| `RECONNECTING` | 3+ missed (9s+) | Banner: "Reconnecting…" |
| `FROZEN` | Frame hash unchanged for 5s | Alert + force ICE restart |
| `FAILED` | Max retries exhausted | Full alert + manual reconnect |

**Acceptance criteria:**
- [ ] State transitions are deterministic and testable in isolation
- [ ] `DEGRADED` produces no visible UI change
- [ ] `RECONNECTING` banner appears within 1s of state transition
- [ ] `FROZEN` detected within 6s of stream freeze
- [ ] `FAILED` state reachable only after all auto-heal attempts exhausted
- [ ] Health state exposed via a stream/observable for UI binding

---

### F4 — Auto-Reconnect with Exponential Backoff

**Purpose:** Temporary network drops must heal without user action.

**Behaviour:**
- On connection loss, camera device attempts reconnect automatically
- Retry schedule: 3s → 6s → 12s → 30s (max interval, repeating)
- Reconnect uses same signaling flow as initial connection
- On success: state returns to `CONNECTED`, UI banner dismissed
- On failure after N retries (configurable, default 5): transition to `FAILED`

**Acceptance criteria:**
- [ ] Reconnect attempt starts within 3s of detected drop
- [ ] Backoff intervals match schedule (testable via mock clock)
- [ ] Successful reconnect resets retry counter and backoff
- [ ] `FAILED` state reached after configured max retries
- [ ] No duplicate reconnect loops (debounce on trigger)

---

### F5 — Freeze Detection

**Purpose:** A connected but frozen stream is a silent failure. Must be detected and surfaced.

**Behaviour:**
- Parent device computes a hash of the video frame every 5 seconds
- If hash is identical for 2 consecutive samples (10s frozen), trigger `FROZEN`
- On `FROZEN`: alert user + send ICE restart signal to camera device
- If ICE restart restores stream: return to `CONNECTED`
- If not: transition to `FAILED`

**Acceptance criteria:**
- [ ] Freeze detected within 10s of stream stopping
- [ ] False positive rate: freeze not triggered on low-motion scenes (baby sleeping)
- [ ] ICE restart attempted automatically on freeze detection
- [ ] User alerted with actionable message, not generic error

**Note on false positives:** Frame hashing on a static scene (sleeping baby) will produce identical hashes. Mitigation: compare frame regions with expected noise floor, or use a separate motion threshold. This must be validated in testing.

---

### F6 — Push-to-Talk

**Purpose:** Parent can speak to the baby from the parent device.

**Behaviour:**
- Press-and-hold button on parent device activates microphone
- Audio sent to camera device speaker
- Camera device plays audio at fixed volume
- Indicator shown on parent device while transmitting

**Acceptance criteria:**
- [ ] Audio reaches camera device within 3s of button press
- [ ] Microphone released immediately on button release
- [ ] Simultaneous two-way audio handled without feedback loop
- [ ] Works while stream is active (no interruption to video)

---

### F7 — Noise Alert

**Purpose:** Notify parent when baby makes a sound above a threshold.

**Behaviour:**
- Camera device monitors audio input level continuously
- If level exceeds configurable threshold: send alert to parent device
- Alert delivered as local notification if parent app is backgrounded
- Cooldown period between alerts: 30s (avoid alert spam)

**Acceptance criteria:**
- [ ] Alert delivered within 5s of threshold exceeded
- [ ] Alert works when parent app is backgrounded
- [ ] Cooldown respected — no duplicate alerts within 30s
- [ ] Threshold configurable by user (low / medium / high)

---

## Technical Requirements

### TR1 — Stack

| Layer | Choice | Rationale |
|---|---|---|
| App | Flutter (Dart) | Single codebase Android + iOS. Existing team knowledge. |
| Streaming | WebRTC via `flutter_webrtc` | P2P with relay fallback. Industry standard. |
| Wakelock | `wakelock_plus` | Prevents OS from killing camera process. |
| Signaling | Node.js + WebSocket | Minimal, stateless after handshake. |
| STUN/TURN | Cloudflare TURN (free tier) | Managed, zero ops, no VPS. |
| Signaling host | Fly.io free tier | Deploy in minutes. Stateless. |
| Notifications | `flutter_local_notifications` | In-app and backgrounded alerts. |

### TR2 — Signaling Server

- WebSocket server only
- Handles SDP offer/answer and ICE candidate exchange
- Stateless after WebRTC connection established (no media passes through it)
- Must support at minimum: room creation, peer join, SDP relay, ICE relay, disconnect signal
- Target: ~100 lines of Node.js

### TR3 — Network

- Must function on: WiFi (local), WiFi (internet), 4G/LTE, 5G
- Must not require port forwarding or custom router config
- TURN relay is mandatory fallback, not optional

### TR4 — Health Check

- Heartbeat interval: 3s (configurable)
- Missed threshold for `RECONNECTING`: 3 consecutive
- Freeze detection interval: 5s frame sample
- Freeze trigger: 2 consecutive identical hashes
- Max reconnect retries before `FAILED`: 5 (configurable)
- Backoff: 3s, 6s, 12s, 30s, 30s...

### TR5 — Performance

- Stream latency target: 2–4s end-to-end
- App must not exceed 15% CPU on camera device during active stream (prevent thermal throttle)
- Memory footprint: no unbounded growth over sessions > 1 hour

### TR6 — Platform Constraints

- Android: minimum API 26 (Android 8.0)
- iOS: minimum iOS 14
- Camera device must hold wakelock — background execution required in app manifest / capabilities
- iOS requires `Background Modes → Audio` + `NSCameraUsageDescription` in Info.plist

---

## Non-Technical Requirements

### NTR1 — Reliability over features

The system must fail loudly. A degraded or failed stream that appears healthy is a critical defect. Every failure state must be visible to the user.

### NTR2 — Setup time

Initial pairing of two devices must complete in under 60 seconds with no account creation required.

### NTR3 — Offline resilience

The app must not crash or hang if the signaling server is unreachable. It must surface a clear message and allow retry.

### NTR4 — Privacy

- No video or audio stored server-side in v0.1
- Stream is P2P where possible — media does not pass through any server when STUN succeeds
- When TURN relay is used, data is encrypted in transit (DTLS-SRTP, standard WebRTC)

### NTR5 — Maintainability

- Health check FSM must be implemented as a pure Dart class with no Flutter dependencies — fully unit testable
- Signaling server must be replaceable (LiveKit, 100ms) without changing app WebRTC logic
- All configurable thresholds (heartbeat interval, retry count, freeze threshold) in a single config file

### NTR6 — Future enterprise path

The following must not be architecturally blocked:
- Multiple simultaneous camera feeds
- User authentication
- Cloud recording
- Multi-user access to a single feed

---

## Acceptance Test Scenarios

| ID | Scenario | Expected outcome |
|---|---|---|
| AT-01 | Both devices on same WiFi, start session | Stream live in <10s via P2P |
| AT-02 | Camera on WiFi, parent on mobile data | Stream live via TURN relay |
| AT-03 | Camera device screen locks mid-session | Stream continues uninterrupted |
| AT-04 | WiFi drops on camera device, reconnects in 20s | Auto-reconnect, `CONNECTED` restored, no user action |
| AT-05 | WiFi drops, never returns | Fallback to mobile data, stream continues |
| AT-06 | Stream freezes (simulated) | `FROZEN` detected in <10s, ICE restart triggered |
| AT-07 | Network unrecoverable | `FAILED` state after max retries, user alerted |
| AT-08 | Baby makes loud noise | Parent notified within 5s |
| AT-09 | Parent app backgrounded | Noise alert delivered as push notification |
| AT-10 | Session running for 60 minutes | No memory growth, no thermal issue, stream stable |

---

## Open Questions

- **False positive freeze detection:** How to distinguish a genuinely frozen stream from a sleeping baby in a dark room. Needs empirical testing — consider audio heartbeat as secondary signal.
- **iOS background camera:** Apple restricts background camera access. May require the screen to stay on (wakelock equivalent) or use a dummy audio session to keep the process alive. Needs validation on device.
- **Cloudflare TURN limits:** Free tier has bandwidth limits. For personal use this is fine. Document the threshold so enterprise migration is triggered at the right time.