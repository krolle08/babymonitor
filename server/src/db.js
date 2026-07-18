// SQLite storage for sleep sessions, events and flags (docs/PROTOCOL.md §3, TR7).
// Uses Node's built-in node:sqlite (DatabaseSync) — no native build step.
import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

const SCHEMA = `
CREATE TABLE IF NOT EXISTS sessions (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id  TEXT NOT NULL,
  room_id    TEXT NOT NULL,
  started_at TEXT NOT NULL,
  ended_at   TEXT
);
CREATE TABLE IF NOT EXISTS events (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL REFERENCES sessions(id),
  type       TEXT NOT NULL,
  at         TEXT NOT NULL,
  data       TEXT NOT NULL DEFAULT '{}'
);
CREATE TABLE IF NOT EXISTS flags (
  id    INTEGER PRIMARY KEY AUTOINCREMENT,
  date  TEXT NOT NULL,
  label TEXT NOT NULL,
  note  TEXT
);
CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id);
CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at);
CREATE INDEX IF NOT EXISTS idx_flags_date ON flags(date);
`;

/** Event types surfaced in eventCounts on the session list (PROTOCOL §3.1). */
const COUNTED_TYPES = ['noise', 'freeze', 'reconnect'];

function parseData(text) {
  try {
    const value = JSON.parse(text);
    return value && typeof value === 'object' ? value : {};
  } catch {
    return {};
  }
}

function sessionRowToJson(row) {
  return {
    id: Number(row.id),
    deviceId: row.device_id,
    roomId: row.room_id,
    startedAt: row.started_at,
    endedAt: row.ended_at ?? null,
  };
}

/**
 * Open (or create) the database. Pass ':memory:' for tests.
 * For file paths the containing directory is created if missing.
 */
export function createDb(dbPath = ':memory:') {
  if (dbPath !== ':memory:') {
    mkdirSync(dirname(resolve(dbPath)), { recursive: true });
  }
  const db = new DatabaseSync(dbPath);
  db.exec(SCHEMA);

  const insertSessionStmt = db.prepare(
    'INSERT INTO sessions (device_id, room_id, started_at) VALUES (?, ?, ?)',
  );
  const endSessionStmt = db.prepare('UPDATE sessions SET ended_at = ? WHERE id = ?');
  const getSessionStmt = db.prepare('SELECT * FROM sessions WHERE id = ?');
  const listSessionsStmt = db.prepare(
    `SELECT * FROM sessions
     WHERE (? IS NULL OR started_at >= ?) AND (? IS NULL OR started_at <= ?)
     ORDER BY started_at ASC, id ASC`,
  );
  const countEventsStmt = db.prepare(
    'SELECT type, COUNT(*) AS n FROM events WHERE session_id = ? GROUP BY type',
  );
  const insertEventStmt = db.prepare(
    'INSERT INTO events (session_id, type, at, data) VALUES (?, ?, ?, ?)',
  );
  const listEventsStmt = db.prepare(
    'SELECT * FROM events WHERE session_id = ? ORDER BY at ASC, id ASC',
  );
  const insertFlagStmt = db.prepare('INSERT INTO flags (date, label, note) VALUES (?, ?, ?)');
  const listFlagsStmt = db.prepare(
    `SELECT * FROM flags
     WHERE (? IS NULL OR date >= ?) AND (? IS NULL OR date <= ?)
     ORDER BY date ASC, id ASC`,
  );
  const deleteFlagStmt = db.prepare('DELETE FROM flags WHERE id = ?');

  function eventCounts(sessionId) {
    const counts = Object.fromEntries(COUNTED_TYPES.map((t) => [t, 0]));
    for (const row of countEventsStmt.all(sessionId)) {
      counts[row.type] = Number(row.n);
    }
    return counts;
  }

  return {
    /** @returns {number} new session id */
    createSession({ deviceId, roomId, startedAt }) {
      const { lastInsertRowid } = insertSessionStmt.run(deviceId, roomId, startedAt);
      return Number(lastInsertRowid);
    },

    /** @returns {boolean} true if the session existed */
    endSession(id, endedAt) {
      return endSessionStmt.run(endedAt, id).changes > 0;
    },

    /** @returns {object|null} session with eventCounts + full events list */
    getSession(id) {
      const row = getSessionStmt.get(id);
      if (!row) return null;
      const events = listEventsStmt.all(id).map((e) => ({
        id: Number(e.id),
        type: e.type,
        at: e.at,
        data: parseData(e.data),
      }));
      return { ...sessionRowToJson(row), eventCounts: eventCounts(id), events };
    },

    /** @returns {object[]} sessions in [from, to] on startedAt, with eventCounts */
    listSessions({ from = null, to = null } = {}) {
      return listSessionsStmt
        .all(from, from, to, to)
        .map((row) => ({ ...sessionRowToJson(row), eventCounts: eventCounts(row.id) }));
    },

    /** @returns {boolean} true if the session exists */
    sessionExists(id) {
      return getSessionStmt.get(id) !== undefined;
    },

    /**
     * Batch insert (offline queue upload). All-or-nothing transaction.
     * @returns {number} number of inserted events
     */
    insertEvents(sessionId, events) {
      db.exec('BEGIN');
      try {
        for (const e of events) {
          insertEventStmt.run(sessionId, e.type, e.at, JSON.stringify(e.data ?? {}));
        }
        db.exec('COMMIT');
      } catch (err) {
        db.exec('ROLLBACK');
        throw err;
      }
      return events.length;
    },

    /** @returns {number} new flag id */
    createFlag({ date, label, note = null }) {
      const { lastInsertRowid } = insertFlagStmt.run(date, label, note);
      return Number(lastInsertRowid);
    },

    /** @returns {object[]} flags in [from, to] on date */
    listFlags({ from = null, to = null } = {}) {
      return listFlagsStmt.all(from, from, to, to).map((row) => ({
        id: Number(row.id),
        date: row.date,
        label: row.label,
        note: row.note ?? null,
      }));
    },

    /** @returns {boolean} true if the flag existed */
    deleteFlag(id) {
      return deleteFlagStmt.run(id).changes > 0;
    },

    close() {
      db.close();
    },
  };
}
