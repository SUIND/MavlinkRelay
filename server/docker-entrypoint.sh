#!/bin/sh
set -e

DB="${RELAY_DB:-/data/relay.db}"

python /app/manage.py init-db "$DB"

if [ -n "${RELAY_CERT_PATH:-}" ]; then
    python /app/manage.py set-config "$DB" cert_path "$RELAY_CERT_PATH"
fi
if [ -n "${RELAY_KEY_PATH:-}" ]; then
    python /app/manage.py set-config "$DB" key_path "$RELAY_KEY_PATH"
fi
if [ -n "${RELAY_HOST:-}" ]; then
    python /app/manage.py set-config "$DB" host "$RELAY_HOST"
fi
if [ -n "${RELAY_PORT:-}" ]; then
    python /app/manage.py set-config "$DB" port "$RELAY_PORT"
fi
if [ -n "${LOG_LEVEL:-}" ]; then
    python /app/manage.py set-config "$DB" log_level "$LOG_LEVEL"
fi
if [ -n "${LOG_FORMAT:-}" ]; then
    python /app/manage.py set-config "$DB" log_format "$LOG_FORMAT"
fi

if [ -n "${VEHICLE_TOKEN:-}" ] && [ -n "${VEHICLE_ID:-}" ]; then
    python - <<EOF
import sqlite3, sys
db = "$DB"
token = "$VEHICLE_TOKEN"
identity = "$VEHICLE_ID"
conn = sqlite3.connect(db)
conn.execute(
    "INSERT OR IGNORE INTO tokens (token_b64, role, identity, allowed_vehicle_id) VALUES (?, 'vehicle', ?, NULL)",
    (token, identity),
)
conn.commit()
conn.close()
print(f"Token registered: {identity}")
EOF
fi

if [ -n "${GCS_TOKEN:-}" ] && [ -n "${GCS_ID:-}" ] && [ -n "${GCS_ALLOWED_VEHICLE:-}" ]; then
    python - <<EOF
import sqlite3
db = "$DB"
token = "$GCS_TOKEN"
identity = "$GCS_ID"
allowed = "$GCS_ALLOWED_VEHICLE"
conn = sqlite3.connect(db)
conn.execute(
    "INSERT OR IGNORE INTO tokens (token_b64, role, identity, allowed_vehicle_id) VALUES (?, 'gcs', ?, ?)",
    (token, identity, allowed),
)
conn.commit()
conn.close()
print(f"Token registered: {identity} (allowed: {allowed})")
EOF
fi

exec mavlink-relay-server --db "$DB" "$@"
