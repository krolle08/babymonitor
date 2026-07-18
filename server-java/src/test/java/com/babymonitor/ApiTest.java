package com.babymonitor;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.stream.StreamSupport;

import static com.babymonitor.TestSupport.api;
import static com.babymonitor.TestSupport.apiWithToken;
import static com.babymonitor.TestSupport.parse;
import static com.babymonitor.TestSupport.startTestServer;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** REST API tests (docs/PROTOCOL.md §3, §6) — port of server/test/api.test.js. */
class ApiTest {

    private static TestSupport.TestServer srv;

    @BeforeAll
    static void boot() {
        srv = startTestServer(Map.of(
                "STUN_URL", "stun:stun.example.test:3478",
                "TURN_URL", "turn:turn.example.test:3478?transport=udp",
                "TURN_USERNAME", "turn-user",
                "TURN_CREDENTIAL", "turn-pass"));
    }

    @AfterAll
    static void shutdown() {
        srv.app().stop();
    }

    private static JsonNode findById(JsonNode array, int id) {
        return StreamSupport.stream(array.spliterator(), false)
                .filter(s -> s.path("id").asInt() == id)
                .findFirst()
                .orElse(null);
    }

    @Test
    void healthzIsUnauthenticatedAndReturnsOkTrue() {
        var res = apiWithToken(srv.baseUrl(), "GET", "/healthz", null, null);
        assertEquals(200, res.status());
        assertEquals(parse("{\"ok\":true}"), res.body());
    }

    @Test
    void apiRoutesRejectMissingOrWrongBearerTokensWith401() {
        var noToken = apiWithToken(srv.baseUrl(), "GET", "/api/sessions", null, null);
        assertEquals(401, noToken.status());
        assertEquals("UNAUTHORIZED", noToken.body().at("/error/code").asText());

        var wrongToken = apiWithToken(srv.baseUrl(), "GET", "/api/flags", "wrong-token", null);
        assertEquals(401, wrongToken.status());

        var wrongOnPost = apiWithToken(srv.baseUrl(), "POST", "/api/sessions", "wrong-token",
                "{\"deviceId\":\"d\",\"roomId\":\"ABC234\",\"startedAt\":\"2026-07-17T20:00:00.000Z\"}");
        assertEquals(401, wrongOnPost.status());

        var iceNoAuth = apiWithToken(srv.baseUrl(), "GET", "/api/ice-config", null, null);
        assertEquals(401, iceNoAuth.status());
    }

    @Test
    void sessionLifecyclePostCreatePatchCloseGetListAndGetById() {
        var created = api(srv.baseUrl(), "POST", "/api/sessions",
                "{\"deviceId\":\"cam-1\",\"roomId\":\"ABC234\",\"startedAt\":\"2026-07-15T19:00:00.000Z\"}");
        assertEquals(201, created.status());
        assertTrue(created.body().path("id").isInt(), "id is a number");
        int id = created.body().get("id").asInt();

        var patched = api(srv.baseUrl(), "PATCH", "/api/sessions/" + id,
                "{\"endedAt\":\"2026-07-16T06:30:00.000Z\"}");
        assertEquals(200, patched.status());
        assertEquals(parse("{\"id\":" + id + "}"), patched.body());

        var list = api(srv.baseUrl(), "GET",
                "/api/sessions?from=2026-07-15T00:00:00.000Z&to=2026-07-16T23:59:59.000Z");
        assertEquals(200, list.status());
        JsonNode session = findById(list.body(), id);
        assertEquals(parse("""
                {"id":%d,"deviceId":"cam-1","roomId":"ABC234",
                 "startedAt":"2026-07-15T19:00:00.000Z","endedAt":"2026-07-16T06:30:00.000Z",
                 "eventCounts":{"noise":0,"freeze":0,"reconnect":0}}""".formatted(id)), session);

        var byId = api(srv.baseUrl(), "GET", "/api/sessions/" + id);
        assertEquals(200, byId.status());
        assertEquals(id, byId.body().path("id").asInt());
        assertEquals(parse("[]"), byId.body().get("events"));
    }

    @Test
    void listSessionsFiltersOnStartedAt() {
        int early = api(srv.baseUrl(), "POST", "/api/sessions",
                "{\"deviceId\":\"cam-1\",\"roomId\":\"FLT234\",\"startedAt\":\"2026-01-01T20:00:00.000Z\"}")
                .body().get("id").asInt();
        int mid = api(srv.baseUrl(), "POST", "/api/sessions",
                "{\"deviceId\":\"cam-1\",\"roomId\":\"FLT234\",\"startedAt\":\"2026-01-02T20:00:00.000Z\"}")
                .body().get("id").asInt();
        int late = api(srv.baseUrl(), "POST", "/api/sessions",
                "{\"deviceId\":\"cam-1\",\"roomId\":\"FLT234\",\"startedAt\":\"2026-01-03T20:00:00.000Z\"}")
                .body().get("id").asInt();

        var res = api(srv.baseUrl(), "GET",
                "/api/sessions?from=2026-01-02T00:00:00.000Z&to=2026-01-02T23:59:59.000Z");
        assertNotNull(findById(res.body(), mid));
        assertNull(findById(res.body(), early));
        assertNull(findById(res.body(), late));
    }

    @Test
    void patchOfUnknownSessionReturns404() {
        var res = api(srv.baseUrl(), "PATCH", "/api/sessions/999999",
                "{\"endedAt\":\"2026-07-16T06:30:00.000Z\"}");
        assertEquals(404, res.status());
        assertEquals("NOT_FOUND", res.body().at("/error/code").asText());
    }

    @Test
    void eventBatchInsertReturnsInsertedCountAndFeedsEventCounts() {
        var created = api(srv.baseUrl(), "POST", "/api/sessions",
                "{\"deviceId\":\"cam-1\",\"roomId\":\"EVT234\",\"startedAt\":\"2026-07-16T19:00:00.000Z\"}");
        int id = created.body().get("id").asInt();

        String events = """
                [
                  {"type":"noise","at":"2026-07-16T20:00:00.000Z","data":{"audioLevel":0.7}},
                  {"type":"noise","at":"2026-07-16T21:00:00.000Z","data":{"audioLevel":0.4}},
                  {"type":"freeze","at":"2026-07-16T22:00:00.000Z","data":{}},
                  {"type":"reconnect","at":"2026-07-16T22:00:10.000Z","data":{}},
                  {"type":"state","at":"2026-07-16T22:00:12.000Z","data":{"from":"reconnecting","to":"connected"}},
                  {"type":"latency","at":"2026-07-16T19:00:05.000Z","data":{"ms":2300}},
                  {"type":"future-thing","at":"2026-07-16T23:00:00.000Z","data":{"anything":true}}
                ]""";
        var inserted = api(srv.baseUrl(), "POST", "/api/sessions/" + id + "/events", events);
        assertEquals(201, inserted.status());
        assertEquals(parse("{\"inserted\":7}"), inserted.body());

        var list = api(srv.baseUrl(), "GET",
                "/api/sessions?from=2026-07-16T00:00:00.000Z&to=2026-07-16T23:59:59.000Z");
        JsonNode session = findById(list.body(), id);
        assertEquals(2, session.at("/eventCounts/noise").asInt());
        assertEquals(1, session.at("/eventCounts/freeze").asInt());
        assertEquals(1, session.at("/eventCounts/reconnect").asInt());

        var byId = api(srv.baseUrl(), "GET", "/api/sessions/" + id);
        assertEquals(7, byId.body().get("events").size());
        boolean noiseRoundTrips = StreamSupport.stream(byId.body().get("events").spliterator(), false)
                .anyMatch(e -> "noise".equals(e.path("type").asText())
                        && e.at("/data/audioLevel").asDouble() == 0.7);
        assertTrue(noiseRoundTrips, "noise event data round-trips");
        JsonNode unknown = StreamSupport.stream(byId.body().get("events").spliterator(), false)
                .filter(e -> "future-thing".equals(e.path("type").asText()))
                .findFirst().orElseThrow();
        assertEquals(parse("{\"anything\":true}"), unknown.get("data"), "unknown types stored verbatim");
    }

    @Test
    void eventUploadToUnknownSessionReturns404AndNonArrayBodyReturns400() {
        var notFound = api(srv.baseUrl(), "POST", "/api/sessions/999999/events",
                "[{\"type\":\"noise\",\"at\":\"2026-07-16T20:00:00.000Z\",\"data\":{}}]");
        assertEquals(404, notFound.status());

        var created = api(srv.baseUrl(), "POST", "/api/sessions",
                "{\"deviceId\":\"cam-1\",\"roomId\":\"BAD234\",\"startedAt\":\"2026-07-16T19:00:00.000Z\"}");
        var badBody = api(srv.baseUrl(), "POST",
                "/api/sessions/" + created.body().get("id").asInt() + "/events",
                "{\"type\":\"noise\",\"at\":\"2026-07-16T20:00:00.000Z\"}");
        assertEquals(400, badBody.status());
        assertEquals("BAD_REQUEST", badBody.body().at("/error/code").asText());
    }

    @Test
    void malformedJsonBodyReturns400WithErrorEnvelope() {
        var res = api(srv.baseUrl(), "POST", "/api/sessions", "{broken");
        assertEquals(400, res.status());
        assertEquals("BAD_REQUEST", res.body().at("/error/code").asText());
    }

    @Test
    void flagsCrudPostGetWithRangeFilterDelete() {
        var created = api(srv.baseUrl(), "POST", "/api/flags",
                "{\"date\":\"2026-07-14\",\"label\":\"Teething\",\"note\":\"front tooth\"}");
        assertEquals(201, created.status());
        assertTrue(created.body().path("id").isInt(), "id is a number");
        int id = created.body().get("id").asInt();

        var noNote = api(srv.baseUrl(), "POST", "/api/flags",
                "{\"date\":\"2026-07-20\",\"label\":\"Travel\"}");
        assertEquals(201, noNote.status());

        var inRange = api(srv.baseUrl(), "GET", "/api/flags?from=2026-07-10&to=2026-07-15");
        assertEquals(200, inRange.status());
        assertEquals(parse("[{\"id\":" + id
                + ",\"date\":\"2026-07-14\",\"label\":\"Teething\",\"note\":\"front tooth\"}]"),
                inRange.body());

        var all = api(srv.baseUrl(), "GET", "/api/flags");
        boolean travelNoteNull = StreamSupport.stream(all.body().spliterator(), false)
                .anyMatch(f -> "Travel".equals(f.path("label").asText()) && f.get("note").isNull());
        assertTrue(travelNoteNull);

        var deleted = api(srv.baseUrl(), "DELETE", "/api/flags/" + id);
        assertEquals(204, deleted.status());
        assertNull(deleted.body());

        var afterDelete = api(srv.baseUrl(), "GET", "/api/flags?from=2026-07-10&to=2026-07-15");
        assertEquals(parse("[]"), afterDelete.body());

        var deleteAgain = api(srv.baseUrl(), "DELETE", "/api/flags/" + id);
        assertEquals(404, deleteAgain.status());
    }

    @Test
    void missingRequiredFieldsReturn400() {
        var res = api(srv.baseUrl(), "POST", "/api/flags", "{\"date\":\"2026-07-14\"}");
        assertEquals(400, res.status());
        assertEquals("BAD_REQUEST", res.body().at("/error/code").asText());
    }

    @Test
    void iceConfigServesStunAndTurnFromEnv() {
        var res = api(srv.baseUrl(), "GET", "/api/ice-config");
        assertEquals(200, res.status());
        assertEquals(parse("""
                {"iceServers":[
                  {"urls":"stun:stun.example.test:3478"},
                  {"urls":"turn:turn.example.test:3478?transport=udp",
                   "username":"turn-user","credential":"turn-pass"}
                ]}"""), res.body());
    }

    @Test
    void iceConfigWithoutTurnEnvFallsBackToStunOnly() {
        TestSupport.TestServer plain = startTestServer(Map.of()); // no TURN_*, no STUN_URL override
        try {
            var res = api(plain.baseUrl(), "GET", "/api/ice-config");
            assertEquals(200, res.status());
            assertEquals(parse("{\"iceServers\":[{\"urls\":\"stun:stun.cloudflare.com:3478\"}]}"),
                    res.body());
        } finally {
            plain.app().stop();
        }
    }

    @Test
    void unknownRoutesReturn404WithErrorEnvelope() {
        var res = api(srv.baseUrl(), "GET", "/api/nope");
        assertEquals(404, res.status());
        assertEquals("NOT_FOUND", res.body().at("/error/code").asText());
    }
}
