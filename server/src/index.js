// Baby monitor server: WebSocket signaling on /ws + REST API on /api (docs/PROTOCOL.md).
// One Node.js process, one Fly.io deploy (TR7).
import http from 'node:http';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import { createDb } from './db.js';
import { createSignaling } from './signaling.js';
import { createApiHandler } from './api.js';

/**
 * Build the full server without listening. Tests boot it on port 0 with
 * dbPath ':memory:' and an injected env.
 */
export function createServer({
  env = process.env,
  port = Number(env.PORT ?? 8080),
  dbPath = env.DB_PATH ?? './data/babymonitor.db',
} = {}) {
  const db = createDb(dbPath);
  const signaling = createSignaling();
  const httpServer = http.createServer(createApiHandler({ db, env }));
  const wss = new WebSocketServer({ noServer: true });

  // WS upgrade only on /ws — anything else is refused (PROTOCOL §1).
  httpServer.on('upgrade', (req, socket, head) => {
    let pathname;
    try {
      pathname = new URL(req.url, 'http://localhost').pathname;
    } catch {
      socket.destroy();
      return;
    }
    if (pathname !== '/ws') {
      socket.write('HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => signaling.handleConnection(ws));
  });

  return {
    httpServer,
    db,
    signaling,

    /** Start listening; resolves with the bound port (useful with port 0). */
    start() {
      return new Promise((resolve, reject) => {
        httpServer.once('error', reject);
        httpServer.listen(port, () => resolve(httpServer.address().port));
      });
    },

    /** Stop everything: WS clients, HTTP server, GC timer, DB handle. */
    async stop() {
      signaling.close();
      for (const client of wss.clients) client.terminate();
      await new Promise((resolve) => wss.close(resolve));
      httpServer.closeAllConnections?.();
      await new Promise((resolve) => httpServer.close(resolve));
      db.close();
    },
  };
}

// Run directly: `node src/index.js`
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const app = createServer();
  if (!process.env.FAMILY_TOKEN) {
    console.warn('WARNING: FAMILY_TOKEN is not set — all /api requests will be rejected (401).');
  }
  app
    .start()
    .then((boundPort) => {
      console.log(`babymonitor server listening on :${boundPort} (ws: /ws, api: /api)`);
    })
    .catch((err) => {
      console.error('Failed to start server:', err);
      process.exit(1);
    });

  const shutdown = () => {
    app.stop().then(() => process.exit(0));
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
