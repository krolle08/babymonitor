package com.babymonitor;

import io.javalin.Javalin;

import java.util.Map;

/**
 * Baby monitor server: WebSocket signaling on /ws + REST API on /api (docs/PROTOCOL.md).
 * One JVM process, one Fly.io deploy (TR7).
 *
 * Mirrors server/src/index.js createServer(): config is injectable and port 0 is
 * supported so tests can boot real instances with an in-memory DB.
 */
public final class Server {

    public static final int DEFAULT_PORT = 8080;
    public static final String DEFAULT_DB_PATH = "./data/babymonitor.db";

    private final int requestedPort;
    private final Db db;
    private final Signaling signaling;
    private final Javalin app;

    /** Env-driven configuration (PORT, DB_PATH — PROTOCOL §6). */
    public Server(Map<String, String> env) {
        this(env, portFromEnv(env), dbPathFromEnv(env));
    }

    /** Fully injectable: tests pass port 0 and dbPath ":memory:". */
    public Server(Map<String, String> env, int port, String dbPath) {
        this.requestedPort = port;
        this.db = new Db(dbPath);
        this.signaling = new Signaling();
        this.app = Javalin.create(config -> {
            config.showJavalinBanner = false;
            config.http.prefer405over404 = false;
        });

        Api.register(app, db, env);

        // WS only on /ws — an upgrade on any other path is refused with 404 (PROTOCOL §1),
        // which is Javalin's behaviour for unmatched ws paths.
        app.ws("/ws", ws -> {
            ws.onConnect(signaling::onConnect);
            ws.onMessage(ctx -> signaling.onMessage(ctx, ctx.message()));
            ws.onClose(signaling::onClose);
            ws.onError(ctx -> {
                // close event follows; never crash the process (NTR3)
            });
        });
    }

    /** Start listening; returns the bound port (useful with port 0). */
    public int start() {
        app.start(requestedPort);
        return app.port();
    }

    /** Stop everything: GC timer, WS clients, HTTP server, DB handle. */
    public void stop() {
        signaling.close();
        app.stop();
        db.close();
    }

    public Signaling signaling() {
        return signaling;
    }

    private static int portFromEnv(Map<String, String> env) {
        String port = env.get("PORT");
        return port == null || port.isEmpty() ? DEFAULT_PORT : Integer.parseInt(port);
    }

    private static String dbPathFromEnv(Map<String, String> env) {
        String dbPath = env.get("DB_PATH");
        return dbPath == null || dbPath.isEmpty() ? DEFAULT_DB_PATH : dbPath;
    }
}
