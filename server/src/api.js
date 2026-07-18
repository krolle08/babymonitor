// REST API for sleep sessions, events, flags and ICE config (docs/PROTOCOL.md §3, §6).
// Built on node:http only — no framework (TR2: tiny server).

const DEFAULT_STUN_URL = 'stun:stun.cloudflare.com:3478';
const MAX_BODY_BYTES = 1024 * 1024;

class HttpError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function sendJson(res, status, body) {
  const text = JSON.stringify(body);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
  });
  res.end(text);
}

function sendApiError(res, status, code, message) {
  sendJson(res, status, { error: { code, message } });
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        reject(new HttpError(413, 'PAYLOAD_TOO_LARGE', 'Request body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      const text = Buffer.concat(chunks).toString('utf8');
      if (text === '') {
        reject(new HttpError(400, 'BAD_REQUEST', 'Request body required'));
        return;
      }
      try {
        resolve(JSON.parse(text));
      } catch {
        reject(new HttpError(400, 'BAD_REQUEST', 'Request body is not valid JSON'));
      }
    });
    req.on('error', (err) => reject(err));
  });
}

function requireString(obj, field) {
  const value = obj?.[field];
  if (typeof value !== 'string' || value === '') {
    throw new HttpError(400, 'BAD_REQUEST', `Field "${field}" must be a non-empty string`);
  }
  return value;
}

function isAuthorized(req, env) {
  const token = env.FAMILY_TOKEN;
  if (!token) return false; // no configured token: nothing can match (§3 auth is mandatory)
  return req.headers.authorization === `Bearer ${token}`;
}

function iceConfig(env) {
  const iceServers = [{ urls: env.STUN_URL || DEFAULT_STUN_URL }];
  if (env.TURN_URL) {
    const turn = { urls: env.TURN_URL };
    if (env.TURN_USERNAME) turn.username = env.TURN_USERNAME;
    if (env.TURN_CREDENTIAL) turn.credential = env.TURN_CREDENTIAL;
    iceServers.push(turn);
  }
  return { iceServers };
}

async function apiRoute(req, res, url, db, env) {
  const { pathname } = url;
  const method = req.method;

  // GET /api/ice-config — TURN/STUN served at runtime so creds never ship in the binary (§6).
  if (method === 'GET' && pathname === '/api/ice-config') {
    return sendJson(res, 200, iceConfig(env));
  }

  // POST /api/sessions — open a monitoring session (§3.1).
  if (method === 'POST' && pathname === '/api/sessions') {
    const body = await readJsonBody(req);
    const id = db.createSession({
      deviceId: requireString(body, 'deviceId'),
      roomId: requireString(body, 'roomId'),
      startedAt: requireString(body, 'startedAt'),
    });
    return sendJson(res, 201, { id });
  }

  // GET /api/sessions?from&to — list with eventCounts (§3.1).
  if (method === 'GET' && pathname === '/api/sessions') {
    return sendJson(res, 200, db.listSessions({
      from: url.searchParams.get('from'),
      to: url.searchParams.get('to'),
    }));
  }

  const sessionMatch = pathname.match(/^\/api\/sessions\/(\d+)$/);
  if (sessionMatch) {
    const id = Number(sessionMatch[1]);
    // PATCH /api/sessions/:id — close a session (§3.1).
    if (method === 'PATCH') {
      const body = await readJsonBody(req);
      const endedAt = requireString(body, 'endedAt');
      if (!db.endSession(id, endedAt)) {
        throw new HttpError(404, 'NOT_FOUND', `No session ${id}`);
      }
      return sendJson(res, 200, { id });
    }
    // GET /api/sessions/:id — full event list (§3.1).
    if (method === 'GET') {
      const session = db.getSession(id);
      if (!session) throw new HttpError(404, 'NOT_FOUND', `No session ${id}`);
      return sendJson(res, 200, session);
    }
  }

  // POST /api/sessions/:id/events — batch upload from the offline queue (§3.2).
  const eventsMatch = pathname.match(/^\/api\/sessions\/(\d+)\/events$/);
  if (eventsMatch && method === 'POST') {
    const id = Number(eventsMatch[1]);
    if (!db.sessionExists(id)) throw new HttpError(404, 'NOT_FOUND', `No session ${id}`);
    const body = await readJsonBody(req);
    if (!Array.isArray(body)) {
      throw new HttpError(400, 'BAD_REQUEST', 'Body must be a JSON array of events');
    }
    const events = body.map((e, i) => {
      if (e === null || typeof e !== 'object' || Array.isArray(e)) {
        throw new HttpError(400, 'BAD_REQUEST', `Event ${i} must be an object`);
      }
      const data = e.data ?? {};
      if (typeof data !== 'object' || Array.isArray(data)) {
        throw new HttpError(400, 'BAD_REQUEST', `Event ${i} "data" must be an object`);
      }
      // Unknown type values are stored verbatim (forward compatible, §3.2).
      return { type: requireString(e, 'type'), at: requireString(e, 'at'), data };
    });
    return sendJson(res, 201, { inserted: db.insertEvents(id, events) });
  }

  // POST /api/flags — annotate a date (§3.3).
  if (method === 'POST' && pathname === '/api/flags') {
    const body = await readJsonBody(req);
    const note = body?.note;
    if (note !== undefined && note !== null && typeof note !== 'string') {
      throw new HttpError(400, 'BAD_REQUEST', 'Field "note" must be a string');
    }
    const id = db.createFlag({
      date: requireString(body, 'date'),
      label: requireString(body, 'label'),
      note: note ?? null,
    });
    return sendJson(res, 201, { id });
  }

  // GET /api/flags?from&to (§3.3).
  if (method === 'GET' && pathname === '/api/flags') {
    return sendJson(res, 200, db.listFlags({
      from: url.searchParams.get('from'),
      to: url.searchParams.get('to'),
    }));
  }

  // DELETE /api/flags/:id (§3.3).
  const flagMatch = pathname.match(/^\/api\/flags\/(\d+)$/);
  if (flagMatch && method === 'DELETE') {
    if (!db.deleteFlag(Number(flagMatch[1]))) {
      throw new HttpError(404, 'NOT_FOUND', `No flag ${flagMatch[1]}`);
    }
    res.writeHead(204);
    return res.end();
  }

  throw new HttpError(404, 'NOT_FOUND', `No route for ${method} ${pathname}`);
}

/**
 * Returns a node:http request listener serving /healthz and /api/* (§3).
 * All /api routes require `Authorization: Bearer <FAMILY_TOKEN>`.
 */
export function createApiHandler({ db, env = process.env }) {
  return function handle(req, res) {
    let url;
    try {
      url = new URL(req.url, 'http://localhost');
    } catch {
      return sendApiError(res, 400, 'BAD_REQUEST', 'Malformed URL');
    }

    // GET /healthz is unauthenticated (§3).
    if (req.method === 'GET' && url.pathname === '/healthz') {
      return sendJson(res, 200, { ok: true });
    }

    if (url.pathname !== '/api' && !url.pathname.startsWith('/api/')) {
      return sendApiError(res, 404, 'NOT_FOUND', `No route for ${req.method} ${url.pathname}`);
    }
    if (!isAuthorized(req, env)) {
      return sendApiError(res, 401, 'UNAUTHORIZED', 'Missing or invalid bearer token');
    }

    apiRoute(req, res, url, db, env).catch((err) => {
      if (res.headersSent) {
        res.end();
        return;
      }
      if (err instanceof HttpError) {
        sendApiError(res, err.status, err.code, err.message);
      } else {
        sendApiError(res, 500, 'INTERNAL', 'Internal server error');
      }
    });
  };
}
