// Signaling protocol tests (docs/PROTOCOL.md §2) against a real server + real ws clients.
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { startTestServer, WsClient, waitFor } from './helpers.js';

const ROOM_CODE_RE = /^[A-HJ-NP-Z2-9]{6}$/; // A–Z/2–9 without 0/O/1/I
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

let srv;

before(async () => {
  srv = await startTestServer();
});

after(async () => {
  await srv.app.stop();
});

async function newRoom() {
  const camera = await WsClient.connect(srv.wsUrl);
  camera.send({ type: 'create-room' });
  const created = await camera.next();
  assert.equal(created.type, 'room-created');
  return { camera, roomId: created.roomId, reclaimToken: created.reclaimToken };
}

async function joinParent(roomId, camera) {
  const parent = await WsClient.connect(srv.wsUrl);
  parent.send({ type: 'join-room', roomId });
  const joined = await parent.next();
  assert.equal(joined.type, 'room-joined');
  assert.equal(joined.roomId, roomId);
  if (camera) {
    const notice = await camera.next();
    assert.deepEqual(notice, { type: 'peer-joined', peerId: joined.peerId });
  }
  return { parent, peerId: joined.peerId };
}

test('create-room returns a 6-char unambiguous code and a UUID reclaim token', async () => {
  const { camera, roomId, reclaimToken } = await newRoom();
  assert.match(roomId, ROOM_CODE_RE);
  assert.match(reclaimToken, UUID_RE);
  camera.close();
});

test('join-room returns a UUID peerId and notifies the camera with peer-joined', async () => {
  const { camera, roomId } = await newRoom();
  const { parent, peerId } = await joinParent(roomId, camera);
  assert.match(peerId, UUID_RE);
  camera.close();
  parent.close();
});

test('join-room on an unknown room answers ROOM_NOT_FOUND', async () => {
  const parent = await WsClient.connect(srv.wsUrl);
  parent.send({ type: 'join-room', roomId: 'ZZZZZZ' });
  const err = await parent.next();
  assert.equal(err.type, 'error');
  assert.equal(err.code, 'ROOM_NOT_FOUND');
  parent.close();
});

test('a 5th parent gets ROOM_FULL', async () => {
  const { camera, roomId } = await newRoom();
  const parents = [];
  for (let i = 0; i < 4; i++) parents.push(await joinParent(roomId, camera));
  const fifth = await WsClient.connect(srv.wsUrl);
  fifth.send({ type: 'join-room', roomId });
  const err = await fifth.next();
  assert.equal(err.type, 'error');
  assert.equal(err.code, 'ROOM_FULL');
  fifth.close();
  camera.close();
  for (const { parent } of parents) parent.close();
});

test('offer/answer/ice route to the right peer — two parents get independent relays', async () => {
  const { camera, roomId } = await newRoom();
  const a = await joinParent(roomId, camera);
  const b = await joinParent(roomId, camera);
  assert.notEqual(a.peerId, b.peerId);

  // Camera → parent A only.
  camera.send({ type: 'offer', peerId: a.peerId, sdp: 'sdp-for-A', sdpType: 'offer' });
  const offerA = await a.parent.next();
  assert.deepEqual(offerA, { type: 'offer', peerId: a.peerId, sdp: 'sdp-for-A', sdpType: 'offer' });
  await b.parent.expectSilence();

  // Camera → parent B only.
  camera.send({ type: 'offer', peerId: b.peerId, sdp: 'sdp-for-B', sdpType: 'offer' });
  const offerB = await b.parent.next();
  assert.equal(offerB.sdp, 'sdp-for-B');
  await a.parent.expectSilence();

  // Parent A answer → camera, stamped with A's peerId.
  a.parent.send({ type: 'answer', peerId: a.peerId, sdp: 'answer-A', sdpType: 'answer' });
  const answerA = await camera.next();
  assert.deepEqual(answerA, { type: 'answer', peerId: a.peerId, sdp: 'answer-A', sdpType: 'answer' });

  // ICE both directions.
  const candidate = { candidate: 'candidate:1 1 udp 1 1.2.3.4 5678 typ host', sdpMid: '0', sdpMLineIndex: 0 };
  camera.send({ type: 'ice', peerId: b.peerId, candidate });
  const iceToB = await b.parent.next();
  assert.deepEqual(iceToB, { type: 'ice', peerId: b.peerId, candidate });
  await a.parent.expectSilence();

  b.parent.send({ type: 'ice', peerId: b.peerId, candidate });
  const iceToCamera = await camera.next();
  assert.deepEqual(iceToCamera, { type: 'ice', peerId: b.peerId, candidate });

  camera.close();
  a.parent.close();
  b.parent.close();
});

test('ice-restart from a parent is relayed to the camera with the sender peerId', async () => {
  const { camera, roomId } = await newRoom();
  const { parent, peerId } = await joinParent(roomId, camera);
  parent.send({ type: 'ice-restart', peerId });
  const relayed = await camera.next();
  assert.deepEqual(relayed, { type: 'ice-restart', peerId });
  camera.close();
  parent.close();
});

test('a parent cannot spoof another peerId — server stamps the real one', async () => {
  const { camera, roomId } = await newRoom();
  const a = await joinParent(roomId, camera);
  const b = await joinParent(roomId, camera);
  a.parent.send({ type: 'ice-restart', peerId: b.peerId });
  const relayed = await camera.next();
  assert.equal(relayed.peerId, a.peerId);
  camera.close();
  a.parent.close();
  b.parent.close();
});

test('hb and noise fan out from the camera to all parents', async () => {
  const { camera, roomId } = await newRoom();
  const a = await joinParent(roomId, camera);
  const b = await joinParent(roomId, camera);

  camera.send({ type: 'hb', seq: 7, ts: 1752710000000, audioLevel: 0.12 });
  assert.deepEqual(await a.parent.next(), { type: 'hb', seq: 7, ts: 1752710000000, audioLevel: 0.12 });
  assert.deepEqual(await b.parent.next(), { type: 'hb', seq: 7, ts: 1752710000000, audioLevel: 0.12 });

  camera.send({ type: 'noise', ts: 1752710003000, audioLevel: 0.8 });
  assert.deepEqual(await a.parent.next(), { type: 'noise', ts: 1752710003000, audioLevel: 0.8 });
  assert.deepEqual(await b.parent.next(), { type: 'noise', ts: 1752710003000, audioLevel: 0.8 });

  camera.close();
  a.parent.close();
  b.parent.close();
});

test('camera disconnect broadcasts camera-left; reclaim restores the room', async () => {
  const { camera, roomId, reclaimToken } = await newRoom();
  const { parent, peerId } = await joinParent(roomId, camera);

  camera.close();
  const left = await parent.next();
  assert.deepEqual(left, { type: 'camera-left' });

  // Camera reconnects and reclaims the same room.
  const camera2 = await WsClient.connect(srv.wsUrl);
  camera2.send({ type: 'create-room', roomId, reclaimToken });
  const recreated = await camera2.next();
  assert.deepEqual(recreated, { type: 'room-created', roomId, reclaimToken });

  // The still-connected parent is re-announced so the camera re-offers.
  const reannounce = await camera2.next();
  assert.deepEqual(reannounce, { type: 'peer-joined', peerId });

  // Relay works again after reclaim.
  camera2.send({ type: 'offer', peerId, sdp: 'post-reclaim', sdpType: 'offer' });
  const offer = await parent.next();
  assert.equal(offer.sdp, 'post-reclaim');

  camera2.close();
  parent.close();
});

test('reclaim with a wrong token answers BAD_RECLAIM and leaves the room intact', async () => {
  const { camera, roomId } = await newRoom();
  const impostor = await WsClient.connect(srv.wsUrl);
  impostor.send({ type: 'create-room', roomId, reclaimToken: '00000000-0000-0000-0000-000000000000' });
  const err = await impostor.next();
  assert.equal(err.type, 'error');
  assert.equal(err.code, 'BAD_RECLAIM');
  // Original camera unaffected: a parent can still join.
  const { parent } = await joinParent(roomId, camera);
  impostor.close();
  camera.close();
  parent.close();
});

test('parent disconnect sends peer-left to the camera', async () => {
  const { camera, roomId } = await newRoom();
  const { parent, peerId } = await joinParent(roomId, camera);
  parent.close();
  const left = await camera.next();
  assert.deepEqual(left, { type: 'peer-left', peerId });
  camera.close();
});

test('a parent can rejoin with its previous peerId after a drop', async () => {
  const { camera, roomId } = await newRoom();
  const { parent, peerId } = await joinParent(roomId, camera);
  parent.close();
  assert.equal((await camera.next()).type, 'peer-left');

  const parent2 = await WsClient.connect(srv.wsUrl);
  parent2.send({ type: 'join-room', roomId, peerId });
  const rejoined = await parent2.next();
  assert.deepEqual(rejoined, { type: 'room-joined', roomId, peerId });
  const reannounce = await camera.next();
  assert.deepEqual(reannounce, { type: 'peer-joined', peerId });

  camera.close();
  parent2.close();
});

test('leave message has the same effect as closing the socket', async () => {
  const { camera, roomId } = await newRoom();
  const { parent, peerId } = await joinParent(roomId, camera);
  parent.send({ type: 'leave' });
  const left = await camera.next();
  assert.deepEqual(left, { type: 'peer-left', peerId });
  camera.close();
  parent.close();
});

test('malformed JSON answers BAD_MESSAGE without crashing the server', async () => {
  const client = await WsClient.connect(srv.wsUrl);
  client.sendRaw('{this is not json');
  const err = await client.next();
  assert.equal(err.type, 'error');
  assert.equal(err.code, 'BAD_MESSAGE');

  // Server is still alive and functional on the same socket.
  client.send({ type: 'create-room' });
  const created = await client.next();
  assert.equal(created.type, 'room-created');
  client.close();
});

test('unknown message types are ignored', async () => {
  const { camera } = await newRoom();
  camera.send({ type: 'telepathy', payload: 42 });
  await camera.expectSilence();
  camera.close();
});

test('negotiation messages outside a room answer NOT_IN_ROOM', async () => {
  const client = await WsClient.connect(srv.wsUrl);
  client.send({ type: 'offer', peerId: 'x', sdp: 's', sdpType: 'offer' });
  const err = await client.next();
  assert.equal(err.type, 'error');
  assert.equal(err.code, 'NOT_IN_ROOM');
  client.close();
});

test('rooms are garbage-collected 10 minutes after both sides are gone', async () => {
  const { camera, roomId } = await newRoom();
  camera.close();
  await camera.closed();

  const room = srv.app.signaling.rooms.get(roomId);
  assert.ok(room, 'room persists immediately after the camera leaves');
  // The server processes the socket close asynchronously — wait for it.
  await waitFor(() => room.emptySince !== null);

  // Not yet 10 minutes: gc must keep it.
  srv.app.signaling.gcNow(room.emptySince + 9 * 60 * 1000);
  assert.ok(srv.app.signaling.rooms.has(roomId));

  // 10+ minutes: gone.
  srv.app.signaling.gcNow(room.emptySince + 10 * 60 * 1000 + 1);
  assert.equal(srv.app.signaling.rooms.has(roomId), false);

  const parent = await WsClient.connect(srv.wsUrl);
  parent.send({ type: 'join-room', roomId });
  const err = await parent.next();
  assert.equal(err.code, 'ROOM_NOT_FOUND');
  parent.close();
});

// ---- Trusted-device auth relay (docs/PROTOCOL.md §2.1, §2.2, §8.2) ----

test('join-room auth is passed through to the camera inside peer-joined', async () => {
  const { camera, roomId } = await newRoom();
  const parent = await WsClient.connect(srv.wsUrl);
  const auth = { deviceId: 'abcdef0123456789', pk: 'pk-base64url', nonce: 'nonce-base64url' };
  parent.send({ type: 'join-room', roomId, auth });
  const joined = await parent.next();
  assert.equal(joined.type, 'room-joined');
  const notice = await camera.next();
  assert.deepEqual(notice, { type: 'peer-joined', peerId: joined.peerId, auth });
  camera.close();
  parent.close();
});

test('join-room without auth yields a peer-joined that omits the auth key', async () => {
  const { camera, roomId } = await newRoom();
  const parent = await WsClient.connect(srv.wsUrl);
  parent.send({ type: 'join-room', roomId });
  const joined = await parent.next();
  const notice = await camera.next();
  assert.deepEqual(notice, { type: 'peer-joined', peerId: joined.peerId });
  assert.ok(!('auth' in notice), 'peer-joined must omit auth entirely when absent (never send null)');
  camera.close();
  parent.close();
});

test('auth-challenge is relayed from the camera to the addressed parent only', async () => {
  const { camera, roomId } = await newRoom();
  const a = await joinParent(roomId, camera);
  const b = await joinParent(roomId, camera);
  camera.send({ type: 'auth-challenge', peerId: a.peerId, nonce: 'nonce-c', sig: 'sig-cam' });
  const relayed = await a.parent.next();
  assert.deepEqual(relayed, { type: 'auth-challenge', peerId: a.peerId, nonce: 'nonce-c', sig: 'sig-cam' });
  await b.parent.expectSilence();
  camera.close();
  a.parent.close();
  b.parent.close();
});

test('auth-response is relayed to the camera with the sender peerId stamped, payload intact', async () => {
  const { camera, roomId } = await newRoom();
  const a = await joinParent(roomId, camera);
  const b = await joinParent(roomId, camera);
  // Parent A addresses B's peerId; the server must stamp A's real id but leave
  // the deviceId/pk/sig payload untouched (§8.2, anti-spoofing like `answer`).
  a.parent.send({ type: 'auth-response', peerId: b.peerId, deviceId: 'dev-A', pk: 'pk-A', sig: 'sig-A' });
  const relayed = await camera.next();
  assert.deepEqual(relayed, { type: 'auth-response', peerId: a.peerId, deviceId: 'dev-A', pk: 'pk-A', sig: 'sig-A' });
  camera.close();
  a.parent.close();
  b.parent.close();
});

test('auth captured at join is re-sent in peer-joined after a camera reclaim', async () => {
  const { camera, roomId, reclaimToken } = await newRoom();
  const parent = await WsClient.connect(srv.wsUrl);
  const auth = { deviceId: 'dev-1', pk: 'pk-1', nonce: 'nonce-1' };
  parent.send({ type: 'join-room', roomId, auth });
  const joined = await parent.next();
  const firstNotice = await camera.next();
  assert.deepEqual(firstNotice, { type: 'peer-joined', peerId: joined.peerId, auth });

  camera.close();
  assert.deepEqual(await parent.next(), { type: 'camera-left' });

  const camera2 = await WsClient.connect(srv.wsUrl);
  camera2.send({ type: 'create-room', roomId, reclaimToken });
  assert.equal((await camera2.next()).type, 'room-created');
  const reannounce = await camera2.next();
  assert.deepEqual(reannounce, { type: 'peer-joined', peerId: joined.peerId, auth });

  camera2.close();
  parent.close();
});

test('pair-request is never relayed by the cloud server (unknown type, ignored)', async () => {
  const { camera, roomId } = await newRoom();
  const { parent, peerId } = await joinParent(roomId, camera);
  parent.send({ type: 'pair-request', deviceId: 'd', name: 'n', pk: 'p', proof: 'pf' });
  await camera.expectSilence();
  await parent.expectSilence();
  // The connection is unharmed — a normal offer still relays afterwards.
  camera.send({ type: 'offer', peerId, sdp: 'after-pair', sdpType: 'offer' });
  const offer = await parent.next();
  assert.equal(offer.sdp, 'after-pair');
  camera.close();
  parent.close();
});
