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

## TR7 — Backend storage

- The signaling server also hosts the REST API (one Fly.io deploy)
- SQLite via Node's built-in `node:sqlite` (`DatabaseSync`, Node ≥ 22.5 — no native build); file path via `DB_PATH` env var (Fly volume)
- Shared-secret `FAMILY_TOKEN` bearer auth — no accounts (NTR2), no media stored (NTR4)
- Full wire contract: `docs/PROTOCOL.md`

## TR8 — Platforms (confirmed)

- Camera role: Android (the old phone), min API 26
- Parent role: Android **and** iOS (min iOS 14)
- Single Flutter codebase with a role picker on first launch
