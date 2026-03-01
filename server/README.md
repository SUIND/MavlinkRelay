# MAVLink QUIC Relay Server

Python aioquic server that transparently relays MAVLink frames between vehicles and GCS over QUIC/TLS.

This repository implements a production-ready QUIC relay for MAVLink traffic. The server accepts QUIC/TLS connections from vehicles and ground control stations (GCS), performs a post-handshake token-based authentication over a CBOR control channel, and relays MAVLink frames on separate streams for priority and bulk traffic.

Key design goals: secure transport (QUIC/TLS), simple token-based authentication (no client TLS certs), robust framing and flow controls for MAVLink, and operational support via YAML configuration and Docker.

---

## Features

- QUIC/TLS transport (aioquic 1.3.0, ALPN `mavlink-quic-v1`)
- Token-based post-handshake authentication (no client TLS certs required)
- Separate priority (stream 4) and bulk (stream 8) MAVLink routing
- CBOR control channel (stream 0) with AUTH / AUTH_OK / AUTH_FAIL / PING / PONG
- Wire framing: `[u16_le length][raw bytes]` on all streams
- Server-side keepalive: PING every 15s, close after 45s no PONG
- YAML-based configuration with CLI override flags
- `--dry-run` flag for config validation without starting server
- JSON or text logging
- Docker + Docker Compose support
- 77 automated tests (unit + integration)

---

## Architecture

The server is organized into a small set of focused modules. The design favors clear separation of responsibilities: connection lifecycle, protocol state machine, framing, control messages, configuration, and metrics.

| Module | Purpose |
|--------|---------|
| `__main__.py` | CLI entry point, argparse, `--dry-run` |
| `server.py` | `run_server()`, QuicConfiguration, signal handlers |
| `protocol.py` | `RelayProtocol` — per-connection state machine (auth, keepalive, routing) |
| `registry.py` | `SessionRegistry`, `VehicleSession`, `GCSSession` — session tracking |
| `framing.py` | `encode_frame()`, `FrameDecoder` — `[u16_le][bytes]` wire format |
| `control.py` | `encode_control()`, `decode_control()`, `handle_auth()` — CBOR control messages |
| `config.py` | `ServerConfig`, `TokenStore` — YAML loading, token validation |
| `stats.py` | `StatsCollector`, `ConnectionStats`, `ServerStats` — metrics |

---

## Quick Start

Install, generate test certificates, validate config, and run:

```bash
# 1. Install (editable)
pip install -e .

# 2. Generate self-signed TLS cert
cd certs && bash generate_certs.sh && cd ..

# 3. Validate config without starting server
mavlink-relay-server --config config.example.yaml --dry-run

# 4. Run
mavlink-relay-server --config config.example.yaml
```

Note: entry point is `mavlink-relay-server` (installed by hatchling).

---

## Configuration reference

The server is configured via a YAML file. CLI flags can override individual values. The structure below is the full configuration reference with inline comments describing each field.

```yaml
server:
  host: "0.0.0.0"   # bind address
  port: 14550        # UDP port

tls:
  cert: "certs/cert.pem"   # server certificate
  key: "certs/key.pem"     # private key

auth:
  tokens:
    - token: "AAAAAAAAAAAAAAAAAAAAAA=="   # base64-encoded 16-byte token
      role: "vehicle"
      vehicle_id: 1
    - token: "BBBBBBBBBBBBBBBBBBBBBB=="
      role: "gcs"
      gcs_id: "gcs-alpha"

relay:
  bulk_queue_max: 100
  priority_queue_max: 500

keepalive:
  interval_s: 15    # PING interval
  timeout_s: 45     # close connection if no PONG within this window

log_level: "INFO"    # INFO | DEBUG | WARNING | ERROR
log_format: "text"   # text | json
```

Token generation command:
```bash
python3 -c "import os, base64; print(base64.b64encode(os.urandom(16)).decode())"
```

---

## CLI flags

| Flag | Description |
|------|-------------|
| `--config` | Path to YAML config file |
| `--host` | Override `server.host` |
| `--port` | Override `server.port` |
| `--cert` | Override `tls.cert` |
| `--key` | Override `tls.key` |
| `--log-level` | Override `log_level` |
| `--auth-timeout` | Auth timeout in seconds (default: 10) |
| `--dry-run` | Validate config and print, then exit |

---

## TLS certificates

A helper script creates a self-signed certificate suitable for development and integration testing.

```bash
cd certs && bash generate_certs.sh
```

The script generates an EC certificate (prime256v1). Clients may optionally validate the server cert using `ca_cert_path` or skip validation for trusted networks. No client certificate is required — authentication uses the post-handshake token exchange.

Cross-reference: see [`AUTHENTICATION.md`](AUTHENTICATION.md) for the full auth flow.

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

The project includes a comprehensive automated test suite. There are 77 tests covering framing, protocol logic, configuration validation, security checks, registry behavior, control messages, and metrics.

```bash
# Install dev dependencies
pip install -e ".[dev]"

# Run all 77 tests
cd /path/to/server && .venv/bin/pytest tests/ -v

# Or via pytest directly
pytest tests/ -v
```

Test suite overview:

| File | Tests | What it covers |
|------|-------|----------------|
| `test_framing.py` | 8 | `encode_frame`, `FrameDecoder` basic cases |
| `test_framing_extended.py` | 8 | Fragmentation, oversized frames, buffer limits |
| `test_registry.py` | 11 | Session registration, routing, vehicle/GCS lifecycle |
| `test_config.py` | 6 | YAML loading, token decode, validation errors |
| `test_control.py` | 10 | AUTH, AUTH_OK, AUTH_FAIL, PING/PONG encode/decode |
| `test_security.py` | 12 | Re-auth guard, token constant-time compare, payload size limits |
| `test_protocol_logic.py` | 10 | Protocol state machine, auth timeout, keepalive logic |
| `test_stats.py` | 12 | StatsCollector, ConnectionStats, ServerStats |

---

## Security hardening summary

The server applies multiple defensive measures to reduce attack surface and limit resource abuse:

- Re-auth guard: `handle_auth` rejects any second AUTH attempt on an already-authenticated connection
- Auth failure messaging: server sends `{"type": "AUTH_FAIL", "reason": "auth failed"}` — no sensitive information in the reason field
- Control payload limit: `decode_control` enforces `_MAX_CONTROL_PAYLOAD = 65536` bytes before calling `cbor2.loads()` — prevents memory bomb via oversized CBOR
- Frame buffer limit: `FrameDecoder.feed` enforces `_MAX_BUFFER_SIZE = 131072` bytes — prevents unbounded buffer growth from malformed streams
- Constant-time token comparison: `TokenStore.validate` uses `hmac.compare_digest` to prevent timing attacks

See [`AUTHENTICATION.md`](AUTHENTICATION.md) for full auth protocol documentation.

---

## Development

Install dev dependencies, run type checks and the test suite:

```bash
pip install -e ".[dev]"
mypy mavlink_relay_server/
pytest tests/ -v
```

---

If you need more detailed operational notes (logging configuration, production TLS provisioning, or deployment hints) see the other repository documents and the `AUTHENTICATION.md` file for authentication details.
