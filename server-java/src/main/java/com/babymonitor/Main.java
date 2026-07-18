package com.babymonitor;

/** Entry point: `java -jar babymonitor-server-all.jar` (mirrors `node src/index.js`). */
public final class Main {

    private Main() {}

    public static void main(String[] args) {
        var env = System.getenv();
        if (env.get("FAMILY_TOKEN") == null || env.get("FAMILY_TOKEN").isEmpty()) {
            System.err.println(
                    "WARNING: FAMILY_TOKEN is not set — all /api requests will be rejected (401).");
        }
        Server server = new Server(env);
        int port = server.start();
        System.out.println("babymonitor server listening on :" + port + " (ws: /ws, api: /api)");
        Runtime.getRuntime().addShutdownHook(new Thread(server::stop, "shutdown"));
    }
}
