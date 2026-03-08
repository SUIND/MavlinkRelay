-- MAVLink Relay Server — SQLite schema
-- Compatible with both standard sqlite3 and pyturso (Limbo).
--
-- Apply with:   sqlite3 relay.db < schema.sql
-- Or via:       python manage.py init-db relay.db

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------------
-- Server configuration
-- Replaces all keys from the old YAML file.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS server_config (
    key   TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);

-- Default values.  Adjust before first run or use manage.py set-config.
INSERT OR IGNORE INTO server_config (key, value) VALUES
    ('host',                   '0.0.0.0'),
    ('port',                   '14550'),
    ('cert_path',              'certs/cert.pem'),
    ('key_path',               'certs/key.pem'),
    ('bulk_queue_max',         '100'),
    ('priority_queue_max',     '500'),
    ('keepalive_interval_s',   '15.0'),
    ('keepalive_timeout_s',    '45.0'),
    ('auth_timeout_s',         '10.0'),
    ('log_level',              'INFO'),
    ('log_format',             'json');

-- ---------------------------------------------------------------------------
-- Auth tokens
--
-- role = 'vehicle' : identity is the vehicle_id (BB_######)
--                    allowed_vehicle_id is NULL
-- role = 'gcs'     : identity is the gcs_id    (GCS_######)
--                    allowed_vehicle_id is the ONE vehicle this GCS may reach
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tokens (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    token_b64          TEXT    NOT NULL UNIQUE,
    role               TEXT    NOT NULL CHECK (role IN ('vehicle', 'gcs')),
    identity           TEXT    NOT NULL,
    allowed_vehicle_id TEXT    -- NULL for vehicle tokens; BB_###### for GCS tokens
);
