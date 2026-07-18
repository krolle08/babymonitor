// REST API tests (docs/PROTOCOL.md §3, §6) against a real server on an ephemeral port.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, api } from './helpers.js';

let srv;

before(async () => {
  srv = await startTestServer({
    STUN_URL: 'stun:stun.example.test:3478',
    TURN_URL: 'turn:turn.example.test:3478?transport=udp',
    TURN_USERNAME: 'turn-user',
    TURN_CREDENTIAL: 'turn-pass',
  });
});

after(async () => {
  await srv.app.stop();
});

test('GET /healthz is unauthenticated and returns {ok:true}', async () => {
  const res = await fetch(`${srv.baseUrl}/healthz`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { ok: true });
});

test('all /api routes reject missing or wrong bearer tokens with 401', async () => {
  const noToken = await api(srv.baseUrl, 'GET', '/api/sessions', { token: null });
  assert.equal(noToken.status, 401);
  assert.equal(noToken.body.error.code, 'UNAUTHORIZED');

  const wrongToken = await api(srv.baseUrl, 'GET', '/api/flags', { token: 'wrong-token' });
  assert.equal(wrongToken.status, 401);

  const wrongOnPost = await api(srv.baseUrl, 'POST', '/api/sessions', {
    token: 'wrong-token',
    body: { deviceId: 'd', roomId: 'ABC234', startedAt: '2026-07-17T20:00:00.000Z' },
  });
  assert.equal(wrongOnPost.status, 401);

  const iceNoAuth = await api(srv.baseUrl, 'GET', '/api/ice-config', { token: null });
  assert.equal(iceNoAuth.status, 401);
});

test('session lifecycle: POST create, PATCH close, GET list and GET by id', async () => {
  const created = await api(srv.baseUrl, 'POST', '/api/sessions', {
    body: { deviceId: 'cam-1', roomId: 'ABC234', startedAt: '2026-07-15T19:00:00.000Z' },
  });
  assert.equal(created.status, 201);
  const id = created.body.id;
  assert.equal(typeof id, 'number');

  const patched = await api(srv.baseUrl, 'PATCH', `/api/sessions/${id}`, {
    body: { endedAt: '2026-07-16T06:30:00.000Z' },
  });
  assert.equal(patched.status, 200);
  assert.deepEqual(patched.body, { id });

  const list = await api(srv.baseUrl, 'GET', '/api/sessions?from=2026-07-15T00:00:00.000Z&to=2026-07-16T23:59:59.000Z');
  assert.equal(list.status, 200);
  const session = list.body.find((s) => s.id === id);
  assert.deepEqual(session, {
    id,
    deviceId: 'cam-1',
    roomId: 'ABC234',
    startedAt: '2026-07-15T19:00:00.000Z',
    endedAt: '2026-07-16T06:30:00.000Z',
    eventCounts: { noise: 0, freeze: 0, reconnect: 0 },
  });

  const byId = await api(srv.baseUrl, 'GET', `/api/sessions/${id}`);
  assert.equal(byId.status, 200);
  assert.equal(byId.body.id, id);
  assert.deepEqual(byId.body.events, []);
});

test('GET /api/sessions?from&to filters on startedAt', async () => {
  const mk = (startedAt) =>
    api(srv.baseUrl, 'POST', '/api/sessions', {
      body: { deviceId: 'cam-1', roomId: 'FLT234', startedAt },
    });
  const early = (await mk('2026-01-01T20:00:00.000Z')).body.id;
  const mid = (await mk('2026-01-02T20:00:00.000Z')).body.id;
  const late = (await mk('2026-01-03T20:00:00.000Z')).body.id;

  const res = await api(srv.baseUrl, 'GET', '/api/sessions?from=2026-01-02T00:00:00.000Z&to=2026-01-02T23:59:59.000Z');
  const ids = res.body.map((s) => s.id);
  assert.ok(ids.includes(mid));
  assert.ok(!ids.includes(early));
  assert.ok(!ids.includes(late));
});

test('PATCH of an unknown session returns 404', async () => {
  const res = await api(srv.baseUrl, 'PATCH', '/api/sessions/999999', {
    body: { endedAt: '2026-07-16T06:30:00.000Z' },
  });
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');
});

test('event batch insert returns {inserted:n} and feeds eventCounts', async () => {
  const created = await api(srv.baseUrl, 'POST', '/api/sessions', {
    body: { deviceId: 'cam-1', roomId: 'EVT234', startedAt: '2026-07-16T19:00:00.000Z' },
  });
  const id = created.body.id;

  const events = [
    { type: 'noise', at: '2026-07-16T20:00:00.000Z', data: { audioLevel: 0.7 } },
    { type: 'noise', at: '2026-07-16T21:00:00.000Z', data: { audioLevel: 0.4 } },
    { type: 'freeze', at: '2026-07-16T22:00:00.000Z', data: {} },
    { type: 'reconnect', at: '2026-07-16T22:00:10.000Z', data: {} },
    { type: 'state', at: '2026-07-16T22:00:12.000Z', data: { from: 'reconnecting', to: 'connected' } },
    { type: 'latency', at: '2026-07-16T19:00:05.000Z', data: { ms: 2300 } },
    { type: 'future-thing', at: '2026-07-16T23:00:00.000Z', data: { anything: true } },
  ];
  const inserted = await api(srv.baseUrl, 'POST', `/api/sessions/${id}/events`, { body: events });
  assert.equal(inserted.status, 201);
  assert.deepEqual(inserted.body, { inserted: 7 });

  const list = await api(srv.baseUrl, 'GET', '/api/sessions?from=2026-07-16T00:00:00.000Z&to=2026-07-16T23:59:59.000Z');
  const session = list.body.find((s) => s.id === id);
  assert.equal(session.eventCounts.noise, 2);
  assert.equal(session.eventCounts.freeze, 1);
  assert.equal(session.eventCounts.reconnect, 1);

  const byId = await api(srv.baseUrl, 'GET', `/api/sessions/${id}`);
  assert.equal(byId.body.events.length, 7);
  const noise = byId.body.events.find((e) => e.type === 'noise' && e.data.audioLevel === 0.7);
  assert.ok(noise, 'noise event data round-trips');
  const unknown = byId.body.events.find((e) => e.type === 'future-thing');
  assert.deepEqual(unknown.data, { anything: true }, 'unknown types stored verbatim');
});

test('event upload to an unknown session returns 404; non-array body returns 400', async () => {
  const notFound = await api(srv.baseUrl, 'POST', '/api/sessions/999999/events', {
    body: [{ type: 'noise', at: '2026-07-16T20:00:00.000Z', data: {} }],
  });
  assert.equal(notFound.status, 404);

  const created = await api(srv.baseUrl, 'POST', '/api/sessions', {
    body: { deviceId: 'cam-1', roomId: 'BAD234', startedAt: '2026-07-16T19:00:00.000Z' },
  });
  const badBody = await api(srv.baseUrl, 'POST', `/api/sessions/${created.body.id}/events`, {
    body: { type: 'noise', at: '2026-07-16T20:00:00.000Z' },
  });
  assert.equal(badBody.status, 400);
  assert.equal(badBody.body.error.code, 'BAD_REQUEST');
});

test('malformed JSON body returns 400 with the error envelope', async () => {
  const res = await fetch(`${srv.baseUrl}/api/sessions`, {
    method: 'POST',
    headers: { authorization: 'Bearer test-family-token', 'content-type': 'application/json' },
    body: '{broken',
  });
  assert.equal(res.status, 400);
  const body = await res.json();
  assert.equal(body.error.code, 'BAD_REQUEST');
});

test('flags CRUD: POST, GET with range filter, DELETE', async () => {
  const created = await api(srv.baseUrl, 'POST', '/api/flags', {
    body: { date: '2026-07-14', label: 'Teething', note: 'front tooth' },
  });
  assert.equal(created.status, 201);
  const id = created.body.id;
  assert.equal(typeof id, 'number');

  const noNote = await api(srv.baseUrl, 'POST', '/api/flags', {
    body: { date: '2026-07-20', label: 'Travel' },
  });
  assert.equal(noNote.status, 201);

  const inRange = await api(srv.baseUrl, 'GET', '/api/flags?from=2026-07-10&to=2026-07-15');
  assert.equal(inRange.status, 200);
  assert.deepEqual(inRange.body, [{ id, date: '2026-07-14', label: 'Teething', note: 'front tooth' }]);

  const all = await api(srv.baseUrl, 'GET', '/api/flags');
  assert.ok(all.body.some((f) => f.label === 'Travel' && f.note === null));

  const deleted = await api(srv.baseUrl, 'DELETE', `/api/flags/${id}`);
  assert.equal(deleted.status, 204);
  assert.equal(deleted.body, null);

  const afterDelete = await api(srv.baseUrl, 'GET', '/api/flags?from=2026-07-10&to=2026-07-15');
  assert.deepEqual(afterDelete.body, []);

  const deleteAgain = await api(srv.baseUrl, 'DELETE', `/api/flags/${id}`);
  assert.equal(deleteAgain.status, 404);
});

test('missing required fields return 400', async () => {
  const res = await api(srv.baseUrl, 'POST', '/api/flags', { body: { date: '2026-07-14' } });
  assert.equal(res.status, 400);
  assert.equal(res.body.error.code, 'BAD_REQUEST');
});

test('GET /api/ice-config serves STUN + TURN from env', async () => {
  const res = await api(srv.baseUrl, 'GET', '/api/ice-config');
  assert.equal(res.status, 200);
  assert.deepEqual(res.body, {
    iceServers: [
      { urls: 'stun:stun.example.test:3478' },
      {
        urls: 'turn:turn.example.test:3478?transport=udp',
        username: 'turn-user',
        credential: 'turn-pass',
      },
    ],
  });
});

test('GET /api/ice-config without TURN env falls back to STUN only', async () => {
  const plain = await startTestServer(); // no TURN_*, no STUN_URL override
  try {
    const res = await api(plain.baseUrl, 'GET', '/api/ice-config');
    assert.equal(res.status, 200);
    assert.deepEqual(res.body, { iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }] });
  } finally {
    await plain.app.stop();
  }
});

test('unknown routes return 404 with the error envelope', async () => {
  const res = await api(srv.baseUrl, 'GET', '/api/nope');
  assert.equal(res.status, 404);
  assert.equal(res.body.error.code, 'NOT_FOUND');
});
