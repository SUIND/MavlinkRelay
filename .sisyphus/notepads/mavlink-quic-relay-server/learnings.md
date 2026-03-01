# Learnings — mavlink-quic-relay-server

## [2026-03-01] Docker Test Environment
- docker-compose.test.yml: relay + test-client services on relay-test-net bridge network
- test_client.py: aioquic VehicleClient + GCSClient, connects to relay:14550, auths, subscribes, sends frames, verifies relay
- Dockerfile.test: python:3.12-slim, installs aioquic + cbor2, runs test_client.py
- config.test.yaml: debug logging, vehicle token=b"\x00"*16, GCS token=b"\xbb"*16
- Run integration test: docker compose -f server/docker-compose.test.yml up --exit-code-from test-client
- Gotcha: aioquic `connect()` returns `QuicConnectionProtocol` (base type); use `typing.cast(VehicleClient, proto)` to access subclass attributes without LSP errors
- Gotcha: import `connect` from `aioquic.asyncio.client` (not `aioquic.asyncio`) per current aioquic module structure
- Gotcha: `version` key in docker-compose is obsolete in modern Docker Compose; omit it to avoid warnings

## [2026-03-01] Expanded Test Suite
- test_security.py: re-auth attack, CBOR bomb, buffer overflow, auth fail reason phrase, constant-time token comparison
- test_protocol_logic.py: full auth+subscribe flow, encode/decode all message types, edge cases
- test_stats.py: all StatsCollector methods including log format
- test_framing_extended.py: max-size frames, single-byte feeds, stress test, buffer overflow
- Total tests now: 77 (was 35)
- Gotcha: FrameDecoder overflow tests must use valid frame headers (non-zero length field) not raw zero bytes — `\x00\x00` prefix is a zero-length frame, triggering a different ValueError before the buffer-size check
- Gotcha: `handle_auth` failure path calls `asyncio.get_event_loop()` (via `_send_auth_fail`), so tests exercising the failure path must be `async def` even if the assertion is synchronous
- Gotcha: `cbor2.loads(b"\xff\xff\xff")` returns `break_marker` (no error); use `b"\x1e"` to trigger `CBORDecodeError`

## [2026-03-01] Security Hardening
- control.py: re-auth guard added to handle_auth (before token lookup)
- control.py: _send_auth_fail now passes reason_phrase="auth failed" (no info leak; aioquic 1.3.0 takes str, not bytes — it calls .encode("utf8") internally)
- control.py: decode_control now enforces _MAX_CONTROL_PAYLOAD = 65536 bytes max
- framing.py: FrameDecoder.feed now enforces _MAX_BUFFER_SIZE = 131072 bytes max
- config.py: TokenStore.validate now uses hmac.compare_digest for constant-time comparison
- protocol.py: _relay_frames int() conversion already had try/except — confirmed, no change needed

## [2026-03-01] Task 10: Docker + --dry-run
- **Dockerfile finalized**: python:3.12-slim base, WORKDIR /app, copies pyproject.toml + source (layer caching), pip install --no-cache-dir, EXPOSE 14550/udp, CMD ["mavlink-relay-server", "--config", "/config/config.yaml"]
- **docker-compose.yml finalized**: service name `relay`, build context `.`, image `mavlink-relay-server:latest`, ports `14550:14550/udp`, volumes mount certs (ro) and `config.example.yaml → /config/config.yaml` (ro), restart: unless-stopped, LOG_LEVEL=INFO
- **--dry-run flag added**: argparse store_true, placed before asyncio.run(); calls `print(f"Config OK: host={...} port={...} tokens={...}")` and sys.exit(0). Smoke test: `--help` shows flag, and `python3 -m mavlink_relay_server --dry-run` invocation would print config and exit cleanly (before cert validation)
- **Validation**: Dockerfile syntax verified (FROM, COPY, RUN, EXPOSE, CMD structure correct); docker-compose.yml syntax verified (service `relay` with build, image, ports, volumes, restart keys correct); __main__.py syntax validated and --dry-run logic integrated after config build but before event loop start

## [2026-02-28] Session ses_35aa44d0fffe49ZZzIKobtzJqD — Plan Start

### Architecture Summary
- Python 3.10+ asyncio relay server using aioquic
- ALPN: `"mavlink-quic-v1"`, UDP port 14550
- Control stream: stream ID 0 (CBOR encoded)
- Priority stream: stream ID 4
- Bulk stream: stream ID 8
- Wire framing: `[u16_le length][raw MAVLink bytes]` — little-endian

### Key Design Decisions
- Many-to-many subscriptions: multiple GCS per vehicle, one vehicle per GCS at a time
- Token storage: YAML config file (static, no rotation)
- Per-vehicle asyncio.Lock for serialized GCS→vehicle writes
- Backpressure: drop-oldest on bulk relay queues (asyncio.Queue with maxsize)
- Keepalive: server sends PING every 15s, closes connection after 45s no PONG
- Auth timeout: 10s from handshake completion
- VEHICLE_OFFLINE sent to subscribed GCS when vehicle disconnects

### Dependencies
- aioquic>=1.0.0, cbor2>=5.6.0, pyyaml>=6.0
- Dev: pytest, pytest-asyncio, mypy

### Project Root
- All server code lives at: `/home/kevin/workspace/MavlinkRelay/server/`
- Package at: `server/mavlink_relay_server/`
- Tests at: `server/tests/`
- Venv at: `server/.venv/`
- Pattern mirrors `jetson/` directory structure

### Wave 2 — COMPLETE
- Task 2 (server core): `server.py` and `protocol.py` fully implemented. `run_server()` creates QuicConfiguration with ALPN "mavlink-quic-v1", loads cert chain, creates RelayProtocol factory with registry injection. Signal handlers use asyncio.Event for clean shutdown. Auth timeout uses `loop.call_later()`.
- Task 4 (registry): `registry.py` fully implemented. VehicleSession and GCSSession dataclasses with `field(default_factory=asyncio.Lock)` for write_lock. All CRUD operations lock-protected. Circular import avoided via TYPE_CHECKING guard.
- Task 6 (config): `config.py` fully implemented. `load_config()` parses YAML with yaml.safe_load, applies CLI overrides. TokenStore uses `dict[bytes, TokenConfig]` lookup. YAML token key is `"token"` (not `"token_b64"`).
- `__main__.py` updated: uses `_build_config(args)` helper, calls `asyncio.run(run_server(config))`, handles KeyboardInterrupt. Has `--auth-timeout` CLI flag (float, default 30.0).

### Wave 1 — COMPLETE
- Task 1 (scaffold): All skeleton files created, `pip install -e .` works, entry point verified
- Task 3 (framing): `framing.py` fully implemented — encode_frame, FrameDecoder, all edge cases pass
- framing.py uses `List[bytes]` from typing for Python 3.10 compat (not `list[bytes]` builtin generic)

## [2026-02-28] Task 8: pytest suite
- Added `asyncio_mode = "auto"` under `[tool.pytest.ini_options]` in `server/pyproject.toml` to simplify async tests.
- Wrote isolated unit tests only (no aioquic integration): framing (encode/decode), config loading + token validation, registry subscription semantics, and control handlers.
- For `handle_auth` / `handle_subscribe`, tests run under pytest-asyncio and `await asyncio.sleep(0)` is enough to let `asyncio.ensure_future(...)` scheduled registry coroutines execute.
- Protocol objects are `MagicMock(spec=RelayProtocol)` with required internal attributes stubbed; control payload assertions decode the length-prefixed CBOR sent via `_send_control`.
