package com.babymonitor;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

import static com.babymonitor.TestSupport.node;
import static com.babymonitor.TestSupport.startTestServer;
import static com.babymonitor.TestSupport.waitFor;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** Signaling protocol tests (docs/PROTOCOL.md §2) — port of server/test/signaling.test.js. */
class SignalingTest {

    private static final Pattern ROOM_CODE_RE = Pattern.compile("^[A-HJ-NP-Z2-9]{6}$"); // A–Z/2–9 without 0/O/1/I
    private static final Pattern UUID_RE = Pattern.compile(
            "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            Pattern.CASE_INSENSITIVE);

    private static TestSupport.TestServer srv;

    @BeforeAll
    static void boot() {
        srv = startTestServer(Map.of());
    }

    @AfterAll
    static void shutdown() {
        srv.app().stop();
    }

    private record RoomHandle(TestSupport.WsClient camera, String roomId, String reclaimToken) {}

    private record ParentHandle(TestSupport.WsClient parent, String peerId) {}

    private static RoomHandle newRoom() {
        TestSupport.WsClient camera = TestSupport.WsClient.connect(srv.wsUrl());
        camera.send(node("type", "create-room"));
        JsonNode created = camera.next();
        assertEquals("room-created", created.path("type").asText());
        return new RoomHandle(camera, created.get("roomId").asText(), created.get("reclaimToken").asText());
    }

    private static ParentHandle joinParent(String roomId, TestSupport.WsClient camera) {
        TestSupport.WsClient parent = TestSupport.WsClient.connect(srv.wsUrl());
        parent.send(node("type", "join-room", "roomId", roomId));
        JsonNode joined = parent.next();
        assertEquals("room-joined", joined.path("type").asText());
        assertEquals(roomId, joined.get("roomId").asText());
        String peerId = joined.get("peerId").asText();
        if (camera != null) {
            assertEquals(node("type", "peer-joined", "peerId", peerId), camera.next());
        }
        return new ParentHandle(parent, peerId);
    }

    @Test
    void createRoomReturnsUnambiguousCodeAndUuidReclaimToken() {
        RoomHandle room = newRoom();
        assertTrue(ROOM_CODE_RE.matcher(room.roomId()).matches(), "room code: " + room.roomId());
        assertTrue(UUID_RE.matcher(room.reclaimToken()).matches(), "reclaim token: " + room.reclaimToken());
        room.camera().close();
    }

    @Test
    void joinRoomReturnsUuidPeerIdAndNotifiesCamera() {
        RoomHandle room = newRoom();
        ParentHandle joined = joinParent(room.roomId(), room.camera());
        assertTrue(UUID_RE.matcher(joined.peerId()).matches(), "peerId: " + joined.peerId());
        room.camera().close();
        joined.parent().close();
    }

    @Test
    void joinUnknownRoomAnswersRoomNotFound() {
        TestSupport.WsClient parent = TestSupport.WsClient.connect(srv.wsUrl());
        parent.send(node("type", "join-room", "roomId", "ZZZZZZ"));
        JsonNode err = parent.next();
        assertEquals("error", err.path("type").asText());
        assertEquals("ROOM_NOT_FOUND", err.path("code").asText());
        parent.close();
    }

    @Test
    void fifthParentGetsRoomFull() {
        RoomHandle room = newRoom();
        List<ParentHandle> parents = new ArrayList<>();
        for (int i = 0; i < 4; i++) parents.add(joinParent(room.roomId(), room.camera()));
        TestSupport.WsClient fifth = TestSupport.WsClient.connect(srv.wsUrl());
        fifth.send(node("type", "join-room", "roomId", room.roomId()));
        JsonNode err = fifth.next();
        assertEquals("error", err.path("type").asText());
        assertEquals("ROOM_FULL", err.path("code").asText());
        fifth.close();
        room.camera().close();
        for (ParentHandle p : parents) p.parent().close();
    }

    @Test
    void offerAnswerIceRouteToTheRightPeer() {
        RoomHandle room = newRoom();
        ParentHandle a = joinParent(room.roomId(), room.camera());
        ParentHandle b = joinParent(room.roomId(), room.camera());
        assertNotEquals(a.peerId(), b.peerId());

        // Camera → parent A only.
        room.camera().send(node("type", "offer", "peerId", a.peerId(), "sdp", "sdp-for-A", "sdpType", "offer"));
        assertEquals(node("type", "offer", "peerId", a.peerId(), "sdp", "sdp-for-A", "sdpType", "offer"),
                a.parent().next());
        b.parent().expectSilence();

        // Camera → parent B only.
        room.camera().send(node("type", "offer", "peerId", b.peerId(), "sdp", "sdp-for-B", "sdpType", "offer"));
        assertEquals("sdp-for-B", b.parent().next().path("sdp").asText());
        a.parent().expectSilence();

        // Parent A answer → camera, stamped with A's peerId.
        a.parent().send(node("type", "answer", "peerId", a.peerId(), "sdp", "answer-A", "sdpType", "answer"));
        assertEquals(node("type", "answer", "peerId", a.peerId(), "sdp", "answer-A", "sdpType", "answer"),
                room.camera().next());

        // ICE both directions.
        ObjectNode candidate = node("candidate", "candidate:1 1 udp 1 1.2.3.4 5678 typ host",
                "sdpMid", "0", "sdpMLineIndex", 0);
        room.camera().send(node("type", "ice", "peerId", b.peerId(), "candidate", candidate.deepCopy()));
        assertEquals(node("type", "ice", "peerId", b.peerId(), "candidate", candidate.deepCopy()),
                b.parent().next());
        a.parent().expectSilence();

        b.parent().send(node("type", "ice", "peerId", b.peerId(), "candidate", candidate.deepCopy()));
        assertEquals(node("type", "ice", "peerId", b.peerId(), "candidate", candidate.deepCopy()),
                room.camera().next());

        room.camera().close();
        a.parent().close();
        b.parent().close();
    }

    @Test
    void iceRestartFromParentIsRelayedToCameraWithSenderPeerId() {
        RoomHandle room = newRoom();
        ParentHandle joined = joinParent(room.roomId(), room.camera());
        joined.parent().send(node("type", "ice-restart", "peerId", joined.peerId()));
        assertEquals(node("type", "ice-restart", "peerId", joined.peerId()), room.camera().next());
        room.camera().close();
        joined.parent().close();
    }

    @Test
    void parentCannotSpoofAnotherPeerId() {
        RoomHandle room = newRoom();
        ParentHandle a = joinParent(room.roomId(), room.camera());
        ParentHandle b = joinParent(room.roomId(), room.camera());
        a.parent().send(node("type", "ice-restart", "peerId", b.peerId()));
        JsonNode relayed = room.camera().next();
        assertEquals(a.peerId(), relayed.path("peerId").asText());
        room.camera().close();
        a.parent().close();
        b.parent().close();
    }

    @Test
    void hbAndNoiseFanOutFromCameraToAllParents() {
        RoomHandle room = newRoom();
        ParentHandle a = joinParent(room.roomId(), room.camera());
        ParentHandle b = joinParent(room.roomId(), room.camera());

        room.camera().send(node("type", "hb", "seq", 7, "ts", 1752710000000L, "audioLevel", 0.12));
        assertEquals(node("type", "hb", "seq", 7, "ts", 1752710000000L, "audioLevel", 0.12),
                a.parent().next());
        assertEquals(node("type", "hb", "seq", 7, "ts", 1752710000000L, "audioLevel", 0.12),
                b.parent().next());

        room.camera().send(node("type", "noise", "ts", 1752710003000L, "audioLevel", 0.8));
        assertEquals(node("type", "noise", "ts", 1752710003000L, "audioLevel", 0.8), a.parent().next());
        assertEquals(node("type", "noise", "ts", 1752710003000L, "audioLevel", 0.8), b.parent().next());

        room.camera().close();
        a.parent().close();
        b.parent().close();
    }

    @Test
    void cameraDisconnectBroadcastsCameraLeftAndReclaimRestoresRoom() {
        RoomHandle room = newRoom();
        ParentHandle joined = joinParent(room.roomId(), room.camera());

        room.camera().close();
        assertEquals(node("type", "camera-left"), joined.parent().next());

        // Camera reconnects and reclaims the same room.
        TestSupport.WsClient camera2 = TestSupport.WsClient.connect(srv.wsUrl());
        camera2.send(node("type", "create-room", "roomId", room.roomId(), "reclaimToken", room.reclaimToken()));
        assertEquals(node("type", "room-created", "roomId", room.roomId(), "reclaimToken", room.reclaimToken()),
                camera2.next());

        // The still-connected parent is re-announced so the camera re-offers.
        assertEquals(node("type", "peer-joined", "peerId", joined.peerId()), camera2.next());

        // Relay works again after reclaim.
        camera2.send(node("type", "offer", "peerId", joined.peerId(), "sdp", "post-reclaim", "sdpType", "offer"));
        assertEquals("post-reclaim", joined.parent().next().path("sdp").asText());

        camera2.close();
        joined.parent().close();
    }

    @Test
    void reclaimWithWrongTokenAnswersBadReclaimAndLeavesRoomIntact() {
        RoomHandle room = newRoom();
        TestSupport.WsClient impostor = TestSupport.WsClient.connect(srv.wsUrl());
        impostor.send(node("type", "create-room", "roomId", room.roomId(),
                "reclaimToken", "00000000-0000-0000-0000-000000000000"));
        JsonNode err = impostor.next();
        assertEquals("error", err.path("type").asText());
        assertEquals("BAD_RECLAIM", err.path("code").asText());
        // Original camera unaffected: a parent can still join.
        ParentHandle joined = joinParent(room.roomId(), room.camera());
        impostor.close();
        room.camera().close();
        joined.parent().close();
    }

    @Test
    void parentDisconnectSendsPeerLeftToCamera() {
        RoomHandle room = newRoom();
        ParentHandle joined = joinParent(room.roomId(), room.camera());
        joined.parent().close();
        assertEquals(node("type", "peer-left", "peerId", joined.peerId()), room.camera().next());
        room.camera().close();
    }

    @Test
    void parentCanRejoinWithPreviousPeerIdAfterDrop() {
        RoomHandle room = newRoom();
        ParentHandle joined = joinParent(room.roomId(), room.camera());
        joined.parent().close();
        assertEquals("peer-left", room.camera().next().path("type").asText());

        TestSupport.WsClient parent2 = TestSupport.WsClient.connect(srv.wsUrl());
        parent2.send(node("type", "join-room", "roomId", room.roomId(), "peerId", joined.peerId()));
        assertEquals(node("type", "room-joined", "roomId", room.roomId(), "peerId", joined.peerId()),
                parent2.next());
        assertEquals(node("type", "peer-joined", "peerId", joined.peerId()), room.camera().next());

        room.camera().close();
        parent2.close();
    }

    @Test
    void leaveMessageHasSameEffectAsClosingSocket() {
        RoomHandle room = newRoom();
        ParentHandle joined = joinParent(room.roomId(), room.camera());
        joined.parent().send(node("type", "leave"));
        assertEquals(node("type", "peer-left", "peerId", joined.peerId()), room.camera().next());
        room.camera().close();
        joined.parent().close();
    }

    @Test
    void malformedJsonAnswersBadMessageWithoutCrashingServer() {
        TestSupport.WsClient client = TestSupport.WsClient.connect(srv.wsUrl());
        client.sendRaw("{this is not json");
        JsonNode err = client.next();
        assertEquals("error", err.path("type").asText());
        assertEquals("BAD_MESSAGE", err.path("code").asText());

        // Server is still alive and functional on the same socket.
        client.send(node("type", "create-room"));
        assertEquals("room-created", client.next().path("type").asText());
        client.close();
    }

    @Test
    void unknownMessageTypesAreIgnored() {
        RoomHandle room = newRoom();
        room.camera().send(node("type", "telepathy", "payload", 42));
        room.camera().expectSilence();
        room.camera().close();
    }

    @Test
    void negotiationMessagesOutsideRoomAnswerNotInRoom() {
        TestSupport.WsClient client = TestSupport.WsClient.connect(srv.wsUrl());
        client.send(node("type", "offer", "peerId", "x", "sdp", "s", "sdpType", "offer"));
        JsonNode err = client.next();
        assertEquals("error", err.path("type").asText());
        assertEquals("NOT_IN_ROOM", err.path("code").asText());
        client.close();
    }

    @Test
    void roomsAreGarbageCollectedTenMinutesAfterBothSidesGone() {
        RoomHandle room = newRoom();
        room.camera().close();
        room.camera().awaitClosed();

        Signaling signaling = srv.app().signaling();
        assertTrue(signaling.hasRoom(room.roomId()), "room persists immediately after the camera leaves");
        // The server processes the socket close asynchronously — wait for it.
        waitFor(() -> signaling.roomEmptySince(room.roomId()) != null);
        long emptySince = signaling.roomEmptySince(room.roomId());

        // Not yet 10 minutes: gc must keep it.
        signaling.gcNow(Instant.ofEpochMilli(emptySince + 9 * 60 * 1000));
        assertTrue(signaling.hasRoom(room.roomId()));

        // 10+ minutes: gone.
        signaling.gcNow(Instant.ofEpochMilli(emptySince + 10 * 60 * 1000 + 1));
        assertFalse(signaling.hasRoom(room.roomId()));

        TestSupport.WsClient parent = TestSupport.WsClient.connect(srv.wsUrl());
        parent.send(node("type", "join-room", "roomId", room.roomId()));
        assertEquals("ROOM_NOT_FOUND", parent.next().path("code").asText());
        parent.close();
    }

    // ---- Trusted-device auth relay (docs/PROTOCOL.md §2.1, §2.2, §8.2) ----

    @Test
    void joinRoomAuthIsPassedThroughToCameraInPeerJoined() {
        RoomHandle room = newRoom();
        TestSupport.WsClient parent = TestSupport.WsClient.connect(srv.wsUrl());
        ObjectNode auth = node("deviceId", "abcdef0123456789", "pk", "pk-base64url", "nonce", "nonce-base64url");
        parent.send(node("type", "join-room", "roomId", room.roomId(), "auth", auth));
        JsonNode joined = parent.next();
        assertEquals("room-joined", joined.path("type").asText());
        String peerId = joined.get("peerId").asText();
        assertEquals(node("type", "peer-joined", "peerId", peerId, "auth", auth), room.camera().next());
        room.camera().close();
        parent.close();
    }

    @Test
    void joinRoomWithoutAuthYieldsPeerJoinedWithoutAuthKey() {
        RoomHandle room = newRoom();
        TestSupport.WsClient parent = TestSupport.WsClient.connect(srv.wsUrl());
        parent.send(node("type", "join-room", "roomId", room.roomId()));
        JsonNode joined = parent.next();
        String peerId = joined.get("peerId").asText();
        JsonNode notice = room.camera().next();
        assertEquals(node("type", "peer-joined", "peerId", peerId), notice);
        assertFalse(notice.has("auth"), "peer-joined must omit auth entirely when absent (never send null)");
        room.camera().close();
        parent.close();
    }

    @Test
    void authChallengeIsRelayedToAddressedParentOnly() {
        RoomHandle room = newRoom();
        ParentHandle a = joinParent(room.roomId(), room.camera());
        ParentHandle b = joinParent(room.roomId(), room.camera());
        room.camera().send(node("type", "auth-challenge", "peerId", a.peerId(), "nonce", "nonce-c", "sig", "sig-cam"));
        assertEquals(node("type", "auth-challenge", "peerId", a.peerId(), "nonce", "nonce-c", "sig", "sig-cam"),
                a.parent().next());
        b.parent().expectSilence();
        room.camera().close();
        a.parent().close();
        b.parent().close();
    }

    @Test
    void authResponseIsRelayedToCameraWithPeerIdStampedPayloadIntact() {
        RoomHandle room = newRoom();
        ParentHandle a = joinParent(room.roomId(), room.camera());
        ParentHandle b = joinParent(room.roomId(), room.camera());
        // Parent A addresses B's peerId; the server must stamp A's real id but leave
        // the deviceId/pk/sig payload untouched (§8.2, anti-spoofing like `answer`).
        a.parent().send(node("type", "auth-response", "peerId", b.peerId(),
                "deviceId", "dev-A", "pk", "pk-A", "sig", "sig-A"));
        assertEquals(node("type", "auth-response", "peerId", a.peerId(),
                "deviceId", "dev-A", "pk", "pk-A", "sig", "sig-A"), room.camera().next());
        room.camera().close();
        a.parent().close();
        b.parent().close();
    }

    @Test
    void authCapturedAtJoinIsResentInPeerJoinedAfterReclaim() {
        RoomHandle room = newRoom();
        TestSupport.WsClient parent = TestSupport.WsClient.connect(srv.wsUrl());
        ObjectNode auth = node("deviceId", "dev-1", "pk", "pk-1", "nonce", "nonce-1");
        parent.send(node("type", "join-room", "roomId", room.roomId(), "auth", auth));
        JsonNode joined = parent.next();
        String peerId = joined.get("peerId").asText();
        assertEquals(node("type", "peer-joined", "peerId", peerId, "auth", auth), room.camera().next());

        room.camera().close();
        assertEquals(node("type", "camera-left"), parent.next());

        TestSupport.WsClient camera2 = TestSupport.WsClient.connect(srv.wsUrl());
        camera2.send(node("type", "create-room", "roomId", room.roomId(), "reclaimToken", room.reclaimToken()));
        assertEquals("room-created", camera2.next().path("type").asText());
        assertEquals(node("type", "peer-joined", "peerId", peerId, "auth", auth), camera2.next());

        camera2.close();
        parent.close();
    }

    @Test
    void pairRequestIsNeverRelayedByCloudServer() {
        RoomHandle room = newRoom();
        ParentHandle joined = joinParent(room.roomId(), room.camera());
        joined.parent().send(node("type", "pair-request", "deviceId", "d", "name", "n", "pk", "p", "proof", "pf"));
        room.camera().expectSilence();
        joined.parent().expectSilence();
        // The connection is unharmed — a normal offer still relays afterwards.
        room.camera().send(node("type", "offer", "peerId", joined.peerId(), "sdp", "after-pair", "sdpType", "offer"));
        assertEquals("after-pair", joined.parent().next().path("sdp").asText());
        room.camera().close();
        joined.parent().close();
    }
}
