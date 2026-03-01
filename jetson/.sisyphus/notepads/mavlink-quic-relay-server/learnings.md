# Learnings — mavlink-quic-relay-server

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
- Package at: `mavlink_relay_server/` (inside workspace root)
- Tests at: `tests/`
