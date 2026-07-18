package com.babymonitor;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.javalin.Javalin;
import io.javalin.http.Context;
import io.javalin.http.Handler;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * REST API for sleep sessions, events, flags and ICE config (docs/PROTOCOL.md §3, §6).
 * Faithful port of server/src/api.js: same routes, same status codes, same JSON field
 * names, same {error:{code,message}} envelope.
 */
final class Api {

    static final String DEFAULT_STUN_URL = "stun:stun.cloudflare.com:3478";

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String HANDLED_ATTR = "bm.apiHandled";

    private Api() {}

    /** HTTP error carrying the protocol's status + error code. */
    static final class HttpError extends RuntimeException {
        final int status;
        final String code;

        HttpError(int status, String code, String message) {
            super(message);
            this.status = status;
            this.code = code;
        }
    }

    static void register(Javalin app, Db db, Map<String, String> env) {
        // GET /healthz is unauthenticated (§3).
        app.get("/healthz", ctx -> {
            ObjectNode ok = MAPPER.createObjectNode();
            ok.put("ok", true);
            json(ctx, 200, ok);
        });

        // All /api routes require `Authorization: Bearer <FAMILY_TOKEN>` (§3).
        Handler auth = ctx -> {
            String token = env.get("FAMILY_TOKEN");
            // No configured token: nothing can match (§3 auth is mandatory).
            if (token == null || token.isEmpty()
                    || !("Bearer " + token).equals(ctx.header("Authorization"))) {
                throw new HttpError(401, "UNAUTHORIZED", "Missing or invalid bearer token");
            }
        };
        app.before("/api", auth);
        app.before("/api/*", auth);

        // GET /api/ice-config — TURN/STUN served at runtime so creds never ship in the binary (§6).
        app.get("/api/ice-config", ctx -> json(ctx, 200, iceConfig(env)));

        // POST /api/sessions — open a monitoring session (§3.1).
        app.post("/api/sessions", ctx -> {
            JsonNode body = readJsonBody(ctx);
            int id = db.createSession(
                    requireString(body, "deviceId"),
                    requireString(body, "roomId"),
                    requireString(body, "startedAt"));
            ObjectNode result = MAPPER.createObjectNode();
            result.put("id", id);
            json(ctx, 201, result);
        });

        // GET /api/sessions?from&to — list with eventCounts (§3.1).
        app.get("/api/sessions", ctx ->
                json(ctx, 200, db.listSessions(ctx.queryParam("from"), ctx.queryParam("to"))));

        // PATCH /api/sessions/{id} — close a session (§3.1).
        app.patch("/api/sessions/{id}", ctx -> {
            int id = pathId(ctx);
            JsonNode body = readJsonBody(ctx);
            String endedAt = requireString(body, "endedAt");
            if (!db.endSession(id, endedAt)) {
                throw new HttpError(404, "NOT_FOUND", "No session " + id);
            }
            ObjectNode result = MAPPER.createObjectNode();
            result.put("id", id);
            json(ctx, 200, result);
        });

        // GET /api/sessions/{id} — full event list (§3.1).
        app.get("/api/sessions/{id}", ctx -> {
            int id = pathId(ctx);
            ObjectNode session = db.getSession(id);
            if (session == null) throw new HttpError(404, "NOT_FOUND", "No session " + id);
            json(ctx, 200, session);
        });

        // POST /api/sessions/{id}/events — batch upload from the offline queue (§3.2).
        app.post("/api/sessions/{id}/events", ctx -> {
            int id = pathId(ctx);
            if (!db.sessionExists(id)) throw new HttpError(404, "NOT_FOUND", "No session " + id);
            JsonNode body = readJsonBody(ctx);
            if (!body.isArray()) {
                throw new HttpError(400, "BAD_REQUEST", "Body must be a JSON array of events");
            }
            List<Db.Event> events = new ArrayList<>();
            for (int i = 0; i < body.size(); i++) {
                JsonNode e = body.get(i);
                if (e == null || !e.isObject()) {
                    throw new HttpError(400, "BAD_REQUEST", "Event " + i + " must be an object");
                }
                JsonNode data = e.get("data");
                if (data == null || data.isNull()) data = MAPPER.createObjectNode();
                if (!data.isObject()) {
                    throw new HttpError(400, "BAD_REQUEST", "Event " + i + " \"data\" must be an object");
                }
                // Unknown type values are stored verbatim (forward compatible, §3.2).
                events.add(new Db.Event(
                        requireString(e, "type"), requireString(e, "at"), data.toString()));
            }
            ObjectNode result = MAPPER.createObjectNode();
            result.put("inserted", db.insertEvents(id, events));
            json(ctx, 201, result);
        });

        // POST /api/flags — annotate a date (§3.3).
        app.post("/api/flags", ctx -> {
            JsonNode body = readJsonBody(ctx);
            JsonNode note = body.get("note");
            if (note != null && !note.isNull() && !note.isTextual()) {
                throw new HttpError(400, "BAD_REQUEST", "Field \"note\" must be a string");
            }
            int id = db.createFlag(
                    requireString(body, "date"),
                    requireString(body, "label"),
                    note == null || note.isNull() ? null : note.asText());
            ObjectNode result = MAPPER.createObjectNode();
            result.put("id", id);
            json(ctx, 201, result);
        });

        // GET /api/flags?from&to (§3.3).
        app.get("/api/flags", ctx ->
                json(ctx, 200, db.listFlags(ctx.queryParam("from"), ctx.queryParam("to"))));

        // DELETE /api/flags/{id} (§3.3).
        app.delete("/api/flags/{id}", ctx -> {
            int id = pathId(ctx);
            if (!db.deleteFlag(id)) {
                throw new HttpError(404, "NOT_FOUND", "No flag " + id);
            }
            ctx.status(204);
            ctx.attribute(HANDLED_ATTR, true);
        });

        // Error envelope {error:{code,message}} (§3.4).
        app.exception(HttpError.class, (e, ctx) -> writeError(ctx, e.status, e.code, e.getMessage()));
        app.exception(Exception.class, (e, ctx) ->
                writeError(ctx, 500, "INTERNAL", "Internal server error"));

        // Unmatched routes get the same envelope the Node server produces.
        app.error(404, ctx -> {
            if (ctx.attribute(HANDLED_ATTR) == null) {
                writeError(ctx, 404, "NOT_FOUND", "No route for " + ctx.method() + " " + ctx.path());
            }
        });
    }

    // ------------------------------------------------------------------ helpers

    private static void json(Context ctx, int status, JsonNode body) {
        ctx.status(status);
        ctx.contentType("application/json; charset=utf-8");
        ctx.result(body.toString());
        ctx.attribute(HANDLED_ATTR, true);
    }

    private static void writeError(Context ctx, int status, String code, String message) {
        ObjectNode envelope = MAPPER.createObjectNode();
        ObjectNode error = envelope.putObject("error");
        error.put("code", code);
        error.put("message", message);
        json(ctx, status, envelope);
    }

    /** Body must be non-empty, valid JSON — mirrors api.js readJsonBody. */
    private static JsonNode readJsonBody(Context ctx) {
        String text = ctx.body();
        if (text.isEmpty()) {
            throw new HttpError(400, "BAD_REQUEST", "Request body required");
        }
        try {
            JsonNode node = MAPPER.readTree(text);
            if (node == null) throw new IllegalArgumentException("empty");
            return node;
        } catch (Exception e) {
            throw new HttpError(400, "BAD_REQUEST", "Request body is not valid JSON");
        }
    }

    private static String requireString(JsonNode obj, String field) {
        JsonNode value = obj == null ? null : obj.get(field);
        if (value == null || !value.isTextual() || value.asText().isEmpty()) {
            throw new HttpError(400, "BAD_REQUEST",
                    "Field \"" + field + "\" must be a non-empty string");
        }
        return value.asText();
    }

    /**
     * Numeric path id. The Node routes only match \d+ ids — anything else falls
     * through to the 404 "No route" response, which we reproduce here.
     */
    private static int pathId(Context ctx) {
        String raw = ctx.pathParam("id");
        if (!raw.matches("\\d+")) {
            throw new HttpError(404, "NOT_FOUND", "No route for " + ctx.method() + " " + ctx.path());
        }
        try {
            return Integer.parseInt(raw);
        } catch (NumberFormatException e) {
            // Larger than any AUTOINCREMENT id we could have handed out.
            return Integer.MAX_VALUE;
        }
    }

    /** {iceServers:[{urls,username?,credential?}]} from TURN_x/STUN_URL env (§6). */
    private static ObjectNode iceConfig(Map<String, String> env) {
        ObjectNode config = MAPPER.createObjectNode();
        ArrayNode iceServers = config.putArray("iceServers");
        String stunUrl = env.get("STUN_URL");
        ObjectNode stun = iceServers.addObject();
        stun.put("urls", stunUrl == null || stunUrl.isEmpty() ? DEFAULT_STUN_URL : stunUrl);
        String turnUrl = env.get("TURN_URL");
        if (turnUrl != null && !turnUrl.isEmpty()) {
            ObjectNode turn = iceServers.addObject();
            turn.put("urls", turnUrl);
            String username = env.get("TURN_USERNAME");
            if (username != null && !username.isEmpty()) turn.put("username", username);
            String credential = env.get("TURN_CREDENTIAL");
            if (credential != null && !credential.isEmpty()) turn.put("credential", credential);
        }
        return config;
    }
}
