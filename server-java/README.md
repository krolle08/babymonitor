# babymonitor server — Java edition

A 1:1 port of [`server/`](../server) (Node.js) to Java 17. Same wire contract
([`docs/PROTOCOL.md`](../docs/PROTOCOL.md)): WebSocket signaling on `/ws`, REST API under
`/api`, SQLite storage. Message types, JSON field names, error codes and HTTP status codes
are identical — the Flutter app cannot tell the two servers apart.

Stack: [Javalin 6](https://javalin.io) (HTTP + WebSocket on embedded Jetty),
Jackson (JSON), `sqlite-jdbc` (storage), JUnit 5 (tests). Built with the checked-in
Gradle wrapper — no local Gradle install needed, only a JDK 17+.

## Run locally

```powershell
# Windows
$env:FAMILY_TOKEN = "your-shared-secret"
.\gradlew.bat run
```

```sh
# macOS / Linux
FAMILY_TOKEN=your-shared-secret ./gradlew run
```

The server listens on `:8080` (override with `PORT`) and stores data in
`./data/babymonitor.db` (override with `DB_PATH`; parent directories are created,
`:memory:` is supported).

| Env var | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | HTTP + WS listen port |
| `FAMILY_TOKEN` | — (required) | REST bearer token; without it every `/api` call is 401 |
| `DB_PATH` | `./data/babymonitor.db` | SQLite file |
| `TURN_URL`, `TURN_USERNAME`, `TURN_CREDENTIAL` | — | Optional TURN, served via `GET /api/ice-config` |
| `STUN_URL` | `stun:stun.cloudflare.com:3478` | Default STUN |

## Test

```powershell
.\gradlew.bat test
```

30 JUnit tests boot real server instances on ephemeral ports with an in-memory DB and
exercise the protocol over real sockets (`java.net.http` WebSocket + HTTP client):
room lifecycle, reclaim, multi-parent relay routing, spoof protection, hb/noise fanout,
room GC, auth, session/event/flag CRUD and ICE config.

## Build a runnable jar

```powershell
.\gradlew.bat fatJar
java -jar build\libs\babymonitor-server-0.1.0-all.jar
```

## Deploy (Fly.io)

```sh
fly launch --no-deploy      # first time; reuses fly.toml
fly secrets set FAMILY_TOKEN=your-shared-secret
fly deploy
```

The `Dockerfile` is a multi-stage build (`gradle:8-jdk17` → `eclipse-temurin:17-jre-alpine`),
so the runtime image ships only a JRE and the fat jar.

## Memory & cost vs the Node version

The Node server idles around 40–70 MB RSS and fits comfortably in Fly's smallest
256 MB `shared-cpu-1x` machine. The JVM carries more fixed overhead — Jetty, JIT,
metaspace and a default heap — so this edition idles around 150–250 MB and `fly.toml`
provisions **512 MB** instead of 256 MB. On Fly's current pricing that roughly doubles
the machine cost (about $3–4/month extra for an always-on instance). In exchange you get
JVM-grade observability and threading, but for this workload — a handful of family
WebSockets and a small SQLite file — the Node version is the cheaper default; run this
one if your infra is JVM-standardised. Throughput and latency are equivalent at this
scale; the constraint is memory, not CPU.
