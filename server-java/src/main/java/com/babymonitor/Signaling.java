package com.babymonitor;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.javalin.websocket.WsContext;

import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.util.HashMap;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * WebSocket signaling: room registry + SDP/ICE relay (docs/PROTOCOL.md §2, TR2).
 * The server never parses SDP — it routes on (room from the socket's session, peerId).
 *
 * Faithful port of server/src/signaling.js. All handlers run under a single lock,
 * reproducing the Node event-loop's serialized semantics.
 */
public final class Signaling {

    // 6-char room codes from A–Z/2–9 excluding ambiguous 0/O/1/I (PROTOCOL §2.1).
    private static final String ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    private static final int ROOM_CODE_LENGTH = 6;
    private static final int MAX_PARENTS = 4;
    private static final long ROOM_GRACE_MS = 10 * 60 * 1000; // rooms GC'd 10 min after both sides gone

    private static final ObjectMapper MAPPER = new ObjectMapper()
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
    private static final SecureRandom RANDOM = new SecureRandom();

    /** Per-connection session state (the Node code's per-socket ctx object). */
    private static final class Conn {
        final WsContext ws;
        String role;    // "camera" | "parent" | null
        Room room;      // null when not in a room
        String peerId;  // parents only
        JsonNode auth;  // parents only: trusted-device auth captured at join (§8.2), or null

        Conn(WsContext ws) {
            this.ws = ws;
        }
    }

    /** roomId -> { roomId, reclaimToken, camera, parents, emptySince } */
    static final class Room {
        final String roomId;
        final String reclaimToken;
        Conn camera;
        final LinkedHashMap<String, Conn> parents = new LinkedHashMap<>();
        Long emptySince; // epoch ms; null while either side is present

        Room(String roomId, String reclaimToken) {
            this.roomId = roomId;
            this.reclaimToken = reclaimToken;
        }
    }

    private final Map<String, Room> rooms = new LinkedHashMap<>();
    private final Map<String, Conn> conns = new HashMap<>(); // keyed by WS session id
    private final ScheduledExecutorService gcTimer;

    public Signaling() {
        this(60_000);
    }

    public Signaling(long gcIntervalMs) {
        gcTimer = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "signaling-gc");
            t.setDaemon(true); // like Node's timer.unref()
            return t;
        });
        gcTimer.scheduleAtFixedRate(() -> gcNow(Instant.now()), gcIntervalMs, gcIntervalMs,
                TimeUnit.MILLISECONDS);
    }

    // ------------------------------------------------------------------ WS event entry points

    public synchronized void onConnect(WsContext ctx) {
        // Signaling connections are long-lived and may be receive-only on the parent
        // side; disable Jetty's idle timeout like the Node server (which has none).
        try {
            ctx.session.setIdleTimeout(Duration.ZERO);
        } catch (Exception ignored) {
            // best effort; hb traffic keeps active rooms alive anyway
        }
        conns.put(ctx.sessionId(), new Conn(ctx));
    }

    public synchronized void onMessage(WsContext ctx, String raw) {
        Conn conn = conns.computeIfAbsent(ctx.sessionId(), id -> new Conn(ctx));
        JsonNode msg;
        try {
            msg = MAPPER.readTree(raw);
        } catch (Exception e) {
            sendError(conn, "BAD_MESSAGE", "Frame is not valid JSON");
            return;
        }
        if (msg == null || !msg.isObject() || !msg.path("type").isTextual()) {
            sendError(conn, "BAD_MESSAGE", "Frame must be a JSON object with a string \"type\"");
            return;
        }
        try {
            handleMessage(conn, (ObjectNode) msg, raw);
        } catch (Exception e) {
            sendError(conn, "BAD_MESSAGE", "Failed to handle message");
        }
    }

    public synchronized void onClose(WsContext ctx) {
        Conn conn = conns.remove(ctx.sessionId());
        if (conn != null) leaveRoom(conn);
    }

    /** Remove rooms where both sides have been gone for >= 10 minutes. */
    public synchronized void gcNow(Instant now) {
        long nowMs = now.toEpochMilli();
        Iterator<Map.Entry<String, Room>> it = rooms.entrySet().iterator();
        while (it.hasNext()) {
            Room room = it.next().getValue();
            if (room.emptySince != null && nowMs - room.emptySince >= ROOM_GRACE_MS) {
                it.remove();
            }
        }
    }

    public synchronized void close() {
        gcTimer.shutdownNow();
    }

    // ------------------------------------------------------------------ test hooks

    public synchronized boolean hasRoom(String roomId) {
        return rooms.containsKey(roomId);
    }

    /** @return epoch ms since the room emptied, or null if absent/occupied */
    public synchronized Long roomEmptySince(String roomId) {
        Room room = rooms.get(roomId);
        return room == null ? null : room.emptySince;
    }

    // ------------------------------------------------------------------ message dispatch

    private void handleMessage(Conn conn, ObjectNode msg, String raw) {
        switch (msg.get("type").asText()) {
            case "create-room" -> handleCreateRoom(conn, msg);
            case "join-room" -> handleJoinRoom(conn, msg);
            case "offer", "answer", "ice", "ice-restart", "auth-challenge", "auth-response" ->
                    relayNegotiation(conn, msg, raw);
            case "hb", "noise" -> fanout(conn, msg, raw);
            case "leave" -> leaveRoom(conn);
            default -> {
                // Unknown message types MUST be ignored (forward compatibility, NTR6).
            }
        }
    }

    private void handleCreateRoom(Conn conn, ObjectNode msg) {
        if (conn.room != null) leaveRoom(conn); // a socket holds at most one room session

        if (msg.has("roomId") || msg.has("reclaimToken")) {
            // Reclaim path: camera reconnected and wants its old room back.
            String roomId = msg.path("roomId").isTextual() ? msg.get("roomId").asText() : null;
            Room room = roomId == null ? null : rooms.get(roomId);
            JsonNode token = msg.get("reclaimToken");
            if (room == null || token == null || !token.isTextual()
                    || !room.reclaimToken.equals(token.asText())) {
                sendError(conn, "BAD_RECLAIM", "Unknown room or wrong reclaim token");
                return;
            }
            Conn old = room.camera;
            room.camera = conn;
            room.emptySince = null;
            conn.role = "camera";
            conn.room = room;
            if (old != null && old != conn) terminate(old);
            ObjectNode created = MAPPER.createObjectNode();
            created.put("type", "room-created");
            created.put("roomId", room.roomId);
            created.put("reclaimToken", room.reclaimToken);
            sendJson(conn, created);
            // Re-announce live parents so the camera re-creates a PC + offer per peer.
            // Carry the auth captured at join time (§8.2) so the camera re-runs its
            // trusted-device challenge for each re-announced parent.
            for (Map.Entry<String, Conn> entry : room.parents.entrySet()) {
                Conn parent = entry.getValue();
                if (isOpen(parent)) {
                    ObjectNode joined = MAPPER.createObjectNode();
                    joined.put("type", "peer-joined");
                    joined.put("peerId", entry.getKey());
                    if (parent.auth != null) joined.set("auth", parent.auth);
                    sendJson(conn, joined);
                }
            }
            return;
        }

        Room room = new Room(generateRoomId(), UUID.randomUUID().toString());
        room.camera = conn;
        rooms.put(room.roomId, room);
        conn.role = "camera";
        conn.room = room;
        ObjectNode created = MAPPER.createObjectNode();
        created.put("type", "room-created");
        created.put("roomId", room.roomId);
        created.put("reclaimToken", room.reclaimToken);
        sendJson(conn, created);
    }

    private void handleJoinRoom(Conn conn, ObjectNode msg) {
        if (!msg.path("roomId").isTextual()) {
            sendError(conn, "BAD_MESSAGE", "join-room requires roomId");
            return;
        }
        if (conn.room != null) leaveRoom(conn);

        Room room = rooms.get(msg.get("roomId").asText());
        if (room == null) {
            sendError(conn, "ROOM_NOT_FOUND", "No room " + msg.get("roomId").asText());
            return;
        }

        // Optional peerId reuse on rejoin: honoured when free (not held by a live socket).
        String peerId = msg.path("peerId").isTextual() && !msg.get("peerId").asText().isEmpty()
                ? msg.get("peerId").asText()
                : null;
        Conn stale = null;
        if (peerId != null) {
            Conn existing = room.parents.get(peerId);
            if (existing != null && existing != conn && isOpen(existing)) {
                peerId = null; // taken by a live parent — treat as a fresh join
            } else if (existing != null && existing != conn) {
                stale = existing; // stale socket; reclaim the slot
            }
        }
        if ((peerId == null || !room.parents.containsKey(peerId))
                && room.parents.size() >= MAX_PARENTS) {
            sendError(conn, "ROOM_FULL",
                    "Room " + room.roomId + " already has " + MAX_PARENTS + " parents");
            return;
        }
        if (peerId == null) peerId = UUID.randomUUID().toString();

        room.parents.put(peerId, conn);
        if (stale != null) terminate(stale);
        // Optional trusted-device auth (§8.2): passed through verbatim, contents not
        // validated by the server. Captured on the parent's Conn so it survives a reclaim.
        JsonNode authField = msg.get("auth");
        conn.auth = (authField != null && !authField.isNull()) ? authField.deepCopy() : null;
        room.emptySince = null;
        conn.role = "parent";
        conn.room = room;
        conn.peerId = peerId;
        ObjectNode joined = MAPPER.createObjectNode();
        joined.put("type", "room-joined");
        joined.put("roomId", room.roomId);
        joined.put("peerId", peerId);
        sendJson(conn, joined);
        // Camera responds with an auth-challenge when auth is present, else an offer (§2.1).
        ObjectNode peerJoined = MAPPER.createObjectNode();
        peerJoined.put("type", "peer-joined");
        peerJoined.put("peerId", peerId);
        if (conn.auth != null) peerJoined.set("auth", conn.auth);
        sendJson(room.camera, peerJoined);
    }

    /**
     * offer/answer/ice/ice-restart/auth-challenge/auth-response: relayed verbatim,
     * routed on peerId (§2.2). auth-challenge flows camera→parent like offer;
     * auth-response flows parent→camera like answer (peerId stamped server-side,
     * the deviceId/pk/sig payload left untouched).
     */
    private void relayNegotiation(Conn conn, ObjectNode msg, String raw) {
        Room room = conn.room;
        if (room == null) {
            sendError(conn, "NOT_IN_ROOM",
                    msg.get("type").asText() + " requires an active room session");
            return;
        }
        if ("camera".equals(conn.role)) {
            Conn target = msg.path("peerId").isTextual()
                    ? room.parents.get(msg.get("peerId").asText())
                    : null;
            if (isOpen(target)) sendRaw(target, raw);
        } else {
            // Stamp the sender's real peerId so the camera routes to the right PC
            // (a parent cannot spoof another peer).
            ObjectNode stamped = msg.deepCopy();
            stamped.put("peerId", conn.peerId);
            sendJson(room.camera, stamped);
        }
    }

    /** hb + noise: camera → all parents fanout (§2.3). */
    private void fanout(Conn conn, ObjectNode msg, String raw) {
        Room room = conn.room;
        if (room == null) {
            sendError(conn, "NOT_IN_ROOM",
                    msg.get("type").asText() + " requires an active room session");
            return;
        }
        if (!"camera".equals(conn.role)) return; // only the camera emits hb/noise
        for (Conn parent : room.parents.values()) {
            if (isOpen(parent)) sendRaw(parent, raw);
        }
    }

    /** Detach a connection from its room (used for both 'leave' and socket close). */
    private void leaveRoom(Conn conn) {
        Room room = conn.room;
        if (room == null) return;
        if ("camera".equals(conn.role)) {
            if (room.camera == conn) {
                room.camera = null;
                // Parents show RECONNECTING and wait; room persists for reclaim (§2.1).
                ObjectNode cameraLeft = MAPPER.createObjectNode();
                cameraLeft.put("type", "camera-left");
                for (Conn parent : room.parents.values()) {
                    sendJson(parent, cameraLeft);
                }
                maybeMarkEmpty(room);
            }
        } else if ("parent".equals(conn.role)) {
            if (room.parents.get(conn.peerId) == conn) {
                room.parents.remove(conn.peerId);
                ObjectNode peerLeft = MAPPER.createObjectNode();
                peerLeft.put("type", "peer-left");
                peerLeft.put("peerId", conn.peerId);
                sendJson(room.camera, peerLeft);
                maybeMarkEmpty(room);
            }
        }
        conn.room = null;
        conn.role = null;
        conn.peerId = null;
    }

    private void maybeMarkEmpty(Room room) {
        if (!isOpen(room.camera) && room.parents.isEmpty()) {
            room.emptySince = System.currentTimeMillis();
        }
    }

    private String generateRoomId() {
        String id;
        do {
            StringBuilder sb = new StringBuilder(ROOM_CODE_LENGTH);
            for (int i = 0; i < ROOM_CODE_LENGTH; i++) {
                sb.append(ROOM_CODE_ALPHABET.charAt(RANDOM.nextInt(ROOM_CODE_ALPHABET.length())));
            }
            id = sb.toString();
        } while (rooms.containsKey(id));
        return id;
    }

    // ------------------------------------------------------------------ socket helpers

    private static boolean isOpen(Conn conn) {
        try {
            return conn != null && conn.ws.session.isOpen();
        } catch (Exception e) {
            return false;
        }
    }

    private static void sendRaw(Conn conn, String text) {
        if (!isOpen(conn)) return;
        try {
            conn.ws.send(text);
        } catch (Exception ignored) {
            // peer vanished mid-send; close event follows — never crash (NTR3)
        }
    }

    private static void sendJson(Conn conn, ObjectNode obj) {
        sendRaw(conn, obj.toString());
    }

    private static void sendError(Conn conn, String code, String message) {
        ObjectNode error = MAPPER.createObjectNode();
        error.put("type", "error");
        error.put("code", code);
        error.put("message", message);
        sendJson(conn, error);
    }

    /** Abruptly close a superseded socket (the Node code's ws.terminate()). */
    private static void terminate(Conn conn) {
        try {
            conn.ws.closeSession();
        } catch (Exception ignored) {
            // already gone
        }
    }
}
