// WebSocket signaling: room registry + SDP/ICE relay (docs/PROTOCOL.md §2, TR2).
// The server never parses SDP — it routes on (room from the socket's session, peerId).
import { randomInt, randomUUID } from 'node:crypto';

// 6-char room codes from A–Z/2–9 excluding ambiguous 0/O/1/I (PROTOCOL §2.1).
const ROOM_CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
const ROOM_CODE_LENGTH = 6;
const MAX_PARENTS = 4;
const ROOM_GRACE_MS = 10 * 60 * 1000; // rooms GC'd 10 min after both sides gone

const OPEN = 1; // WebSocket.OPEN

function isOpen(ws) {
  return ws && ws.readyState === OPEN;
}

function sendJson(ws, obj) {
  if (isOpen(ws)) ws.send(JSON.stringify(obj));
}

function sendError(ws, code, message) {
  sendJson(ws, { type: 'error', code, message });
}

export function createSignaling({ gcIntervalMs = 60_000 } = {}) {
  /** roomId -> { roomId, reclaimToken, camera, parents: Map<peerId, ws>,
   *              parentAuth: Map<peerId, auth>, emptySince } */
  const rooms = new Map();

  function generateRoomId() {
    let id;
    do {
      id = '';
      for (let i = 0; i < ROOM_CODE_LENGTH; i++) {
        id += ROOM_CODE_ALPHABET[randomInt(ROOM_CODE_ALPHABET.length)];
      }
    } while (rooms.has(id));
    return id;
  }

  function maybeMarkEmpty(room) {
    if (!isOpen(room.camera) && room.parents.size === 0) {
      room.emptySince = Date.now();
    }
  }

  /** Remove rooms where both sides have been gone for >= 10 minutes. */
  function gcNow(now = Date.now()) {
    for (const [roomId, room] of rooms) {
      if (room.emptySince !== null && now - room.emptySince >= ROOM_GRACE_MS) {
        rooms.delete(roomId);
      }
    }
  }

  const gcTimer = setInterval(gcNow, gcIntervalMs);
  gcTimer.unref?.();

  /** Detach ws from its room (used for both 'leave' and socket close). */
  function leaveRoom(ws, ctx) {
    const room = ctx.room;
    if (!room) return;
    if (ctx.role === 'camera') {
      if (room.camera === ws) {
        room.camera = null;
        // Parents show RECONNECTING and wait; room persists for reclaim (§2.1).
        for (const parentWs of room.parents.values()) {
          sendJson(parentWs, { type: 'camera-left' });
        }
        maybeMarkEmpty(room);
      }
    } else if (ctx.role === 'parent') {
      if (room.parents.get(ctx.peerId) === ws) {
        room.parents.delete(ctx.peerId);
        room.parentAuth.delete(ctx.peerId);
        sendJson(room.camera, { type: 'peer-left', peerId: ctx.peerId });
        maybeMarkEmpty(room);
      }
    }
    ctx.room = null;
    ctx.role = null;
    ctx.peerId = null;
  }

  function handleCreateRoom(ws, ctx, msg) {
    if (ctx.room) leaveRoom(ws, ctx); // a socket holds at most one room session

    if (msg.roomId !== undefined || msg.reclaimToken !== undefined) {
      // Reclaim path: camera reconnected and wants its old room back.
      const room = rooms.get(msg.roomId);
      if (!room || typeof msg.reclaimToken !== 'string' || room.reclaimToken !== msg.reclaimToken) {
        sendError(ws, 'BAD_RECLAIM', 'Unknown room or wrong reclaim token');
        return;
      }
      if (room.camera && room.camera !== ws) room.camera.terminate?.();
      room.camera = ws;
      room.emptySince = null;
      ctx.role = 'camera';
      ctx.room = room;
      sendJson(ws, { type: 'room-created', roomId: room.roomId, reclaimToken: room.reclaimToken });
      // Re-announce live parents so the camera re-creates a PC + offer per peer.
      // Carry the auth captured at join time (§8.2) so the camera re-runs its
      // trusted-device challenge for each re-announced parent.
      for (const [peerId, parentWs] of room.parents) {
        if (!isOpen(parentWs)) continue;
        const peerJoined = { type: 'peer-joined', peerId };
        const savedAuth = room.parentAuth.get(peerId);
        if (savedAuth != null) peerJoined.auth = savedAuth;
        sendJson(ws, peerJoined);
      }
      return;
    }

    const room = {
      roomId: generateRoomId(),
      reclaimToken: randomUUID(),
      camera: ws,
      parents: new Map(),
      parentAuth: new Map(),
      emptySince: null,
    };
    rooms.set(room.roomId, room);
    ctx.role = 'camera';
    ctx.room = room;
    sendJson(ws, { type: 'room-created', roomId: room.roomId, reclaimToken: room.reclaimToken });
  }

  function handleJoinRoom(ws, ctx, msg) {
    if (typeof msg.roomId !== 'string') {
      sendError(ws, 'BAD_MESSAGE', 'join-room requires roomId');
      return;
    }
    if (ctx.room) leaveRoom(ws, ctx);

    const room = rooms.get(msg.roomId);
    if (!room) {
      sendError(ws, 'ROOM_NOT_FOUND', `No room ${msg.roomId}`);
      return;
    }

    // Optional peerId reuse on rejoin: honoured when free (not held by a live socket).
    let peerId = typeof msg.peerId === 'string' && msg.peerId !== '' ? msg.peerId : null;
    if (peerId !== null) {
      const existing = room.parents.get(peerId);
      if (existing && existing !== ws && isOpen(existing)) {
        peerId = null; // taken by a live parent — treat as a fresh join
      } else if (existing && existing !== ws) {
        existing.terminate?.(); // stale socket; reclaim the slot
      }
    }
    if ((peerId === null || !room.parents.has(peerId)) && room.parents.size >= MAX_PARENTS) {
      sendError(ws, 'ROOM_FULL', `Room ${room.roomId} already has ${MAX_PARENTS} parents`);
      return;
    }
    if (peerId === null) peerId = randomUUID();

    room.parents.set(peerId, ws);
    // Optional trusted-device auth (§8.2): passed through verbatim, contents not
    // validated by the server. Captured per peerId so it survives a camera reclaim.
    const auth = msg.auth;
    if (auth != null) room.parentAuth.set(peerId, auth);
    else room.parentAuth.delete(peerId);
    room.emptySince = null;
    ctx.role = 'parent';
    ctx.room = room;
    ctx.peerId = peerId;
    sendJson(ws, { type: 'room-joined', roomId: room.roomId, peerId });
    // Camera responds with an auth-challenge when auth is present, else an offer (§2.1).
    const peerJoined = { type: 'peer-joined', peerId };
    if (auth != null) peerJoined.auth = auth;
    sendJson(room.camera, peerJoined);
  }

  /** offer/answer/ice/ice-restart/auth-challenge/auth-response: relayed verbatim,
   *  routed on peerId (§2.2). auth-challenge flows camera→parent like offer;
   *  auth-response flows parent→camera like answer (peerId stamped server-side,
   *  the deviceId/pk/sig payload left untouched). */
  function relayNegotiation(ws, ctx, msg, raw) {
    const room = ctx.room;
    if (!room) {
      sendError(ws, 'NOT_IN_ROOM', `${msg.type} requires an active room session`);
      return;
    }
    if (ctx.role === 'camera') {
      const target = room.parents.get(msg.peerId);
      if (isOpen(target)) target.send(raw);
    } else {
      // Stamp the sender's real peerId so the camera routes to the right PC.
      sendJson(room.camera, { ...msg, peerId: ctx.peerId });
    }
  }

  /** hb + noise: camera → all parents fanout (§2.3). */
  function fanout(ws, ctx, msg, raw) {
    const room = ctx.room;
    if (!room) {
      sendError(ws, 'NOT_IN_ROOM', `${msg.type} requires an active room session`);
      return;
    }
    if (ctx.role !== 'camera') return; // only the camera emits hb/noise
    for (const parentWs of room.parents.values()) {
      if (isOpen(parentWs)) parentWs.send(raw);
    }
  }

  function handleMessage(ws, ctx, msg, raw) {
    switch (msg.type) {
      case 'create-room':
        handleCreateRoom(ws, ctx, msg);
        break;
      case 'join-room':
        handleJoinRoom(ws, ctx, msg);
        break;
      case 'offer':
      case 'answer':
      case 'ice':
      case 'ice-restart':
      case 'auth-challenge':
      case 'auth-response':
        relayNegotiation(ws, ctx, msg, raw);
        break;
      case 'hb':
      case 'noise':
        fanout(ws, ctx, msg, raw);
        break;
      case 'leave':
        leaveRoom(ws, ctx);
        break;
      default:
        // Unknown message types MUST be ignored (forward compatibility, NTR6).
        break;
    }
  }

  function handleConnection(ws) {
    const ctx = { role: null, room: null, peerId: null };
    ws.on('message', (data) => {
      const raw = data.toString(); // always relay as text frames
      let msg;
      try {
        msg = JSON.parse(raw);
      } catch {
        sendError(ws, 'BAD_MESSAGE', 'Frame is not valid JSON');
        return;
      }
      if (msg === null || typeof msg !== 'object' || typeof msg.type !== 'string') {
        sendError(ws, 'BAD_MESSAGE', 'Frame must be a JSON object with a string "type"');
        return;
      }
      try {
        handleMessage(ws, ctx, msg, raw);
      } catch {
        sendError(ws, 'BAD_MESSAGE', 'Failed to handle message');
      }
    });
    ws.on('close', () => leaveRoom(ws, ctx));
    ws.on('error', () => {
      /* close event follows; never crash the process (NTR3) */
    });
  }

  return {
    handleConnection,
    gcNow,
    rooms,
    close() {
      clearInterval(gcTimer);
    },
  };
}
