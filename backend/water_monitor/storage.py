"""An idempotent event archive and a small materialized latest-value table."""
import hashlib
import json
from pathlib import Path
import sqlite3


class Store:
    def __init__(self, path):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY, device_id TEXT, boot_id TEXT, seq INTEGER,
                observed_at REAL, received_at REAL, fingerprint TEXT, raw BLOB
            );
            CREATE INDEX IF NOT EXISTS events_time ON events(received_at);
            CREATE TABLE IF NOT EXISTS readings (
                event_id TEXT REFERENCES events(id) ON DELETE CASCADE,
                device_id TEXT, sensor_id TEXT, metric TEXT, unit TEXT,
                value REAL, quality TEXT, source TEXT, location_id TEXT,
                observed_at REAL, received_at REAL,
                PRIMARY KEY(event_id, sensor_id, metric)
            );
            CREATE INDEX IF NOT EXISTS readings_window
                ON readings(device_id, sensor_id, metric, observed_at);
            CREATE TABLE IF NOT EXISTS latest (
                device_id TEXT, sensor_id TEXT, metric TEXT, unit TEXT,
                value REAL, quality TEXT, source TEXT, location_id TEXT,
                observed_at REAL, received_at REAL,
                PRIMARY KEY(device_id, sensor_id, metric)
            );
            CREATE TABLE IF NOT EXISTS rejected (
                id INTEGER PRIMARY KEY, received_at REAL, subject TEXT, reason TEXT, raw BLOB
            );
        """)

    def close(self):
        self.db.close()

    def ingest(self, event, observed_at, received_at, raw):
        identity = [event["device_id"], event["boot_id"], event["seq"]]
        event_id = hashlib.sha256(json.dumps(identity).encode()).hexdigest()
        fingerprint = hashlib.sha256(json.dumps(event, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        previous = self.db.execute("SELECT fingerprint FROM events WHERE id=?", (event_id,)).fetchone()
        if previous:
            if previous[0] != fingerprint:
                raise ValueError("event identity reused with a different payload")
            return False
        with self.db:
            self.db.execute("INSERT INTO events VALUES (?,?,?,?,?,?,?,?)", (
                event_id, *identity, observed_at, received_at, fingerprint, raw,
            ))
            for reading in event["readings"]:
                key = event["device_id"], reading["sensor_id"], reading["metric"]
                current = self.db.execute("SELECT unit FROM latest WHERE device_id=? AND sensor_id=? AND metric=?", key).fetchone()
                if current and current[0] != reading["unit"]:
                    raise ValueError("unit changed for an existing device/sensor/metric")
                values = (*key, reading["unit"], reading["value"], reading["quality"],
                          event["source"], event["location_id"], observed_at, received_at)
                self.db.execute("INSERT INTO readings VALUES (?,?,?,?,?,?,?,?,?,?,?)", (event_id, *values))
                if reading["quality"] == "invalid":
                    continue
                self.db.execute("""
                    INSERT INTO latest VALUES (?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(device_id,sensor_id,metric) DO UPDATE SET
                        unit=excluded.unit, value=excluded.value, quality=excluded.quality,
                        source=excluded.source, location_id=excluded.location_id,
                        observed_at=excluded.observed_at, received_at=excluded.received_at
                    WHERE excluded.observed_at > latest.observed_at OR
                        (excluded.observed_at = latest.observed_at AND excluded.received_at > latest.received_at)
                """, values)
        return True

    def current(self, device_id=None):
        if device_id is None:
            return [dict(row) for row in self.db.execute("SELECT * FROM latest")]
        return [dict(row) for row in self.db.execute("SELECT * FROM latest WHERE device_id=?", (device_id,))]

    def mean(self, row, window_seconds):
        result = self.db.execute("""
            SELECT AVG(value), COUNT(*) FROM readings
            WHERE device_id=? AND sensor_id=? AND metric=? AND unit=? AND source=?
                AND quality != 'invalid' AND observed_at BETWEEN ? AND ?
        """, (row["device_id"], row["sensor_id"], row["metric"], row["unit"], row["source"],
              row["observed_at"] - window_seconds, row["observed_at"])).fetchone()
        return result[0], result[1]

    def reject(self, subject, raw, reason, received_at):
        with self.db:
            self.db.execute("INSERT INTO rejected(received_at,subject,reason,raw) VALUES (?,?,?,?)",
                            (received_at, subject, str(reason)[:500], raw[:16384]))
            self.db.execute("DELETE FROM rejected WHERE id NOT IN (SELECT id FROM rejected ORDER BY id DESC LIMIT 1000)")

    def prune(self, now, days, max_events=250000):
        with self.db:
            self.db.execute("DELETE FROM events WHERE received_at < ?", (now - days * 86400,))
            self.db.execute("""DELETE FROM events WHERE id IN (
                SELECT id FROM events ORDER BY received_at DESC LIMIT -1 OFFSET ?
            )""", (max_events,))
