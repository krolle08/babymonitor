package com.babymonitor;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.net.http.WebSocket;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.function.BooleanSupplier;

/**
 * Shared test helpers (port of server/test/helpers.js): ephemeral-port server boot,
 * a queueing WS client and a small REST helper — all on java.net.http.
 */
final class TestSupport {

    static final String TEST_TOKEN = "test-family-token";
    static final ObjectMapper MAPPER = new ObjectMapper();
    static final HttpClient HTTP = HttpClient.newHttpClient();

    private TestSupport() {}

    record TestServer(Server app, int port, String baseUrl, String wsUrl) {}

    /** Boot a real server on port 0 with an in-memory DB and an injected env. */
    static TestServer startTestServer(Map<String, String> extraEnv) {
        Map<String, String> env = new HashMap<>();
        env.put("FAMILY_TOKEN", TEST_TOKEN);
        env.putAll(extraEnv);
        Server app = new Server(env, 0, ":memory:");
        int port = app.start();
        return new TestServer(app, port, "http://127.0.0.1:" + port, "ws://127.0.0.1:" + port + "/ws");
    }

    /** Build a JSON object from key/value pairs (String/Integer/Long/Double/Boolean/JsonNode). */
    static ObjectNode node(Object... kv) {
        ObjectNode obj = MAPPER.createObjectNode();
        for (int i = 0; i < kv.length; i += 2) {
            String key = (String) kv[i];
            Object value = kv[i + 1];
            if (value == null) obj.putNull(key);
            else if (value instanceof String s) obj.put(key, s);
            else if (value instanceof Integer n) obj.put(key, n);
            else if (value instanceof Long n) obj.put(key, n);
            else if (value instanceof Double n) obj.put(key, n);
            else if (value instanceof Boolean b) obj.put(key, b);
            else if (value instanceof JsonNode j) obj.set(key, j);
            else throw new IllegalArgumentException("Unsupported value type: " + value.getClass());
        }
        return obj;
    }

    static JsonNode parse(String json) {
        try {
            return MAPPER.readTree(json);
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    /** Poll until the condition is true (e.g. the server processed a socket close). */
    static void waitFor(BooleanSupplier condition) {
        long deadline = System.currentTimeMillis() + 3000;
        while (!condition.getAsBoolean()) {
            if (System.currentTimeMillis() > deadline) throw new AssertionError("waitFor timed out");
            try {
                Thread.sleep(10);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new AssertionError("interrupted", e);
            }
        }
    }

    // ------------------------------------------------------------------ REST helper

    record ApiResponse(int status, JsonNode body) {}

    static ApiResponse api(String baseUrl, String method, String path) {
        return apiWithToken(baseUrl, method, path, TEST_TOKEN, null);
    }

    static ApiResponse api(String baseUrl, String method, String path, String jsonBody) {
        return apiWithToken(baseUrl, method, path, TEST_TOKEN, jsonBody);
    }

    static ApiResponse apiWithToken(String baseUrl, String method, String path, String token,
                                    String jsonBody) {
        try {
            HttpRequest.Builder builder = HttpRequest.newBuilder(URI.create(baseUrl + path));
            if (token != null) builder.header("Authorization", "Bearer " + token);
            if (jsonBody != null) {
                builder.header("Content-Type", "application/json");
                builder.method(method, HttpRequest.BodyPublishers.ofString(jsonBody));
            } else {
                builder.method(method, HttpRequest.BodyPublishers.noBody());
            }
            HttpResponse<String> res = HTTP.send(builder.build(), HttpResponse.BodyHandlers.ofString());
            String text = res.body();
            return new ApiResponse(res.statusCode(),
                    text == null || text.isEmpty() ? null : MAPPER.readTree(text));
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    // ------------------------------------------------------------------ WS client

    /** WebSocket client that queues incoming JSON frames so tests never race. */
    static final class WsClient implements WebSocket.Listener {
        private final BlockingQueue<String> frames = new LinkedBlockingQueue<>();
        private final StringBuilder partial = new StringBuilder();
        private final CountDownLatch closedLatch = new CountDownLatch(1);
        private volatile WebSocket ws;

        static WsClient connect(String url) {
            WsClient client = new WsClient();
            client.ws = HTTP.newWebSocketBuilder().buildAsync(URI.create(url), client).join();
            return client;
        }

        @Override
        public void onOpen(WebSocket webSocket) {
            webSocket.request(1);
        }

        @Override
        public CompletionStage<?> onText(WebSocket webSocket, CharSequence data, boolean last) {
            partial.append(data);
            if (last) {
                frames.add(partial.toString());
                partial.setLength(0);
            }
            webSocket.request(1);
            return null;
        }

        @Override
        public CompletionStage<?> onClose(WebSocket webSocket, int statusCode, String reason) {
            closedLatch.countDown();
            return null;
        }

        @Override
        public void onError(WebSocket webSocket, Throwable error) {
            closedLatch.countDown();
        }

        void send(ObjectNode obj) {
            sendRaw(obj.toString());
        }

        void sendRaw(String text) {
            ws.sendText(text, true).join();
        }

        /** Next JSON frame (queued or future), or fail after 3 s. */
        JsonNode next() {
            try {
                String frame = frames.poll(3000, TimeUnit.MILLISECONDS);
                if (frame == null) throw new AssertionError("timed out waiting for a WS message");
                return MAPPER.readTree(frame);
            } catch (AssertionError e) {
                throw e;
            } catch (Exception e) {
                throw new AssertionError(e);
            }
        }

        /** Assert that no frame arrives within 200 ms. */
        void expectSilence() {
            try {
                String frame = frames.poll(200, TimeUnit.MILLISECONDS);
                if (frame != null) {
                    throw new AssertionError("expected silence but received: " + frame);
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new AssertionError(e);
            }
        }

        void close() {
            try {
                ws.sendClose(WebSocket.NORMAL_CLOSURE, "").join();
            } catch (Exception ignored) {
                // already closed by the server
            }
        }

        /** Blocks until the socket is fully closed. */
        void awaitClosed() {
            try {
                if (!closedLatch.await(3, TimeUnit.SECONDS)) {
                    throw new AssertionError("timed out waiting for the socket to close");
                }
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new AssertionError(e);
            }
        }
    }
}
