# MAVLink QUIC Relay Server

Python aioquic server that transparently relays MAVLink frames between vehicles and GCS over QUIC/TLS.

The server accepts QUIC/TLS connections from vehicles and ground control stations (GCS), performs a post-handshake token-based authentication over a CBOR control channel, and relays MAVLink frames on separate streams for priority and bulk traffic.

Key design goals: secure transport (QUIC/TLS), simple token-based authentication (no client TLS certs), strict 1:1 GCS-to-vehicle authorization, SQLite-backed configuration with a swappable DB connector, and robust framing and flow controls for MAVLink.

---

## Features

- QUIC/TLS transport (aioquic 1.3.0, ALPN `mavlink-quic-v1`)
- Token-based post-handshake authentication (no client TLS certs required)
- Server-side 1:1 GCS → vehicle ACL: each GCS token is provisioned for exactly one vehicle; SUBSCRIBE to any other vehicle is rejected
- SQLite configuration via stdlib `sqlite3`; DB connector is swappable via the `ConfigBackend` protocol (e.g. asyncpg for PostgreSQL)
- `manage.py` CLI for database setup and vehicle/GCS pair management
- Separate priority (stream 4) and bulk (stream 8) MAVLink routing
- CBOR control channel (stream 0) with AUTH / AUTH_OK / AUTH_FAIL / PING / PONG
- Wire framing: `[u16_le length][raw bytes]` on all streams
- Server-side keepalive: PING every 15s, close after 45s no PONG
- `--dry-run` flag for config validation without starting the server
- JSON or text logging
- Docker + Docker Compose support
- 87 automated tests (unit + integration)

---

## Architecture

The server is organized into a small set of focused modules.

| Module | Purpose |
|--------|---------|
| `__main__.py` | CLI entry point, argparse, `--dry-run` |
| `server.py` | `run_server()`, QuicConfiguration, signal handlers |
| `protocol.py` | `RelayProtocol` — per-connection state machine (auth, keepalive, routing) |
| `registry.py` | `SessionRegistry`, `VehicleSession`, `GCSSession` — session tracking |
| `framing.py` | `encode_frame()`, `FrameDecoder` — `[u16_le][bytes]` wire format |
| `control.py` | `encode_control()`, `decode_control()`, `handle_auth()`, `handle_subscribe()` — CBOR control messages and ACL |
| `config.py` | `ServerConfig`, `DatabaseStore`, `ConfigBackend` protocol, `load_config()` |
| `backends/turso.py` | `TursoBackend` — stdlib `sqlite3` implementation of `ConfigBackend` |
| `stats.py` | `StatsCollector`, `ConnectionStats`, `ServerStats` — metrics |
| `manage.py` | DB management CLI (init, add-pair, list, set-config) |
| `schema.sql` | SQLite schema — `server_config` and `tokens` tables |

### Swappable DB connector

All database access goes through the `ConfigBackend` protocol:

```python
class ConfigBackend(Protocol):
    async def fetch(self) -> ConfigRows: ...
```

`TursoBackend` implements this using stdlib `sqlite3`. To switch to PostgreSQL, implement `AsyncpgBackend` with the same interface and pass it to `load_config()` — no business logic changes required.

---

## Quick Start

### 1. Create a virtual environment and install

```bash
cd server
python -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

### 2. Generate a self-signed TLS certificate

```bash
cd certs && bash generate_certs.sh && cd ..
```

### 3. Initialize the database

```bash
python manage.py init-db relay.db
```

This creates `relay.db` with the `server_config` and `tokens` tables, populated with default values.

### 4. Set TLS paths in the database

```bash
python manage.py set-config relay.db cert_path certs/cert.pem
python manage.py set-config relay.db key_path  certs/key.pem
```

Alternatively, pass `--cert` / `--key` as CLI flags at runtime (they override DB values).

### 5. Add a vehicle / GCS pair

```bash
python manage.py add-pair relay.db --number 1
```

Output:
```
Added vehicle BB_000001
  token: <base64 token for the vehicle>

Added GCS GCS_000001  (authorized for BB_000001)
  token: <base64 token for the GCS>
```

Each pair shares a number: `BB_000001` / `GCS_000001`, `BB_000002` / `GCS_000002`, etc. The GCS token is permanently bound to its matching vehicle — it cannot subscribe to any other vehicle.

Distribute the vehicle token to the Jetson node and the GCS token to the ground station.

### 6. Validate configuration without starting the server

```bash
mavlink-relay-server --db relay.db --dry-run
```

### 7. Run

```bash
mavlink-relay-server --db relay.db
```

---

## Database management reference

All DB operations go through `manage.py`.

```bash
python manage.py init-db <db>
```
Create schema in a new (or existing) database.

```bash
python manage.py add-pair <db> --number N
python manage.py add-pair <db> --vehicle BB_000001 --gcs GCS_000002
```
Add a matched vehicle + GCS token pair. `--number` derives both identities from the same 6-digit number. `--vehicle` / `--gcs` allows custom identities when the numbers differ.

```bash
python manage.py list <db>
```
Print all token rows with their roles, identities, and allowed vehicle.

```bash
python manage.py set-config <db> <key> <value>
```
Upsert a `server_config` row. Valid keys:

| Key | Default | Description |
|-----|---------|-------------|
| `host` | `0.0.0.0` | Bind address |
| `port` | `14550` | UDP port |
| `cert_path` | `certs/cert.pem` | TLS certificate |
| `key_path` | `certs/key.pem` | TLS private key |
| `bulk_queue_max` | `100` | Max frames in bulk queue |
| `priority_queue_max` | `500` | Max frames in priority queue |
| `keepalive_interval_s` | `15.0` | PING interval (seconds) |
| `keepalive_timeout_s` | `45.0` | Close if no PONG within this window |
| `auth_timeout_s` | `10.0` | Auth timeout (seconds) |
| `log_level` | `INFO` | `INFO` \| `DEBUG` \| `WARNING` \| `ERROR` |
| `log_format` | `json` | `json` \| `text` |

---

## CLI flags

| Flag | Description |
|------|-------------|
| `--db` | Path to the SQLite relay database (required) |
| `--host` | Override `server_config.host` |
| `--port` | Override `server_config.port` |
| `--cert` | Override `server_config.cert_path` |
| `--key` | Override `server_config.key_path` |
| `--log-level` | Override `server_config.log_level` |
| `--auth-timeout` | Auth timeout in seconds |
| `--dry-run` | Load config and token store, print summary, then exit |

---

## TLS certificates

A helper script creates a self-signed certificate suitable for development and integration testing.

```bash
cd certs && bash generate_certs.sh
```

The script generates an EC certificate (prime256v1). Clients may optionally validate the server cert using `ca_cert_path` or skip validation for trusted networks. No client certificate is required — authentication uses the post-handshake token exchange.

See [`AUTHENTICATION.md`](AUTHENTICATION.md) for the full auth flow.

---

## Docker

Production usage is supported via Docker Compose.

**Production:**
```bash
docker compose up
```

**Integration tests:**
```bash
docker compose -f docker-compose.test.yml up --exit-code-from test-client
```

---

## Running tests

```bash
pip install -e ".[dev]"
.venv/bin/pytest tests/ -v
```

Test suite overview:

| File | Tests | What it covers |
|------|-------|----------------|
| `test_framing.py` | 8 | `encode_frame`, `FrameDecoder` basic cases |
| `test_framing_extended.py` | 8 | Fragmentation, oversized frames, buffer limits |
| `test_registry.py` | 13 | Session registration, routing, vehicle/GCS lifecycle |
| `test_config.py` | 10 | `DatabaseStore`, `ConfigBackend` protocol, `load_config`, `TursoBackend` integration |
| `test_control.py` | 12 | AUTH, subscribe ACL, PING/PONG encode/decode |
| `test_security.py` | 14 | Re-auth guard, ACL rejection, token constant-time compare, payload size limits |
| `test_protocol_logic.py` | 10 | Protocol state machine, auth/subscribe flow, keepalive logic |
| `test_stats.py` | 12 | StatsCollector, ConnectionStats, ServerStats |

---

## Security hardening summary

- Re-auth guard: `handle_auth` rejects any second AUTH attempt on an already-authenticated connection
- 1:1 GCS → vehicle ACL: `handle_subscribe` rejects any `SUBSCRIBE` where the requested `vehicle_id` does not match the `allowed_vehicle_id` stored at auth time — a GCS cannot reach any vehicle it was not provisioned for
- Auth failure messaging: server sends `{"type": "AUTH_FAIL", "reason": "auth failed"}` — no sensitive information in the reason field
- Control payload limit: `decode_control` enforces `_MAX_CONTROL_PAYLOAD = 65536` bytes before calling `cbor2.loads()` — prevents memory bomb via oversized CBOR
- Frame buffer limit: `FrameDecoder.feed` enforces `_MAX_BUFFER_SIZE = 131072` bytes — prevents unbounded buffer growth from malformed streams
- Constant-time token comparison: `DatabaseStore.validate` uses `hmac.compare_digest` to prevent timing attacks

See [`AUTHENTICATION.md`](AUTHENTICATION.md) for full auth protocol documentation.

---

## Development

```bash
pip install -e ".[dev]"
mypy mavlink_relay_server/
pytest tests/ -v
```
