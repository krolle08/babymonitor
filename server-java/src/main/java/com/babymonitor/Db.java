package com.babymonitor;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * SQLite storage for sleep sessions, events and flags (docs/PROTOCOL.md §3, TR7).
 * Same schema and JSON shapes as server/src/db.js. Pass ":memory:" for tests;
 * for file paths the containing directory is created if missing.
 *
 * A single connection is kept open; all methods are synchronized because Jetty
 * serves requests from multiple threads (the Node original is single-threaded).
 */
public final class Db implements AutoCloseable {

    private static final String[] SCHEMA = {
        """
        CREATE TABLE IF NOT EXISTS sessions (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          device_id  TEXT NOT NULL,
          room_id    TEXT NOT NULL,
          started_at TEXT NOT NULL,
          ended_at   TEXT
        )""",
        """
        CREATE TABLE IF NOT EXISTS events (
          id         INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL REFERENCES sessions(id),
          type       TEXT NOT NULL,
          at         TEXT NOT NULL,
          data       TEXT NOT NULL DEFAULT '{}'
        )""",
        """
        CREATE TABLE IF NOT EXISTS flags (
          id    INTEGER PRIMARY KEY AUTOINCREMENT,
          date  TEXT NOT NULL,
          label TEXT NOT NULL,
          note  TEXT
        )""",
        "CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at)",
        "CREATE INDEX IF NOT EXISTS idx_flags_date ON flags(date)",
    };

    /** Event types surfaced with a 0 default in eventCounts (PROTOCOL §3.1). */
    private static final String[] COUNTED_TYPES = {"noise", "freeze", "reconnect"};

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final Connection conn;

    /** One event in a batch upload: data is a pre-serialized JSON object string. */
    public record Event(String type, String at, String dataJson) {}

    public Db(String dbPath) {
        try {
            String url;
            if (":memory:".equals(dbPath)) {
                url = "jdbc:sqlite::memory:";
            } else {
                Path resolved = Path.of(dbPath).toAbsolutePath().normalize();
                Files.createDirectories(resolved.getParent());
                url = "jdbc:sqlite:" + resolved;
            }
            conn = DriverManager.getConnection(url);
            try (Statement st = conn.createStatement()) {
                for (String ddl : SCHEMA) {
                    st.executeUpdate(ddl);
                }
            }
        } catch (Exception e) {
            throw new IllegalStateException("Failed to open database at " + dbPath, e);
        }
    }

    /** @return the new session id */
    public synchronized int createSession(String deviceId, String roomId, String startedAt) {
        try (PreparedStatement ps = conn.prepareStatement(
                "INSERT INTO sessions (device_id, room_id, started_at) VALUES (?, ?, ?)",
                Statement.RETURN_GENERATED_KEYS)) {
            ps.setString(1, deviceId);
            ps.setString(2, roomId);
            ps.setString(3, startedAt);
            ps.executeUpdate();
            try (ResultSet keys = ps.getGeneratedKeys()) {
                keys.next();
                return keys.getInt(1);
            }
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
    }

    /** @return true if the session existed */
    public synchronized boolean endSession(int id, String endedAt) {
        try (PreparedStatement ps = conn.prepareStatement(
                "UPDATE sessions SET ended_at = ? WHERE id = ?")) {
            ps.setString(1, endedAt);
            ps.setInt(2, id);
            return ps.executeUpdate() > 0;
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
    }

    /** @return session with eventCounts + full events list, or null */
    public synchronized ObjectNode getSession(int id) {
        try (PreparedStatement ps = conn.prepareStatement("SELECT * FROM sessions WHERE id = ?")) {
            ps.setInt(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) return null;
                ObjectNode session = sessionRowToJson(rs);
                session.set("eventCounts", eventCounts(id));
                ArrayNode events = session.putArray("events");
                try (PreparedStatement eps = conn.prepareStatement(
                        "SELECT * FROM events WHERE session_id = ? ORDER BY at ASC, id ASC")) {
                    eps.setInt(1, id);
                    try (ResultSet ers = eps.executeQuery()) {
                        while (ers.next()) {
                            ObjectNode event = events.addObject();
                            event.put("id", ers.getInt("id"));
                            event.put("type", ers.getString("type"));
                            event.put("at", ers.getString("at"));
                            event.set("data", parseData(ers.getString("data")));
                        }
                    }
                }
                return session;
            }
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
    }

    /** @return sessions in [from, to] on startedAt, with eventCounts */
    public synchronized ArrayNode listSessions(String from, String to) {
        ArrayNode result = MAPPER.createArrayNode();
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT * FROM sessions"
                        + " WHERE (? IS NULL OR started_at >= ?) AND (? IS NULL OR started_at <= ?)"
                        + " ORDER BY started_at ASC, id ASC")) {
            ps.setString(1, from);
            ps.setString(2, from);
            ps.setString(3, to);
            ps.setString(4, to);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    ObjectNode session = sessionRowToJson(rs);
                    session.set("eventCounts", eventCounts(rs.getInt("id")));
                    result.add(session);
                }
            }
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
        return result;
    }

    /** @return true if the session exists */
    public synchronized boolean sessionExists(int id) {
        try (PreparedStatement ps = conn.prepareStatement("SELECT 1 FROM sessions WHERE id = ?")) {
            ps.setInt(1, id);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next();
            }
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
    }

    /**
     * Batch insert (offline queue upload). All-or-nothing transaction.
     * @return number of inserted events
     */
    public synchronized int insertEvents(int sessionId, List<Event> events) {
        try {
            conn.setAutoCommit(false);
            try (PreparedStatement ps = conn.prepareStatement(
                    "INSERT INTO events (session_id, type, at, data) VALUES (?, ?, ?, ?)")) {
                for (Event e : events) {
                    ps.setInt(1, sessionId);
                    ps.setString(2, e.type());
                    ps.setString(3, e.at());
                    ps.setString(4, e.dataJson());
                    ps.executeUpdate();
                }
                conn.commit();
            } catch (Exception e) {
                conn.rollback();
                throw e;
            } finally {
                conn.setAutoCommit(true);
            }
            return events.size();
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
    }

    /** @return the new flag id */
    public synchronized int createFlag(String date, String label, String note) {
        try (PreparedStatement ps = conn.prepareStatement(
                "INSERT INTO flags (date, label, note) VALUES (?, ?, ?)",
                Statement.RETURN_GENERATED_KEYS)) {
            ps.setString(1, date);
            ps.setString(2, label);
            ps.setString(3, note);
            ps.executeUpdate();
            try (ResultSet keys = ps.getGeneratedKeys()) {
                keys.next();
                return keys.getInt(1);
            }
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
    }

    /** @return flags in [from, to] on date */
    public synchronized ArrayNode listFlags(String from, String to) {
        ArrayNode result = MAPPER.createArrayNode();
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT * FROM flags"
                        + " WHERE (? IS NULL OR date >= ?) AND (? IS NULL OR date <= ?)"
                        + " ORDER BY date ASC, id ASC")) {
            ps.setString(1, from);
            ps.setString(2, from);
            ps.setString(3, to);
            ps.setString(4, to);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    ObjectNode flag = result.addObject();
                    flag.put("id", rs.getInt("id"));
                    flag.put("date", rs.getString("date"));
                    flag.put("label", rs.getString("label"));
                    String note = rs.getString("note");
                    if (note == null) flag.putNull("note");
                    else flag.put("note", note);
                }
            }
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
        return result;
    }

    /** @return true if the flag existed */
    public synchronized boolean deleteFlag(int id) {
        try (PreparedStatement ps = conn.prepareStatement("DELETE FROM flags WHERE id = ?")) {
            ps.setInt(1, id);
            return ps.executeUpdate() > 0;
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
    }

    @Override
    public synchronized void close() {
        try {
            conn.close();
        } catch (SQLException ignored) {
            // never crash on shutdown (NTR3)
        }
    }

    // ------------------------------------------------------------------

    private ObjectNode sessionRowToJson(ResultSet rs) throws SQLException {
        ObjectNode session = MAPPER.createObjectNode();
        session.put("id", rs.getInt("id"));
        session.put("deviceId", rs.getString("device_id"));
        session.put("roomId", rs.getString("room_id"));
        session.put("startedAt", rs.getString("started_at"));
        String endedAt = rs.getString("ended_at");
        if (endedAt == null) session.putNull("endedAt");
        else session.put("endedAt", endedAt);
        return session;
    }

    /**
     * eventCounts: the three canonical types default to 0, every type actually
     * present is reported with its count (mirrors db.js eventCounts exactly).
     */
    private ObjectNode eventCounts(int sessionId) throws SQLException {
        Map<String, Integer> counts = new LinkedHashMap<>();
        for (String type : COUNTED_TYPES) counts.put(type, 0);
        try (PreparedStatement ps = conn.prepareStatement(
                "SELECT type, COUNT(*) AS n FROM events WHERE session_id = ? GROUP BY type")) {
            ps.setInt(1, sessionId);
            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    counts.put(rs.getString("type"), rs.getInt("n"));
                }
            }
        }
        ObjectNode node = MAPPER.createObjectNode();
        counts.forEach(node::put);
        return node;
    }

    /** Stored event data parsed back to a JSON object; anything else becomes {}. */
    private static JsonNode parseData(String text) {
        try {
            JsonNode value = MAPPER.readTree(text);
            return value != null && value.isObject() ? value : MAPPER.createObjectNode();
        } catch (Exception e) {
            return MAPPER.createObjectNode();
        }
    }
}
