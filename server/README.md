# Baby Monitor Server

One small Node.js process with two jobs (see `../docs/PROTOCOL.md` — the binding wire contract):

1. **WebSocket signaling** on `/ws` — room codes, SDP/ICE relay, heartbeat/noise fallback relay. No media ever passes through it (TR2, NTR4).
2. **REST API** on `/api/*` — sleep sessions, events and flags in SQLite via Node's built-in `node:sqlite` (TR7). `GET /healthz` is the unauthenticated health probe.

Requires **Node >= 22.5** (uses `node:sqlite`; developed on Node 24). Only runtime dependency: `ws`.

## Run locally

```sh
cd server
npm install
FAMILY_TOKEN=pick-a-long-random-secret node src/index.js
# PowerShell:
#   $env:FAMILY_TOKEN = 'pick-a-long-random-secret'; node src/index.js
```

The server listens on `PORT` (default `8080`):

- WebSocket: `ws://localhost:8080/ws`
- REST: `http://localhost:8080/api/...` with header `Authorization: Bearer <FAMILY_TOKEN>`
- Health: `http://localhost:8080/healthz`

### Environment variables (PROTOCOL §6)

| Var | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | HTTP + WS listen port |
| `FAMILY_TOKEN` | — (required) | Shared-secret bearer token for all `/api` routes |
| `DB_PATH` | `./data/babymonitor.db` | SQLite file (`:memory:` for throwaway runs) |
| `TURN_URL`, `TURN_USERNAME`, `TURN_CREDENTIAL` | — | Optional TURN relay, served to apps via `GET /api/ice-config` |
| `STUN_URL` | `stun:stun.cloudflare.com:3478` | Default STUN server |

TURN credentials are served at runtime through the authenticated `GET /api/ice-config` endpoint, so they never ship inside the app binary.

## Test

```sh
npm test        # runs: node --test "test/*.test.js"
```

(The glob instead of a bare `test/` directory argument is deliberate: Node's test runner
fails to resolve directory arguments on Windows; the glob works on every platform.)

Tests boot the real server on an ephemeral port with an in-memory database and drive it with real `ws` clients and `fetch`.

## Deploy to Fly.io

```sh
cd server
fly launch --no-deploy          # reuses the committed fly.toml + Dockerfile; pick your org/region
fly volumes create babymonitor_data --size 1   # persistent SQLite storage mounted at /data
fly secrets set FAMILY_TOKEN=pick-a-long-random-secret
fly secrets set TURN_URL="turns:turn.cloudflare.com:5349?transport=tcp" \
                TURN_USERNAME=<username> \
                TURN_CREDENTIAL=<credential>
fly deploy
```

Notes:

- `fly.toml` pins `min_machines_running = 1` and disables auto-stop: rooms and WebSocket sessions live in memory, so the machine must stay up while a monitoring session runs.
- `DB_PATH=/data/babymonitor.db` points at the mounted volume, so sleep history survives deploys and restarts.
- Point both apps at `wss://<your-app>.fly.dev/ws` and `https://<your-app>.fly.dev` in the app's Settings screen, and enter the same `FAMILY_TOKEN`.

## Getting Cloudflare TURN credentials (Cloudflare Calls)

Cloudflare's TURN service is part of **Cloudflare Realtime** (formerly Calls) and has a generous free tier:

1. Log in to the [Cloudflare dashboard](https://dash.cloudflare.com) and open **Realtime** (a.k.a. Calls) in the sidebar.
2. Create a **TURN App** (sometimes labelled "TURN Service" / "TURN keys"). Cloudflare gives you a **Turn Token ID** and an **API token**.
3. Generate short-lived TURN credentials from those keys:

   ```sh
   curl -X POST \
     https://rtc.live.cloudflare.com/v1/turn/keys/<TURN_KEY_ID>/credentials/generate \
     -H "Authorization: Bearer <TURN_API_TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"ttl": 86400}'
   ```

   The response contains `iceServers` with `urls`, `username` and `credential`.
4. Set them as Fly secrets (`TURN_URL`, `TURN_USERNAME`, `TURN_CREDENTIAL`). For personal use a long TTL and occasional manual rotation is fine; for anything bigger, generate credentials server-side on demand.

If TURN is not configured, `GET /api/ice-config` returns a STUN-only config and the apps still work whenever P2P is possible; TURN is the mandatory fallback for restrictive networks (TR3), so configure it before relying on the monitor away from home.
