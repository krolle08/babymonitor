// Shared test helpers: ephemeral-port server boot + a queueing WS client.
// (Not named *.test.js, so node --test does not run this file as a suite.)
import { WebSocket } from 'ws';
import { createServer } from '../src/index.js';

export const TEST_TOKEN = 'test-family-token';

/** Boot a real server on port 0 with an in-memory DB and an injected env. */
export async function startTestServer(extraEnv = {}) {
  const env = { FAMILY_TOKEN: TEST_TOKEN, ...extraEnv };
  const app = createServer({ env, port: 0, dbPath: ':memory:' });
  const port = await app.start();
  return {
    app,
    port,
    baseUrl: `http://127.0.0.1:${port}`,
    wsUrl: `ws://127.0.0.1:${port}/ws`,
  };
}

/** WebSocket client that queues incoming JSON frames so tests never race. */
export class WsClient {
  constructor(ws) {
    this.ws = ws;
    this.queue = [];
    this.waiters = [];
    ws.on('message', (data) => {
      const msg = JSON.parse(data.toString());
      const waiter = this.waiters.shift();
      if (waiter) waiter.resolve(msg);
      else this.queue.push(msg);
    });
  }

  static connect(url) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      ws.once('open', () => resolve(new WsClient(ws)));
      ws.once('error', reject);
    });
  }

  send(obj) {
    this.ws.send(JSON.stringify(obj));
  }

  sendRaw(text) {
    this.ws.send(text);
  }

  /** Next JSON frame (queued or future), or reject after `timeout` ms. */
  next(timeout = 3000) {
    if (this.queue.length > 0) return Promise.resolve(this.queue.shift());
    return new Promise((resolve, reject) => {
      const waiter = {};
      const timer = setTimeout(() => {
        const i = this.waiters.indexOf(waiter);
        if (i !== -1) this.waiters.splice(i, 1);
        reject(new Error(`timed out after ${timeout}ms waiting for a WS message`));
      }, timeout);
      waiter.resolve = (msg) => {
        clearTimeout(timer);
        resolve(msg);
      };
      this.waiters.push(waiter);
    });
  }

  /** Assert that no frame arrives within `ms`. */
  async expectSilence(ms = 200) {
    await new Promise((r) => setTimeout(r, ms));
    if (this.queue.length > 0) {
      throw new Error(`expected silence but received: ${JSON.stringify(this.queue[0])}`);
    }
  }

  close() {
    this.ws.close();
  }

  /** Resolves once the socket is fully closed. */
  closed() {
    if (this.ws.readyState === WebSocket.CLOSED) return Promise.resolve();
    return new Promise((resolve) => this.ws.once('close', resolve));
  }
}

/** Poll until `fn()` is truthy (e.g. the server processed a socket close). */
export async function waitFor(fn, { timeout = 3000, interval = 10 } = {}) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const value = fn();
    if (value) return value;
    if (Date.now() > deadline) throw new Error('waitFor timed out');
    await new Promise((r) => setTimeout(r, interval));
  }
}

/** Small fetch wrapper for the REST API with bearer auth. */
export async function api(baseUrl, method, path, { body, token = TEST_TOKEN } = {}) {
  const headers = {};
  if (token !== null) headers.authorization = `Bearer ${token}`;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const res = await fetch(`${baseUrl}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  return { status: res.status, body: text === '' ? null : JSON.parse(text) };
}
