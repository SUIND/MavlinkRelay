# MAVLink QUIC Relay System — Python Server Implementation Plan

## TL;DR

> **Quick Summary**: Build a production Python asyncio relay server using aioquic that accepts QUIC connections from Jetson vehicle nodes and Android GCS clients, authenticates them via token-based AUTH, manages session/subscription state, and bidirectionally relays MAVLink frames between subscribed pairs — with backpressure, keepalive, monitoring, and graceful shutdown.
>
> **Deliverables**:
> - `mavlink_relay_server` Python package with `__main__.py` entry point
> - aioquic-based QUIC server with TLS 1.3 and custom ALPN `"mavlink-quic-v1"`
> - Session registry (vehicles, GCS clients, subscriptions)
> - AUTH + SUBSCRIBE control protocol (CBOR on stream 0)
> - Bidirectional MAVLink frame relay across priority/bulk streams
> - Backpressure: drop-oldest policy on bulk relay queues
> - PING/PONG keepalive (15s interval, 45s timeout)
> - Monitoring: structured JSON logging of connection/relay statistics
> - pytest test suite with mock QUIC clients
> - Docker-ready deployment (Dockerfile + docker-compose)
>
> **Estimated Effort**: Large
> **Parallel Execution**: YES — 4 waves
> **Critical Path**: Task 1 (scaffold) → Task 2 (QUIC server core) → Task 4 (session registry) → Task 5 (relay logic) → Task 8 (tests)

---

## Context

### Original Request
Build the Python relay server component of a 3-part MAVLink QUIC relay system. This server sits between Jetson vehicle nodes (C++ ROS1 + msquic) and Android GCS clients (QGroundControl + msquic), relaying MAVLink frames bidirectionally over QUIC.

### Interview Summary
**Key Discussions**:
- **Server language/framework**: Python 3 with aioquic (asyncio-based QUIC)
- **Scale target**: 10+ vehicles, 50+ GCS clients, 5000+ frames/sec aggregate
- **Authentication**: Token-based (opaque 128-bit random tokens), post-handshake on control stream
- **Wire protocol**: `[u16_le length][raw MAVLink bytes]` per stream — shared with Jetson and GCS plans
- **Control messages**: CBOR-encoded on stream 0 (AUTH, AUTH_OK, AUTH_FAIL, SUBSCRIBE, SUB_OK, SUB_FAIL, PING, PONG)
- **Streams**: 3 persistent bidirectional QUIC streams per connection (control=0, priority=4, bulk=8)
- **Bidirectional**: Vehicle→GCS telemetry AND GCS→Vehicle commands
- **Test strategy**: Tests after implementation (pytest), no TDD
- **Scope**: ONLY the relay server. Not the Jetson node, not the GCS.

### Research Findings
- **aioquic API**: One `QuicConnectionProtocol` instance per connection. Override `quic_event_received()` to handle `StreamDataReceived`, `HandshakeCompleted`, `ConnectionTerminated`. Shared state via class attribute or registry passed through `create_protocol` closure.
- **Sending data**: `self._quic.send_stream_data(stream_id, data)` then `self.transmit()`. Batch multiple `send_stream_data` calls before one `transmit()` for throughput.
- **Backpressure**: aioquic has no explicit "is buffer full" API. Use application-level queues with `asyncio.Queue(maxsize=N)` for backpressure.
- **Production gotchas**: aioquic memory leak in `remote_challenges` (fixed in ≥1.0.0). Cap at ~115 Mbps per connection. Don't do heavy work in `quic_event_received()` — offload via `asyncio.create_task()` if needed.
- **CBOR library**: `cbor2` (v5.7.1+) — most actively maintained Python CBOR library.
- **TLS setup**: `QuicConfiguration(is_client=False, alpn_protocols=[...])` + `config.load_cert_chain(cert, key)`.
- **Graceful shutdown**: `protocol.close(error_code, reason_phrase)` per connection; `server.close()` for all.

### Metis Review
**Identified Gaps** (all addressed):
- **Stream ID assignment**: Client-initiated bidirectional streams use IDs 0, 4, 8, 12... (QUIC spec: `stream_id = 4*N`). Server must map received stream IDs to roles (first opened = control, second = priority, third = bulk) OR use a control-stream negotiation to assign roles. **Applied**: First 3 client-initiated bidi streams are mapped by order: stream 0 = control, stream 4 = priority, stream 8 = bulk.
- **Subscription model**: One GCS subscribes to one vehicle? Many GCS to one vehicle? Many vehicles to one GCS? **Applied**: Many-to-many. Multiple GCS can subscribe to the same vehicle. One GCS can subscribe to one vehicle at a time (re-SUBSCRIBE to switch).
- **Token storage**: Where does the server store valid tokens? **Applied**: Config file (YAML/TOML) with token→role+vehicle_id mapping. Out of scope: token generation/rotation mechanism.
- **Frame forwarding atomicity**: When relaying vehicle→GCS, must the full length-prefixed frame be sent atomically? **Applied**: Yes — each `send_stream_data()` call contains one complete `[u16_le len][payload]` frame.
- **Disconnection cascade**: When vehicle disconnects, should subscribed GCS clients be notified? **Applied**: Yes — send a control message `VEHICLE_OFFLINE {vehicle_id}` on the GCS control stream.
- **Server-initiated streams**: Server does NOT initiate streams. All 3 streams are client-initiated. Server responds on the same stream IDs.
- **Concurrent writes to same stream**: When multiple GCS send commands to the same vehicle, the server must serialize writes to the vehicle's priority/bulk stream. **Applied**: Use `asyncio.Lock` per vehicle connection for stream writes.
- **QUIC connection migration**: aioquic supports it automatically — no special handling needed.

---

## System Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │  Python Relay Server (THIS PLAN)            │
                    │                                             │
                    │  ┌───────────────────────────────────────┐  │
                    │  │ SessionRegistry                       │  │
                    │  │                                       │  │
                    │  │  vehicles: {vid: VehicleSession}      │  │
                    │  │  gcs_clients: {gid: GCSSession}       │  │
                    │  │  subscriptions: {vid: {gid, gid,...}} │  │
                    │  └──────────┬────────────────────────────┘  │
                    │             │ lookup                        │
                    │  ┌──────────┴────────────────────────────┐  │
                    │  │ RelayProtocol (per connection)         │  │
                    │  │                                       │  │
                    │  │  quic_event_received(event):          │  │
                    │  │    HandshakeCompleted → await AUTH     │  │
                    │  │    StreamDataReceived → relay/ctrl     │  │
                    │  │    ConnectionTerminated → cleanup      │  │
                    │  │                                       │  │
                    │  │  Streams (client-initiated):           │  │
                    │  │    Stream 0: Control (AUTH/SUB/PING)  │  │
                    │  │    Stream 4: Priority MAVLink         │  │
                    │  │    Stream 8: Bulk MAVLink             │  │
                    │  └───────────────────────────────────────┘  │
                    │                                             │
                    │  ┌───────────────────────────────────────┐  │
                    │  │ aioquic QUIC Server                    │  │
                    │  │ TLS 1.3 + ALPN "mavlink-quic-v1"     │  │
                    │  │ UDP :14550                            │  │
                    │  └───────────────────────────────────────┘  │
                    └──────────┬──────────────────┬───────────────┘
                               │                  │
              QUIC/TLS 1.3     │                  │     QUIC/TLS 1.3
                               │                  │
                    ┌──────────┴─────┐    ┌───────┴──────────┐
                    │ Jetson Vehicle  │    │ Android GCS      │
                    │ (msquic C++)    │    │ (QGC + msquic)   │
                    │                │    │                  │
                    │ Sends:         │    │ Sends:           │
                    │  AUTH(vehicle)  │    │  AUTH(gcs)       │
                    │  MAVLink frames │    │  SUBSCRIBE(vid)  │
                    │                │    │  MAVLink commands │
                    └────────────────┘    └──────────────────┘
```

### Data Flow: Relay Paths

```
VEHICLE → SERVER → GCS (Telemetry):
  Vehicle sends MAVLink frame on priority/bulk stream
  → Server receives StreamDataReceived
  → Server looks up subscriptions for this vehicle_id
  → Server forwards frame to all subscribed GCS connections (same stream type)

GCS → SERVER → VEHICLE (Commands):
  GCS sends MAVLink frame on priority/bulk stream
  → Server receives StreamDataReceived
  → Server looks up which vehicle this GCS is subscribed to
  → Server forwards frame to that vehicle's connection (same stream type)
```

### Shared Protocol Constants (Cross-Plan Consistency)

| Constant | Value | Also In |
|----------|-------|---------|
| ALPN | `"mavlink-quic-v1"` | Jetson plan, GCS plan |
| Control stream ID | 0 (first client bidi) | Jetson plan, GCS plan |
| Priority stream ID | 4 (second client bidi) | Jetson plan, GCS plan |
| Bulk stream ID | 8 (third client bidi) | Jetson plan, GCS plan |
| Wire framing | `[u16_le length][raw MAVLink]` | Jetson plan, GCS plan |
| Control encoding | CBOR | Jetson plan, GCS plan |
| Keepalive interval | 15 seconds | Jetson plan, GCS plan |
| Keepalive timeout | 45 seconds (3× missed) | Jetson plan, GCS plan |
| Reconnect backoff | 1s→2s→4s→8s→16s→30s cap, ±10% jitter | Jetson plan (client-side) |
| AUTH token | Opaque 128-bit random | Jetson plan, GCS plan |

### Control Message Formats (CBOR)

```
AUTH (client → server):
  {
    "type": "AUTH",
    "token": <bytes: 16-byte auth token>,
    "role": "vehicle" | "gcs",
    "vehicle_id": <int: required if role=="vehicle">,
    "gcs_id": <str: required if role=="gcs">
  }

AUTH_OK (server → client):
  {"type": "AUTH_OK"}

AUTH_FAIL (server → client):
  {"type": "AUTH_FAIL", "reason": <str>}

SUBSCRIBE (gcs → server):
  {"type": "SUBSCRIBE", "vehicle_id": <int>}

SUB_OK (server → gcs):
  {"type": "SUB_OK", "vehicle_id": <int>}

SUB_FAIL (server → gcs):
  {"type": "SUB_FAIL", "vehicle_id": <int>, "reason": <str>}

PING (either → either):
  {"type": "PING", "ts": <float: unix timestamp>}

PONG (either → either):
  {"type": "PONG", "ts": <float: original timestamp from PING>}

VEHICLE_OFFLINE (server → gcs):
  {"type": "VEHICLE_OFFLINE", "vehicle_id": <int>}
```

---

## Work Objectives

### Core Objective
Build a production-ready Python asyncio QUIC relay server that transparently and efficiently relays MAVLink frames between authenticated vehicle nodes and subscribed GCS clients.

### Concrete Deliverables
- Python package `mavlink_relay_server/` with:
  - `__main__.py` entry point (`python -m mavlink_relay_server`)
  - `server.py` — aioquic server setup and main loop
  - `protocol.py` — `RelayProtocol(QuicConnectionProtocol)` subclass
  - `registry.py` — `SessionRegistry` with vehicle/GCS/subscription tracking
  - `framing.py` — length-prefix frame encoder/decoder
  - `control.py` — CBOR control message handler (AUTH, SUBSCRIBE, PING/PONG)
  - `config.py` — Configuration loader (YAML)
  - `stats.py` — Connection/relay statistics
  - `py.typed` marker + type annotations throughout
- `config.example.yaml` — example server configuration
- `certs/` directory with self-signed certificate generation script
- `Dockerfile` + `docker-compose.yml`
- `pyproject.toml` with dependencies
- `tests/` directory with pytest test suite
- `README.md`

### Definition of Done
- [ ] `python -m mavlink_relay_server --config config.example.yaml --cert certs/cert.pem --key certs/key.pem` starts and listens on configured port
- [ ] Vehicle client connects, sends AUTH(role=vehicle), receives AUTH_OK, and can send MAVLink frames
- [ ] GCS client connects, sends AUTH(role=gcs), sends SUBSCRIBE(vehicle_id), receives SUB_OK
- [ ] MAVLink frame sent by vehicle on priority stream is forwarded to subscribed GCS on priority stream within 10ms
- [ ] MAVLink frame sent by GCS on priority stream is forwarded to subscribed vehicle on priority stream within 10ms
- [ ] Bulk stream drops oldest frame when relay queue exceeds configured max size
- [ ] PING sent by client receives PONG within 100ms
- [ ] Client with invalid token receives AUTH_FAIL and connection is closed
- [ ] When vehicle disconnects, subscribed GCS receives VEHICLE_OFFLINE message
- [ ] Server handles 10+ simultaneous vehicle connections and 50+ GCS connections
- [ ] All pytest tests pass
- [ ] Docker container builds and runs

### Must Have
- aioquic QUIC server with TLS 1.3 and ALPN `"mavlink-quic-v1"`
- Per-connection `RelayProtocol` instances
- Shared `SessionRegistry` across all connections
- CBOR-encoded control messages on stream 0 (AUTH, AUTH_OK, AUTH_FAIL, SUBSCRIBE, SUB_OK, SUB_FAIL, PING, PONG, VEHICLE_OFFLINE)
- Length-prefix wire framing `[u16_le length][payload]` on streams 4 and 8
- Bidirectional MAVLink relay: vehicle↔GCS
- Many-to-many subscriptions (multiple GCS per vehicle)
- Application-level backpressure with drop-oldest on bulk relay queues
- Keepalive: server sends PING every 15s, expects PONG within 45s
- Token validation from config file
- Per-vehicle write lock (serialize GCS→vehicle forwarding)
- Structured JSON logging with connection events and relay statistics
- Graceful shutdown on SIGINT/SIGTERM
- Type annotations throughout (mypy-compatible)
- Python 3.10+ (match statement compatible)

### Must NOT Have (Guardrails)
- **NO** MAVLink message parsing or validation — server is a transparent frame relay, it does NOT interpret MAVLink content
- **NO** priority classification — server relays frames on whichever stream they arrive on. Priority classification is the client's responsibility (Jetson/GCS plans)
- **NO** token generation or rotation — tokens are configured statically. Token management is out of scope.
- **NO** persistent storage or database — all state is in-memory, ephemeral per server lifetime
- **NO** HTTP/REST/WebSocket API — QUIC only
- **NO** web dashboard or admin UI — monitoring is JSON logs only
- **NO** message rate limiting — backpressure via queue drops only
- **NO** multi-server clustering or replication — single server instance
- **NO** MAVLink routing by sysid/compid — relay is per vehicle subscription, not per MAVLink address
- **NO** QUIC datagram support — reliable streams only
- **NO** automatic TLS certificate renewal — certs are loaded at startup from file paths
- **NO** custom congestion control — use aioquic/QUIC defaults

---

## Verification Strategy

> **UNIVERSAL RULE: ZERO HUMAN INTERVENTION**
>
> ALL tasks are verifiable WITHOUT any human action.

### Test Decision
- **Infrastructure exists**: NO (new project)
- **Automated tests**: YES (tests after implementation)
- **Framework**: pytest + pytest-asyncio

### Agent-Executed QA Scenarios (MANDATORY — ALL tasks)

Every task includes specific agent-executable QA scenarios using Bash (Python commands, pytest, curl-like QUIC client tests).

**Verification Tool by Deliverable Type:**

| Type | Tool | How Agent Verifies |
|------|------|-------------------|
| Python build/install | Bash (pip install, python -m) | Package installs, entry point runs |
| Server startup | Bash (python -m + timeout) | Server binds port, logs "listening" |
| QUIC protocol | Bash (pytest with mock aioquic clients) | Protocol test assertions pass |
| Relay logic | Bash (pytest integration tests) | End-to-end relay tests pass |
| Docker | Bash (docker build + docker run) | Container starts, binds port |

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately):
├── Task 1: Scaffold Python project + dependencies
└── Task 3: Length-prefix frame encoder/decoder (standalone module)

Wave 2 (After Wave 1):
├── Task 2: aioquic QUIC server core + TLS setup (depends: Task 1)
├── Task 4: Session registry (depends: Task 1)
└── Task 6: Configuration loader + token store (depends: Task 1)

Wave 3 (After Wave 2):
├── Task 5: Control protocol + relay integration (depends: Tasks 2, 3, 4, 6)
└── Task 7: Keepalive + disconnect handling + VEHICLE_OFFLINE (depends: Tasks 2, 4)

Wave 4 (After Wave 3):
├── Task 8: Tests — pytest suite (depends: Tasks 5, 7)
├── Task 9: Monitoring + statistics logging (depends: Task 5)
└── Task 10: Docker + deployment (depends: Task 5)

Critical Path: Task 1 → Task 2 → Task 5 → Task 8
Parallel Speedup: ~45% faster than sequential
```

### Dependency Matrix

| Task | Depends On | Blocks | Can Parallelize With |
|------|------------|--------|---------------------|
| 1 | None | 2, 4, 6 | 3 |
| 2 | 1 | 5, 7 | 3, 4, 6 |
| 3 | None | 5 | 1, 4, 6 |
| 4 | 1 | 5, 7 | 2, 3, 6 |
| 5 | 2, 3, 4, 6 | 8, 9, 10 | 7 |
| 6 | 1 | 5 | 2, 3, 4 |
| 7 | 2, 4 | 8 | 5, 6 |
| 8 | 5, 7 | None | 9, 10 |
| 9 | 5 | None | 7, 8, 10 |
| 10 | 5 | None | 7, 8, 9 |

### Agent Dispatch Summary

| Wave | Tasks | Recommended Agents |
|------|-------|-------------------|
| 1 | 1, 3 | task(category="quick") for scaffold; task(category="quick") for framing |
| 2 | 2, 4, 6 | task(category="deep") for QUIC server; task(category="business-logic") for registry; task(category="quick") for config |
| 3 | 5, 7 | task(category="deep") for relay integration; task(category="unspecified-high") for keepalive |
| 4 | 8, 9, 10 | task(category="unspecified-high") for tests; task(category="quick") for stats; task(category="quick") for Docker |

---

## TODOs

- [ ] 1. Scaffold Python project with dependencies

  **What to do**:
  - Create the project directory structure:
    ```
    mavlink_relay_server/
    ├── pyproject.toml
    ├── README.md
    ├── config.example.yaml
    ├── Dockerfile
    ├── docker-compose.yml
    ├── certs/
    │   └── generate_certs.sh
    ├── mavlink_relay_server/
    │   ├── __init__.py
    │   ├── __main__.py
    │   ├── server.py
    │   ├── protocol.py
    │   ├── registry.py
    │   ├── framing.py
    │   ├── control.py
    │   ├── config.py
    │   ├── stats.py
    │   └── py.typed
    └── tests/
        ├── __init__.py
        ├── conftest.py
        └── (test files added in Task 8)
    ```
  - `pyproject.toml`:
    - Dependencies: `aioquic>=1.0.0`, `cbor2>=5.6.0`, `pyyaml>=6.0`
    - Dev dependencies: `pytest`, `pytest-asyncio`, `mypy`
    - Entry point: `mavlink-relay-server = "mavlink_relay_server.__main__:main"`
    - Python version: `>=3.10`
    - Build system: `hatchling` or `setuptools`
  - `__main__.py`: Parse CLI args (`--config`, `--cert`, `--key`, `--host`, `--port`), print "Starting..." and exit (placeholder)
  - `generate_certs.sh`: OpenSSL commands to generate self-signed CA + server cert for development:
    ```bash
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
      -days 365 -noenc -keyout key.pem -out cert.pem \
      -subj "/CN=mavlink-relay"
    ```
  - `config.example.yaml`: Example configuration structure:
    ```yaml
    server:
      host: "0.0.0.0"
      port: 14550
    tls:
      cert: "certs/cert.pem"
      key: "certs/key.pem"
    auth:
      tokens:
        - token: "base64-encoded-128-bit-token"
          role: "vehicle"
          vehicle_id: 1
        - token: "base64-encoded-128-bit-token"
          role: "gcs"
          gcs_id: "gcs-alpha"
    relay:
      bulk_queue_max: 100
      priority_queue_max: 500
    keepalive:
      interval_s: 15
      timeout_s: 45
    ```
  - Verify: `pip install -e .` succeeds, `python -m mavlink_relay_server --help` shows usage

  **Must NOT do**:
  - Do NOT implement any server logic yet — just verify the skeleton installs and runs
  - Do NOT generate actual TLS certificates — just provide the script
  - Do NOT add Docker build logic yet — just create empty Dockerfile

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Standard Python project scaffolding with well-known patterns
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `frontend-ui-ux`: No UI involved
    - `playwright`: No browser involved

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 3)
  - **Blocks**: Tasks 2, 4, 6
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - aioquic examples directory structure: https://github.com/aiortc/aioquic/tree/main/examples
  - Python project layout: https://packaging.python.org/en/latest/tutorials/packaging-projects/

  **API/Type References**:
  - aioquic `QuicConfiguration`: https://github.com/aiortc/aioquic/blob/main/src/aioquic/quic/configuration.py
  - `cbor2` API: https://cbor2.readthedocs.io/

  **Documentation References**:
  - pyproject.toml spec: https://packaging.python.org/en/latest/specifications/pyproject-toml/

  **Acceptance Criteria**:

  - [ ] `pip install -e .` succeeds without errors
  - [ ] `python -m mavlink_relay_server --help` prints usage and exits 0
  - [ ] `generate_certs.sh` generates `cert.pem` and `key.pem` when run
  - [ ] `config.example.yaml` is valid YAML (parseable by `python -c "import yaml; yaml.safe_load(open('config.example.yaml'))"`)
  - [ ] All `.py` files have type stubs / `py.typed` marker present

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Project installs and entry point works
    Tool: Bash
    Preconditions: Python 3.10+ available, virtual environment created
    Steps:
      1. python -m venv .venv && source .venv/bin/activate
      2. pip install -e ".[dev]"
      3. Assert: exit code 0, no errors
      4. python -m mavlink_relay_server --help
      5. Assert: stdout contains "usage" or "--config"
      6. Assert: exit code 0
    Expected Result: Package installs and CLI shows help
    Evidence: pip install output + CLI help output captured

  Scenario: Certificate generation script works
    Tool: Bash
    Preconditions: openssl installed
    Steps:
      1. cd certs && bash generate_certs.sh
      2. Assert: cert.pem exists and is valid x509 (openssl x509 -in cert.pem -noout -text)
      3. Assert: key.pem exists (openssl ec -in key.pem -check -noout)
    Expected Result: Valid TLS cert+key generated
    Evidence: openssl verification output captured
  ```

  **Commit**: YES
  - Message: `feat(server): scaffold Python relay server project with dependencies`
  - Files: all files in `mavlink_relay_server/`
  - Pre-commit: `pip install -e . && python -m mavlink_relay_server --help`

---

- [ ] 2. Implement aioquic QUIC server core with TLS

  **What to do**:
  - Implement `server.py`:
    - `async def run_server(config: ServerConfig) -> None`:
      - Create `QuicConfiguration(is_client=False, alpn_protocols=["mavlink-quic-v1"])`
      - Set `max_data=10_485_760` (10MB connection-wide flow control)
      - Set `max_stream_data=1_048_576` (1MB per-stream flow control)
      - Load TLS cert chain: `configuration.load_cert_chain(config.cert_path, config.key_path)`
      - Create `SessionRegistry` instance (from Task 4 — use stub for now)
      - Use closure to pass registry to protocol factory:
        ```python
        async def run_server(config):
            registry = SessionRegistry()
            await serve(
                host=config.host,
                port=config.port,
                configuration=quic_config,
                create_protocol=lambda *args, **kwargs: RelayProtocol(*args, registry=registry, **kwargs),
            )
        ```
      - Handle SIGINT/SIGTERM for graceful shutdown: `loop.add_signal_handler(signal.SIGINT, server.close)`
      - Log "Listening on {host}:{port}" on startup

  - Implement `protocol.py` — `RelayProtocol(QuicConnectionProtocol)`:
    - `__init__`: Accept `registry` parameter. Initialize stream ID tracking, auth state, session data.
    - `quic_event_received(event: QuicEvent)`:
      - `HandshakeCompleted`: Log connection, record ALPN. Start auth timeout timer (10s).
      - `StreamDataReceived`: Dispatch to stream handler based on `event.stream_id`:
        - Map first 3 client-initiated bidi stream IDs to roles:
          - Stream ID 0 → control
          - Stream ID 4 → priority
          - Stream ID 8 → bulk
        - Control stream → `_handle_control_data(event.data)`
        - Priority/Bulk stream → `_handle_mavlink_data(event.stream_id, event.data)` (stub for Task 5)
      - `ConnectionTerminated`: Call cleanup (stub for Task 7)
    - Stream accumulation buffer per stream ID (partial CBOR/frame handling)
    - Auth timeout: if no AUTH received within 10s of handshake, close connection

  - Implement `__main__.py`:
    - Parse CLI args: `--config`, `--cert`, `--key`, `--host` (default 0.0.0.0), `--port` (default 14550), `--log-level`
    - Load config from YAML file
    - Call `asyncio.run(run_server(config))`

  **Must NOT do**:
  - Do NOT implement relay logic — that's Task 5. Just log received data.
  - Do NOT implement control message parsing — that's Task 5. Just buffer incoming control data.
  - Do NOT implement session registry — that's Task 4. Use a stub class.
  - Do NOT implement keepalive — that's Task 7.

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Core async QUIC server setup with aioquic API, TLS, signal handling — requires understanding aioquic's event model
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `playwright`: No browser testing needed

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 6)
  - **Blocks**: Tasks 5, 7
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - aioquic `QuicConnectionProtocol` subclassing: https://github.com/aiortc/aioquic/blob/main/src/aioquic/asyncio/protocol.py — `quic_event_received()` override pattern
  - aioquic DoQ server example: https://github.com/aiortc/aioquic/blob/main/examples/doq_server.py — server setup, `serve()` call pattern, signal handling
  - aioquic HTTP/3 server: https://github.com/aiortc/aioquic/blob/main/examples/http3_server.py — multi-stream dispatching pattern

  **API/Type References**:
  - `aioquic.asyncio.serve()`: `async def serve(host, port, *, configuration, create_protocol, retry=False, ...) -> QuicServer`
  - `QuicConnectionProtocol.__init__(self, quic: QuicConnection, stream_handler=None)`
  - `QuicEvent` subclasses: `HandshakeCompleted`, `StreamDataReceived(data, end_stream, stream_id)`, `ConnectionTerminated(error_code, frame_type, reason_phrase)`
  - `self._quic.send_stream_data(stream_id: int, data: bytes, end_stream: bool = False)`
  - `self.transmit()` — flush pending QUIC packets

  **External References**:
  - aioquic API docs: https://aioquic.readthedocs.io/
  - QUIC stream ID rules: RFC 9000 §2.1 — client-initiated bidirectional streams have IDs 0, 4, 8, 12, ...

  **Acceptance Criteria**:

  - [ ] `python -m mavlink_relay_server --config config.example.yaml --cert certs/cert.pem --key certs/key.pem` starts and logs "Listening on 0.0.0.0:14550"
  - [ ] Server accepts a QUIC connection from an aioquic test client with ALPN `"mavlink-quic-v1"`
  - [ ] Server logs "HandshakeCompleted" when client connects
  - [ ] Server logs "ConnectionTerminated" when client disconnects
  - [ ] Server shuts down cleanly on SIGINT (no traceback, no zombie coroutines)
  - [ ] If client sends data on stream 0, server logs it as control stream data
  - [ ] If client doesn't send AUTH within 10s, connection is closed by server

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Server starts and accepts QUIC connection
    Tool: Bash
    Preconditions: Certs generated, package installed
    Steps:
      1. Start server in background: python -m mavlink_relay_server --config config.example.yaml --cert certs/cert.pem --key certs/key.pem &
      2. Wait 2s for startup
      3. Assert: server log contains "Listening on"
      4. Run test client script (inline Python using aioquic):
         python -c "
         import asyncio
         from aioquic.asyncio import connect
         from aioquic.quic.configuration import QuicConfiguration
         async def test():
             config = QuicConfiguration(alpn_protocols=['mavlink-quic-v1'])
             config.verify_mode = False  # self-signed cert
             async with connect('localhost', 14550, configuration=config) as protocol:
                 await asyncio.sleep(1)
         asyncio.run(test())
         "
      5. Assert: server log contains "HandshakeCompleted"
      6. Kill server (SIGINT)
      7. Assert: server exits cleanly (exit code 0, no traceback)
    Expected Result: Server starts, accepts connection, shuts down cleanly
    Evidence: Server log output captured

  Scenario: Auth timeout closes connection
    Tool: Bash
    Preconditions: Server running
    Steps:
      1. Connect test client (same as above) but don't send AUTH
      2. Wait 12s
      3. Assert: server log contains "auth timeout" or "closing connection"
    Expected Result: Server closes connection after 10s auth timeout
    Evidence: Server log output captured
  ```

  **Commit**: YES
  - Message: `feat(server): implement aioquic QUIC server core with TLS and protocol skeleton`
  - Files: `mavlink_relay_server/server.py`, `mavlink_relay_server/protocol.py`, `mavlink_relay_server/__main__.py`
  - Pre-commit: `python -m mavlink_relay_server --help`

---

- [ ] 3. Implement length-prefix frame encoder/decoder

  **What to do**:
  - Create `framing.py` with standalone frame utilities:
    - `encode_frame(payload: bytes) -> bytes`: Returns `struct.pack("<H", len(payload)) + payload`
    - `class FrameDecoder`:
      - Accumulates incoming stream bytes via `feed(data: bytes) -> list[bytes]`
      - Returns zero or more complete frames (stripped of length prefix)
      - Handles partial frames across multiple `feed()` calls
      - Validates: frame length > 0, frame length ≤ 65535 (u16 max)
      - Rejects frames with length 0 (empty MAVLink frame is invalid)
    - Internal state: `_buffer: bytearray` for accumulation
    - Edge cases:
      - Data arrives 1 byte at a time → accumulates until full frame
      - Multiple frames in one `feed()` call → returns all complete frames
      - Partial length prefix (1 byte) → waits for next feed
      - Frame larger than 65535 bytes → impossible by u16_le, but guard against corrupted length

  **Must NOT do**:
  - Do NOT parse MAVLink content — just extract length-prefixed byte blobs
  - Do NOT add QUIC or asyncio dependencies — this is a pure bytes utility
  - Do NOT add CBOR logic — control messages use a different codec (Task 5)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple byte-level encoder/decoder with no external dependencies
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 1)
  - **Blocks**: Task 5
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - Jetson plan wire protocol: `[u16_le length][raw MAVLink bytes]` — MUST match exactly
  - aioquic DoQ server example frame parsing: `struct.unpack("!H", event.data[:2])` (but DoQ uses big-endian — our protocol uses little-endian `<H`)

  **API/Type References**:
  - `struct.pack("<H", length)` — little-endian unsigned 16-bit
  - `struct.unpack_from("<H", buffer, offset)` — parse from buffer at offset

  **WHY Little-Endian**: The Jetson plan (msquic/C++) and this server plan MUST agree on byte order. MAVLink itself is little-endian, so `u16_le` is consistent.

  **Acceptance Criteria**:

  - [ ] `encode_frame(b"\x01\x02\x03")` returns `b"\x03\x00\x01\x02\x03"` (LE length + payload)
  - [ ] `FrameDecoder().feed(b"\x03\x00\x01\x02\x03")` returns `[b"\x01\x02\x03"]`
  - [ ] Feeding bytes one-at-a-time across 5 calls returns frame only after last byte
  - [ ] Feeding two concatenated frames in one call returns both frames
  - [ ] Feeding a partial length prefix (1 byte) then remaining data returns frame after second feed
  - [ ] Zero-length frame (b"\x00\x00") raises or is rejected
  - [ ] Module has no imports beyond `struct` and standard library

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Frame round-trip encoding/decoding
    Tool: Bash
    Preconditions: Package installed
    Steps:
      1. python -c "
         from mavlink_relay_server.framing import encode_frame, FrameDecoder
         # Test encode
         encoded = encode_frame(b'\\xfe\\x09\\x00')
         assert encoded == b'\\x03\\x00\\xfe\\x09\\x00', f'encode failed: {encoded!r}'
         # Test decode
         decoder = FrameDecoder()
         frames = decoder.feed(encoded)
         assert frames == [b'\\xfe\\x09\\x00'], f'decode failed: {frames}'
         # Test multi-frame
         two_frames = encode_frame(b'\\x01') + encode_frame(b'\\x02\\x03')
         frames = decoder.feed(two_frames)
         assert len(frames) == 2
         assert frames[0] == b'\\x01'
         assert frames[1] == b'\\x02\\x03'
         print('ALL PASS')
         "
      2. Assert: stdout contains "ALL PASS"
      3. Assert: exit code 0
    Expected Result: All frame operations produce correct results
    Evidence: Python output captured

  Scenario: Partial frame accumulation
    Tool: Bash
    Preconditions: Package installed
    Steps:
      1. python -c "
         from mavlink_relay_server.framing import FrameDecoder
         d = FrameDecoder()
         # Feed length prefix only (partial)
         assert d.feed(b'\\x03\\x00') == []
         # Feed 2 of 3 payload bytes
         assert d.feed(b'\\xAA\\xBB') == []
         # Feed last byte
         frames = d.feed(b'\\xCC')
         assert frames == [b'\\xAA\\xBB\\xCC'], f'{frames}'
         print('PARTIAL PASS')
         "
      2. Assert: stdout contains "PARTIAL PASS"
    Expected Result: Partial frames accumulate correctly
    Evidence: Python output captured
  ```

  **Commit**: YES (groups with Task 1)
  - Message: `feat(server): add length-prefix frame encoder/decoder`
  - Files: `mavlink_relay_server/framing.py`
  - Pre-commit: inline Python verification above

---

- [ ] 4. Implement session registry

  **What to do**:
  - Create `registry.py` with `SessionRegistry` class:
    - **Data classes** (using `@dataclass`):
      ```python
      @dataclass
      class VehicleSession:
          vehicle_id: int
          protocol: "RelayProtocol"  # forward ref
          priority_stream_id: int
          bulk_stream_id: int
          control_stream_id: int
          connected_at: float
          write_lock: asyncio.Lock  # serialize GCS→vehicle writes

      @dataclass
      class GCSSession:
          gcs_id: str
          protocol: "RelayProtocol"
          priority_stream_id: int
          bulk_stream_id: int
          control_stream_id: int
          connected_at: float
          subscribed_vehicle_id: int | None = None
      ```

    - **SessionRegistry methods**:
      - `async register_vehicle(vehicle_id: int, protocol, stream_ids) -> VehicleSession`
        - Raises `ValueError` if vehicle_id already registered (duplicate vehicle)
      - `async register_gcs(gcs_id: str, protocol, stream_ids) -> GCSSession`
        - Raises `ValueError` if gcs_id already registered
      - `async unregister_vehicle(vehicle_id: int) -> set[str]`
        - Removes vehicle, returns set of gcs_ids that were subscribed (for VEHICLE_OFFLINE notification)
        - Clears subscriptions for this vehicle
      - `async unregister_gcs(gcs_id: str) -> None`
        - Removes GCS, removes from subscription sets
      - `async subscribe(gcs_id: str, vehicle_id: int) -> bool`
        - Returns True if vehicle exists and subscription created
        - If GCS was subscribed to another vehicle, unsubscribes first
      - `get_vehicle(vehicle_id: int) -> VehicleSession | None`
      - `get_gcs(gcs_id: str) -> GCSSession | None`
      - `get_subscribers(vehicle_id: int) -> list[GCSSession]`
        - Returns list of GCS sessions subscribed to this vehicle
      - `get_vehicle_for_gcs(gcs_id: str) -> VehicleSession | None`
        - Returns the vehicle session this GCS is subscribed to

    - **Thread safety**: All mutation methods are `async` and use an internal `asyncio.Lock` to prevent race conditions during concurrent connection/disconnection events

    - **Statistics properties**: `vehicle_count`, `gcs_count`, `subscription_count`

  **Must NOT do**:
  - Do NOT persist state to disk — purely in-memory
  - Do NOT import aioquic — registry is agnostic to transport
  - Do NOT handle relay logic — registry only tracks sessions and subscriptions
  - Do NOT implement token validation — that's in the control handler (Task 5)

  **Recommended Agent Profile**:
  - **Category**: `business-logic`
    - Reason: Core domain logic with data structures, subscription management, and concurrency
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 2, 6)
  - **Blocks**: Tasks 5, 7
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - Jetson plan: Vehicle connects with `vehicle_id` from AUTH message
  - GCS plan: GCS connects with `gcs_id`, then sends SUBSCRIBE with `vehicle_id`

  **API/Type References**:
  - `asyncio.Lock` for coroutine-safe mutations
  - `dataclasses.dataclass` for session data
  - Python type hints: `dict[int, VehicleSession]`, `dict[str, GCSSession]`, `dict[int, set[str]]`

  **Acceptance Criteria**:

  - [ ] Register vehicle → `get_vehicle(id)` returns session
  - [ ] Register duplicate vehicle_id → raises `ValueError`
  - [ ] Register GCS → `get_gcs(id)` returns session
  - [ ] Subscribe GCS to vehicle → `get_subscribers(vid)` includes that GCS
  - [ ] Unregister vehicle → returns subscribed gcs_ids, `get_vehicle(id)` returns None
  - [ ] Unregister GCS → removed from subscription sets
  - [ ] Subscribe to new vehicle → unsubscribes from previous automatically
  - [ ] `vehicle_count`, `gcs_count` properties are accurate

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Full session lifecycle
    Tool: Bash
    Preconditions: Package installed
    Steps:
      1. python -c "
         import asyncio
         from mavlink_relay_server.registry import SessionRegistry, VehicleSession, GCSSession

         async def test():
             reg = SessionRegistry()

             # Register vehicle
             v = await reg.register_vehicle(1, 'proto_v', (0, 4, 8))
             assert reg.vehicle_count == 1
             assert reg.get_vehicle(1) is not None

             # Register GCS
             g = await reg.register_gcs('gcs-1', 'proto_g', (0, 4, 8))
             assert reg.gcs_count == 1

             # Subscribe
             ok = await reg.subscribe('gcs-1', 1)
             assert ok is True
             subs = reg.get_subscribers(1)
             assert len(subs) == 1

             # Unregister vehicle
             notified = await reg.unregister_vehicle(1)
             assert 'gcs-1' in notified
             assert reg.vehicle_count == 0

             print('ALL PASS')

         asyncio.run(test())
         "
      2. Assert: stdout contains "ALL PASS"
    Expected Result: Full lifecycle works correctly
    Evidence: Python output captured

  Scenario: Duplicate vehicle registration rejected
    Tool: Bash
    Steps:
      1. python -c "
         import asyncio
         from mavlink_relay_server.registry import SessionRegistry

         async def test():
             reg = SessionRegistry()
             await reg.register_vehicle(1, 'p1', (0, 4, 8))
             try:
                 await reg.register_vehicle(1, 'p2', (0, 4, 8))
                 assert False, 'Should have raised'
             except ValueError:
                 print('DUPLICATE REJECTED')

         asyncio.run(test())
         "
      2. Assert: stdout contains "DUPLICATE REJECTED"
    Expected Result: Duplicate registration raises ValueError
    Evidence: Python output captured
  ```

  **Commit**: YES
  - Message: `feat(server): add session registry with vehicle/GCS/subscription tracking`
  - Files: `mavlink_relay_server/registry.py`
  - Pre-commit: inline Python verification

---

- [ ] 5. Implement control protocol handler and MAVLink relay integration

  **What to do**:
  - Implement `control.py` — CBOR control message handler:
    - `encode_control(msg: dict) -> bytes`: CBOR-encode a control message, return with length-prefix `[u16_le len][cbor bytes]`
    - `decode_control(data: bytes) -> dict`: CBOR-decode a control message
    - Message type handlers:
      - `handle_auth(protocol, msg, registry, token_store) -> bool`:
        - Validate token against token store
        - If valid: register in registry, send AUTH_OK, return True
        - If invalid: send AUTH_FAIL, close connection, return False
      - `handle_subscribe(protocol, msg, registry) -> None`:
        - Only valid for GCS role
        - Look up vehicle_id in registry
        - If found: register subscription, send SUB_OK
        - If not found: send SUB_FAIL with reason "vehicle not connected"

  - Update `protocol.py` — wire up control and relay:
    - `_handle_control_data(data: bytes)`:
      - Feed data to control stream `FrameDecoder`
      - For each complete frame: CBOR decode → dispatch by `msg["type"]`
      - AUTH → `handle_auth()`
      - SUBSCRIBE → `handle_subscribe()`
      - PING → respond with PONG immediately
    - `_handle_mavlink_data(stream_id: int, data: bytes)`:
      - Feed data to per-stream `FrameDecoder`
      - For each complete frame (raw MAVLink bytes):
        - **Vehicle connection**: Look up all subscribed GCS clients → forward frame to each GCS on same stream type (priority→priority, bulk→bulk)
        - **GCS connection**: Look up subscribed vehicle → forward frame to vehicle on same stream type
      - Use `asyncio.Lock` per-vehicle for serialized writes (prevent interleaved frames from multiple GCS)
      - **Backpressure (bulk only)**: Track per-connection outbound bulk queue. If exceeds `bulk_queue_max`, drop oldest frame, increment drop counter, log warning.
      - **Batched transmit**: After forwarding all frames from one `feed()` call, call `protocol.transmit()` once (not per-frame)
    - `_send_frame(stream_id: int, payload: bytes)`:
      - `self._quic.send_stream_data(stream_id, encode_frame(payload))`
      - Do NOT call `self.transmit()` here — caller batches

  - Implement token store in `config.py`:
    - `class TokenStore`:
      - `__init__(tokens_config: list[dict])`: Build lookup table from config
      - `validate(token: bytes) -> dict | None`: Returns `{"role": ..., "vehicle_id": ...}` or None

  **Must NOT do**:
  - Do NOT parse or validate MAVLink frame content — transparent relay
  - Do NOT do priority classification — server does not classify, it relays on the same stream type it received
  - Do NOT implement keepalive — that's Task 7
  - Do NOT implement disconnect cleanup — that's Task 7
  - Do NOT block the event loop — all operations must be non-blocking

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Core relay integration combining control protocol, session registry, and stream multiplexing — the central nervous system of the server
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO (or limited — can partially parallelize with Task 7)
  - **Parallel Group**: Wave 3
  - **Blocks**: Tasks 8, 9, 10
  - **Blocked By**: Tasks 2, 3, 4, 6

  **References**:

  **Pattern References**:
  - aioquic `quic_event_received` dispatching: https://github.com/aiortc/aioquic/blob/main/examples/doq_server.py — event loop pattern
  - Jetson plan control stream: AUTH→AUTH_OK flow, CBOR encoding, wire framing on control stream
  - Jetson plan relay architecture: outbound path (classify → priority/bulk stream), inbound path (receive → forward)

  **API/Type References**:
  - `cbor2.dumps(dict)` → bytes, `cbor2.loads(bytes)` → dict
  - `self._quic.send_stream_data(stream_id, data)` + `self.transmit()`
  - `SessionRegistry` methods from Task 4
  - `FrameDecoder` from Task 3
  - `encode_frame()` from Task 3

  **Cross-Plan Consistency**:
  - AUTH message format MUST match what Jetson plan sends (same CBOR fields: type, token, role, vehicle_id)
  - SUBSCRIBE message format MUST match what GCS plan sends (type, vehicle_id)
  - Wire framing `[u16_le length][payload]` MUST match both Jetson and GCS
  - ALPN `"mavlink-quic-v1"` MUST match all 3 components

  **Acceptance Criteria**:

  - [ ] Vehicle client: AUTH(role=vehicle, token=valid) → receives AUTH_OK
  - [ ] Vehicle client: AUTH(role=vehicle, token=invalid) → receives AUTH_FAIL, connection closed
  - [ ] GCS client: AUTH(role=gcs) → AUTH_OK → SUBSCRIBE(vehicle_id=1) → SUB_OK (if vehicle 1 connected)
  - [ ] GCS client: SUBSCRIBE(vehicle_id=99) → SUB_FAIL (vehicle not connected)
  - [ ] Vehicle sends frame on priority stream → forwarded to subscribed GCS on priority stream
  - [ ] Vehicle sends frame on bulk stream → forwarded to subscribed GCS on bulk stream
  - [ ] GCS sends frame on priority stream → forwarded to subscribed vehicle on priority stream
  - [ ] Two GCS subscribed to same vehicle → both receive vehicle's frames
  - [ ] PING on control stream → PONG response within 100ms
  - [ ] Bulk relay drops oldest frame when queue exceeds configured max
  - [ ] Batched transmit: multiple frames forwarded with single `transmit()` call

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Full AUTH + SUBSCRIBE + relay roundtrip
    Tool: Bash
    Preconditions: Server running with test config containing valid tokens for vehicle_id=1 and gcs_id="test-gcs"
    Steps:
      1. Start server in background
      2. Run integration test script (Python):
         - Create aioquic vehicle client, connect, open 3 streams
         - Send AUTH(role=vehicle, vehicle_id=1, token=<valid>) on stream 0
         - Assert: receives AUTH_OK on stream 0
         - Create aioquic GCS client, connect, open 3 streams
         - Send AUTH(role=gcs, gcs_id="test-gcs", token=<valid>) on stream 0
         - Assert: receives AUTH_OK
         - Send SUBSCRIBE(vehicle_id=1) on stream 0
         - Assert: receives SUB_OK
         - Vehicle sends MAVLink frame (b"\xfe\x09...") on stream 4 (priority)
         - Assert: GCS receives same frame on its stream 4 within 100ms
         - GCS sends MAVLink frame on stream 4
         - Assert: Vehicle receives same frame on its stream 4 within 100ms
      3. Assert: all assertions pass
      4. Kill server
    Expected Result: Full bidirectional relay works through AUTH+SUBSCRIBE flow
    Evidence: Test script output captured

  Scenario: Invalid token rejected
    Tool: Bash
    Steps:
      1. Connect client with invalid token
      2. Send AUTH(token=<wrong>)
      3. Assert: receives AUTH_FAIL with reason string
      4. Assert: connection is closed by server
    Expected Result: AUTH_FAIL and disconnection
    Evidence: Client log captured

  Scenario: Bulk backpressure drops oldest
    Tool: Bash
    Steps:
      1. Set bulk_queue_max=5 in config
      2. Vehicle connects, GCS connects and subscribes
      3. Pause GCS reading (don't read from stream 8)
      4. Vehicle sends 10 bulk frames rapidly
      5. Resume GCS reading
      6. Assert: GCS receives ≤5 most recent frames (oldest dropped)
      7. Assert: server log contains drop warning
    Expected Result: Oldest bulk frames dropped under backpressure
    Evidence: Frame sequence numbers and server logs captured
  ```

  **Commit**: YES
  - Message: `feat(server): implement control protocol (AUTH/SUBSCRIBE) and MAVLink relay logic`
  - Files: `mavlink_relay_server/control.py`, `mavlink_relay_server/protocol.py` (updated), `mavlink_relay_server/config.py` (updated)
  - Pre-commit: integration test script

---

- [ ] 6. Implement configuration loader

  **What to do**:
  - Implement `config.py` — full configuration management:
    - `@dataclass class ServerConfig`:
      - `host: str` (default "0.0.0.0")
      - `port: int` (default 14550)
      - `cert_path: str`
      - `key_path: str`
      - `bulk_queue_max: int` (default 100)
      - `priority_queue_max: int` (default 500)
      - `keepalive_interval_s: float` (default 15.0)
      - `keepalive_timeout_s: float` (default 45.0)
      - `auth_timeout_s: float` (default 10.0)
      - `log_level: str` (default "INFO")
      - `log_format: str` (default "json")
      - `tokens: list[TokenConfig]`
    - `@dataclass class TokenConfig`:
      - `token_b64: str` (base64-encoded)
      - `role: str` ("vehicle" or "gcs")
      - `vehicle_id: int | None`
      - `gcs_id: str | None`
    - `def load_config(path: str, cli_overrides: dict) -> ServerConfig`:
      - Load YAML file
      - Apply CLI argument overrides (--host, --port, --cert, --key override YAML)
      - Validate required fields (cert, key must exist)
      - Validate token entries (vehicle tokens must have vehicle_id, gcs tokens must have gcs_id)
      - Return `ServerConfig`
    - `class TokenStore` (if not already in Task 5 stub):
      - `__init__(tokens: list[TokenConfig])`: Build `dict[bytes, TokenConfig]` lookup
      - `validate(token_bytes: bytes) -> TokenConfig | None`

  **Must NOT do**:
  - Do NOT add environment variable support — YAML + CLI only
  - Do NOT add dynamic reload — config is loaded once at startup
  - Do NOT add a web UI for configuration

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Standard YAML config loading with dataclasses — straightforward
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 2, 4)
  - **Blocks**: Task 5
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - `config.example.yaml` structure from Task 1

  **API/Type References**:
  - `yaml.safe_load()` for YAML parsing
  - `base64.b64decode()` for token decoding
  - `dataclasses.dataclass` with default values

  **Acceptance Criteria**:

  - [ ] `load_config("config.example.yaml", {})` returns valid `ServerConfig`
  - [ ] CLI overrides: `load_config("config.example.yaml", {"port": 9999})` → config.port == 9999
  - [ ] Missing cert path → raises `FileNotFoundError` or `ValueError`
  - [ ] Invalid YAML → raises clear error message
  - [ ] Token validation: `token_store.validate(valid_token)` returns config, `validate(wrong)` returns None
  - [ ] Vehicle token without `vehicle_id` → validation error at load time

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Config loads and validates
    Tool: Bash
    Steps:
      1. python -c "
         from mavlink_relay_server.config import load_config
         config = load_config('config.example.yaml', {})
         assert config.port == 14550
         assert config.host == '0.0.0.0'
         assert len(config.tokens) > 0
         print(f'Loaded {len(config.tokens)} tokens')
         print('CONFIG OK')
         "
      2. Assert: stdout contains "CONFIG OK"
    Expected Result: Config loads successfully
    Evidence: Python output captured
  ```

  **Commit**: YES (groups with Task 4)
  - Message: `feat(server): add YAML configuration loader with token store`
  - Files: `mavlink_relay_server/config.py`
  - Pre-commit: inline Python verification

---

- [ ] 7. Implement keepalive (PING/PONG) and disconnect handling

  **What to do**:
  - **Server-side keepalive** (add to `RelayProtocol`):
    - On `HandshakeCompleted` + successful AUTH: start keepalive `asyncio.Task`:
      ```python
      async def _keepalive_loop(self):
          while self._connected:
              await asyncio.sleep(self._config.keepalive_interval_s)  # 15s
              self._send_ping()
              self._last_ping_sent = time.monotonic()
      ```
    - `_send_ping()`: Send CBOR PING message `{"type": "PING", "ts": time.time()}` on control stream (stream 0) using length-prefix framing
    - On receiving PONG: record `_last_pong_received = time.monotonic()`
    - **Timeout detection**: Separate `asyncio.Task` or check in keepalive loop:
      - If `time.monotonic() - _last_pong_received > keepalive_timeout_s` (45s):
        - Log warning "Client {id} keepalive timeout"
        - Close connection: `self._quic.close(error_code=0x01, reason_phrase="keepalive timeout")`
        - Trigger cleanup

  - **Disconnect handling** (update `ConnectionTerminated` handler):
    - Determine client role (vehicle or GCS)
    - **Vehicle disconnect**:
      1. `notified_gcs = await registry.unregister_vehicle(vehicle_id)`
      2. For each GCS in `notified_gcs`:
        - Send VEHICLE_OFFLINE control message: `{"type": "VEHICLE_OFFLINE", "vehicle_id": vehicle_id}`
        - via `gcs_session.protocol._send_control(encode_control(msg))`
    - **GCS disconnect**:
      1. `await registry.unregister_gcs(gcs_id)`
    - Cancel keepalive task
    - Log disconnection with session duration and stats

  - **Client PING handling** (already partially in Task 5):
    - If client sends PING → respond with PONG containing same timestamp

  **Must NOT do**:
  - Do NOT implement reconnection — the server doesn't reconnect (that's client-side)
  - Do NOT close the entire server on one client timeout
  - Do NOT block the event loop during cleanup

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Async task management, timer-based keepalive, multi-step cleanup — moderately complex
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (can overlap with Task 5 in Wave 3)
  - **Parallel Group**: Wave 3 (with Task 5)
  - **Blocks**: Task 8
  - **Blocked By**: Tasks 2, 4

  **References**:

  **Pattern References**:
  - Jetson plan keepalive: 15s interval, 45s timeout — MUST match
  - Control message format: PING/PONG with `ts` field
  - VEHICLE_OFFLINE message format

  **API/Type References**:
  - `asyncio.create_task()` for spawning keepalive loop
  - `time.monotonic()` for timeout tracking (not affected by wall clock changes)
  - `time.time()` for PING timestamp (human-readable, for latency measurement)
  - `self._quic.close(error_code, reason_phrase)`

  **Acceptance Criteria**:

  - [ ] Server sends PING on control stream every 15s after AUTH
  - [ ] Client PONG resets the timeout counter
  - [ ] If no PONG received for 45s, server closes connection
  - [ ] When vehicle disconnects, all subscribed GCS receive VEHICLE_OFFLINE
  - [ ] Keepalive task is cancelled on normal disconnect (no orphan tasks)
  - [ ] Session is fully cleaned from registry on disconnect

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Server sends PING and client responds with PONG
    Tool: Bash
    Preconditions: Server running, vehicle client connected and authenticated
    Steps:
      1. Connect vehicle client, complete AUTH
      2. Wait 16s (just past keepalive interval)
      3. Assert: client receives PING on control stream with "ts" field
      4. Client sends PONG with same "ts"
      5. Wait another 16s
      6. Assert: client receives second PING (connection still alive)
    Expected Result: Keepalive cycle works
    Evidence: Captured PING/PONG messages

  Scenario: Keepalive timeout disconnects client
    Tool: Bash
    Steps:
      1. Connect vehicle client, complete AUTH
      2. Do NOT respond to PINGs
      3. Wait 50s (past 45s timeout)
      4. Assert: connection is closed by server
      5. Assert: server log contains "keepalive timeout"
    Expected Result: Unresponsive client is disconnected
    Evidence: Server log output captured

  Scenario: Vehicle disconnect notifies subscribed GCS
    Tool: Bash
    Steps:
      1. Vehicle connects and authenticates (vehicle_id=1)
      2. GCS connects, authenticates, subscribes to vehicle_id=1
      3. Vehicle disconnects (close connection)
      4. Assert: GCS receives VEHICLE_OFFLINE(vehicle_id=1) on control stream within 1s
      5. Assert: server registry shows 0 vehicles, 1 GCS
    Expected Result: GCS notified of vehicle going offline
    Evidence: GCS control stream messages captured
  ```

  **Commit**: YES
  - Message: `feat(server): add keepalive PING/PONG, disconnect handling, and VEHICLE_OFFLINE notification`
  - Files: `mavlink_relay_server/protocol.py` (updated)
  - Pre-commit: pytest (from Task 8, if available)

---

- [ ] 8. Implement pytest test suite

  **What to do**:
  - Create comprehensive pytest test suite in `tests/`:
    - `tests/conftest.py`:
      - Fixtures for `SessionRegistry`, `TokenStore`, `ServerConfig`
      - Fixture for generating test TLS certificates (ephemeral, in-memory or tmpdir)
      - Fixture for creating a running test server (aioquic server on random port)
      - Fixture for creating test QUIC clients (vehicle and GCS)
      - `pytest-asyncio` configuration

    - `tests/test_framing.py`:
      - Test `encode_frame` with various payload sizes
      - Test `FrameDecoder` with single frame, multi-frame, partial frame, edge cases
      - Test empty frame rejection
      - Test max-size frame (65535 bytes payload)

    - `tests/test_registry.py`:
      - Test vehicle registration/unregistration
      - Test GCS registration/unregistration
      - Test subscribe/unsubscribe
      - Test duplicate registration rejection
      - Test unregister returns affected subscribers
      - Test re-subscribe (switch vehicle)

    - `tests/test_config.py`:
      - Test YAML loading
      - Test CLI overrides
      - Test validation errors (missing cert, invalid token)
      - Test token store lookup

    - `tests/test_control.py`:
      - Test CBOR encode/decode roundtrip
      - Test AUTH message validation
      - Test SUBSCRIBE message handling

    - `tests/test_protocol.py` (integration):
      - Start real aioquic server on random port with test certs
      - Connect vehicle client → AUTH → send MAVLink frame
      - Connect GCS client → AUTH → SUBSCRIBE → receive forwarded frame
      - Test bidirectional relay (GCS → vehicle)
      - Test invalid token rejection
      - Test auth timeout
      - Test PING/PONG
      - Test vehicle disconnect → VEHICLE_OFFLINE to GCS
      - Test bulk backpressure (fill queue, verify drop)

  **Must NOT do**:
  - Do NOT write tests that require external servers or real drones
  - Do NOT write flaky timing-dependent tests — use `asyncio.wait_for` with generous timeouts
  - Do NOT test MAVLink parsing (server doesn't parse MAVLink)

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Comprehensive test suite covering unit + integration with async QUIC — requires understanding all components
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with Tasks 9, 10)
  - **Blocks**: None
  - **Blocked By**: Tasks 5, 7

  **References**:

  **Pattern References**:
  - aioquic test patterns: https://github.com/aiortc/aioquic/tree/main/tests — how aioquic tests its own server/client
  - pytest-asyncio patterns: https://pytest-asyncio.readthedocs.io/

  **API/Type References**:
  - `pytest.fixture` with `scope="function"` for test isolation
  - `pytest.mark.asyncio` for async test functions
  - `aioquic.asyncio.connect()` for test client
  - `aioquic.asyncio.serve()` for test server

  **Acceptance Criteria**:

  - [ ] `pytest tests/ -v` passes with 0 failures
  - [ ] ≥20 test cases covering: framing, registry, config, control protocol, integration
  - [ ] Integration tests use real aioquic connections (not mocks)
  - [ ] No test requires internet access or external services
  - [ ] Tests complete in under 60 seconds total
  - [ ] Coverage of happy path AND error paths (invalid token, timeout, disconnect)

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: All tests pass
    Tool: Bash
    Preconditions: Package installed with dev dependencies
    Steps:
      1. pip install -e ".[dev]"
      2. pytest tests/ -v --tb=short
      3. Assert: exit code 0
      4. Assert: stdout contains "passed" with 0 "failed"
      5. Assert: at least 20 test items collected
    Expected Result: Full test suite green
    Evidence: pytest output captured

  Scenario: Integration test validates end-to-end relay
    Tool: Bash
    Steps:
      1. pytest tests/test_protocol.py -v -k "test_relay_roundtrip"
      2. Assert: test passes
      3. Assert: test validates vehicle→GCS and GCS→vehicle relay
    Expected Result: End-to-end relay validated
    Evidence: pytest verbose output captured
  ```

  **Commit**: YES
  - Message: `test(server): add comprehensive pytest suite for relay server`
  - Files: `tests/conftest.py`, `tests/test_framing.py`, `tests/test_registry.py`, `tests/test_config.py`, `tests/test_control.py`, `tests/test_protocol.py`
  - Pre-commit: `pytest tests/ -v`

---

- [ ] 9. Add monitoring and statistics logging

  **What to do**:
  - Implement `stats.py`:
    - `@dataclass class ConnectionStats`:
      - `frames_relayed_priority: int = 0`
      - `frames_relayed_bulk: int = 0`
      - `frames_dropped_bulk: int = 0`
      - `bytes_relayed: int = 0`
      - `control_messages_sent: int = 0`
      - `control_messages_received: int = 0`
      - `latency_last_ping_ms: float = 0.0`
    - `class ServerStats`:
      - Aggregates per-connection stats
      - `total_connections: int`
      - `active_vehicles: int`
      - `active_gcs: int`
      - `uptime_s: float`
      - `to_dict() -> dict` for JSON serialization

  - Add periodic stats logging to `RelayProtocol`:
    - Every 60s, log a JSON stats line:
      ```json
      {"event": "stats", "vehicles": 3, "gcs": 7, "frames_priority": 12500, "frames_bulk": 98000, "dropped_bulk": 42, "uptime_s": 3600}
      ```
    - Log on each connection/disconnection event:
      ```json
      {"event": "connect", "role": "vehicle", "id": 1, "remote": "192.168.1.100:54321"}
      {"event": "disconnect", "role": "gcs", "id": "gcs-1", "duration_s": 1800, "frames": 45000}
      ```

  - Configure Python `logging` module:
    - JSON formatter when `log_format == "json"` in config
    - Human-readable format when `log_format == "text"`
    - Log level from config (`DEBUG`, `INFO`, `WARNING`)

  **Must NOT do**:
  - Do NOT add Prometheus metrics endpoints — JSON logs only
  - Do NOT add a web dashboard
  - Do NOT persist stats to disk

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Straightforward logging and counter implementation
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with Tasks 8, 10)
  - **Blocks**: None
  - **Blocked By**: Task 5

  **References**:

  **Pattern References**:
  - Python structured logging: `logging.getLogger().info(json.dumps(...))`
  - `dataclasses.asdict()` for JSON serialization

  **Acceptance Criteria**:

  - [ ] Server logs JSON stats every 60s when running
  - [ ] Connection/disconnection events are logged with role, id, and remote address
  - [ ] `ServerStats.to_dict()` returns valid JSON-serializable dict
  - [ ] Log format is configurable (json vs text)

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Stats logging works
    Tool: Bash
    Steps:
      1. Start server with log_level=DEBUG
      2. Connect vehicle + GCS, relay a few frames
      3. Wait 65s (past stats interval)
      4. Assert: server log contains JSON with "event": "stats"
      5. Assert: "frames_priority" or "frames_bulk" > 0
    Expected Result: Stats are logged periodically
    Evidence: Server log lines captured
  ```

  **Commit**: YES
  - Message: `feat(server): add structured JSON monitoring and statistics logging`
  - Files: `mavlink_relay_server/stats.py`, `mavlink_relay_server/protocol.py` (updated)
  - Pre-commit: `pytest tests/ -v`

---

- [ ] 10. Docker deployment

  **What to do**:
  - Implement `Dockerfile`:
    ```dockerfile
    FROM python:3.12-slim
    WORKDIR /app
    COPY pyproject.toml .
    COPY mavlink_relay_server/ mavlink_relay_server/
    RUN pip install --no-cache-dir .
    COPY config.example.yaml config.yaml
    COPY certs/ certs/
    EXPOSE 14550/udp
    CMD ["python", "-m", "mavlink_relay_server", "--config", "config.yaml", "--cert", "certs/cert.pem", "--key", "certs/key.pem"]
    ```
  - Implement `docker-compose.yml`:
    ```yaml
    services:
      relay-server:
        build: .
        ports:
          - "14550:14550/udp"
        volumes:
          - ./config.yaml:/app/config.yaml:ro
          - ./certs:/app/certs:ro
        restart: unless-stopped
    ```
  - **IMPORTANT**: QUIC runs over UDP — port mapping must be UDP (`14550/udp`)
  - Add health check: `HEALTHCHECK` not applicable for UDP. Instead, add a `--dry-run` CLI flag that validates config and exits 0.

  **Must NOT do**:
  - Do NOT add Kubernetes manifests — Docker only
  - Do NOT include real TLS certificates in the image
  - Do NOT add multi-stage builds — keep simple for now

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Standard Dockerfile with straightforward build
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4 (with Tasks 8, 9)
  - **Blocks**: None
  - **Blocked By**: Task 5

  **References**:

  **Pattern References**:
  - Python Docker best practices: https://docs.docker.com/language/python/

  **External References**:
  - QUIC is UDP-based — Docker port mapping must use `/udp` suffix

  **Acceptance Criteria**:

  - [ ] `docker build -t mavlink-relay-server .` succeeds
  - [ ] `docker run --rm mavlink-relay-server python -m mavlink_relay_server --help` shows usage
  - [ ] `docker compose up -d` starts server and binds UDP port 14550
  - [ ] Container exits cleanly on `docker compose down` (SIGTERM handled)

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Docker build and run
    Tool: Bash
    Preconditions: Docker installed and running
    Steps:
      1. Generate test certs: cd certs && bash generate_certs.sh && cd ..
      2. docker build -t mavlink-relay-server .
      3. Assert: build succeeds (exit code 0)
      4. docker run --rm mavlink-relay-server python -m mavlink_relay_server --help
      5. Assert: stdout contains "--config"
      6. docker run --rm -d --name relay-test -p 14550:14550/udp mavlink-relay-server
      7. Wait 3s
      8. docker logs relay-test
      9. Assert: logs contain "Listening on"
      10. docker stop relay-test
    Expected Result: Container builds, runs, and serves
    Evidence: Docker build + logs captured
  ```

  **Commit**: YES
  - Message: `ops(server): add Dockerfile and docker-compose for deployment`
  - Files: `Dockerfile`, `docker-compose.yml`
  - Pre-commit: `docker build -t mavlink-relay-server .`

---

## Commit Strategy

| After Task | Message | Files | Verification |
|------------|---------|-------|--------------|
| 1 | `feat(server): scaffold Python relay server project with dependencies` | pyproject.toml, all scaffold files | `pip install -e .` |
| 2 | `feat(server): implement aioquic QUIC server core with TLS and protocol skeleton` | server.py, protocol.py, __main__.py | Server starts |
| 3 | `feat(server): add length-prefix frame encoder/decoder` | framing.py | Inline tests |
| 4 | `feat(server): add session registry with vehicle/GCS/subscription tracking` | registry.py | Inline tests |
| 5 | `feat(server): implement control protocol and MAVLink relay logic` | control.py, protocol.py, config.py | Integration test |
| 6 | `feat(server): add YAML configuration loader with token store` | config.py | Inline tests |
| 7 | `feat(server): add keepalive PING/PONG, disconnect handling, VEHICLE_OFFLINE` | protocol.py | Integration test |
| 8 | `test(server): add comprehensive pytest suite for relay server` | tests/*.py | `pytest -v` |
| 9 | `feat(server): add structured JSON monitoring and statistics logging` | stats.py, protocol.py | `pytest -v` |
| 10 | `ops(server): add Dockerfile and docker-compose for deployment` | Dockerfile, docker-compose.yml | `docker build` |

---

## Success Criteria

### Verification Commands
```bash
# Install and start
pip install -e ".[dev]"
cd certs && bash generate_certs.sh && cd ..
python -m mavlink_relay_server --config config.example.yaml --cert certs/cert.pem --key certs/key.pem
# Expected: "Listening on 0.0.0.0:14550"

# Run tests
pytest tests/ -v
# Expected: ≥20 tests passed, 0 failed

# Docker
docker build -t mavlink-relay-server .
docker run --rm -p 14550:14550/udp mavlink-relay-server
# Expected: Container starts and listens
```

### Final Checklist
- [ ] All "Must Have" features present and working
- [ ] All "Must NOT Have" items absent (no MAVLink parsing, no HTTP API, etc.)
- [ ] All pytest tests pass
- [ ] Server handles 10+ vehicle + 50+ GCS connections (validated by load test in pytest)
- [ ] Wire protocol matches Jetson plan exactly (u16_le framing, CBOR control, same ALPN)
- [ ] Docker container builds and runs
- [ ] Graceful shutdown on SIGINT/SIGTERM
