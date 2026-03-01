# MavlinkRelay — Project Overview

## Structure

```
MavlinkRelay/
├── jetson/mavlink_quic_relay/   # C++ ROS1 node (msquic client)
└── server/mavlink_relay_server/ # Python aioquic server
```

## Purpose

Relays MAVLink frames between a vehicle (NVIDIA Jetson + MAVROS) and a GCS over QUIC/TLS.

- **Jetson** (C++/ROS1): msquic client. Reads from `/mavlink/from`, classifies frames, sends over QUIC; receives from QUIC, publishes to `/mavlink/to`.
- **Server** (Python/aioquic): relay hub. Accepts vehicle + GCS connections, authenticates, routes MAVLink frames between subscribed pairs.

---

## Wire Protocol

### Framing (all streams)
`[u16_le 2-byte length][raw payload]` — little-endian u16 prefix on every frame.

### Stream IDs (QUIC client-initiated bidirectional)
| Stream ID | Name     | Content                          |
|----------:|----------|----------------------------------|
| 0         | Control  | CBOR auth + keepalive messages   |
| 4         | Priority | High-priority MAVLink frames     |
| 8         | Bulk     | All other MAVLink telemetry      |

The C++ client opens streams in order (index 0→1→2); QUIC assigns IDs 0, 4, 8.

### Control messages (CBOR maps, length-prefixed)

| Direction      | Message                                                                              |
|----------------|--------------------------------------------------------------------------------------|
| Client→Server  | `{"type":"AUTH","token":<bstr>,"role":"vehicle","vehicle_id":<uint>}`               |
| Server→Client  | `{"type":"AUTH_OK"}`                                                                 |
| Server→Client  | `{"type":"AUTH_FAIL","reason":"..."}`                                                |
| Server→Client  | `{"type":"PING","ts":<float64>}` every 15s after auth                               |
| Client→Server  | `{"type":"PONG","ts":<same_float64>}` — must echo PING ts; server times out at 45s  |

---

## Jetson C++ Client Key Files

| File | Role |
|------|------|
| `src/quic_client.cpp` | msquic wrapper: connection, streams, frame encode/decode, control dispatch |
| `include/mavlink_quic_relay/quic_client.h` | QuicClient class, InternalEvent enum, StreamRecvState |
| `src/relay_node.cpp` | ROS node wiring: callbacks, sender thread, reconnect |
| `src/reconnect_manager.cpp` | Exponential backoff reconnect (1s→30s cap, 60s on AUTH_FAIL) |
| `src/priority_classifier.cpp` | 18 priority msgids → Stream 4; rest → Stream 8 |
| `src/ros_interface.cpp` | MAVROS topic subscribe/publish, frame serialization |

### Control frame dispatch (`handleControlFrame`)
Incoming control frames are CBOR-decoded using internal helpers (`cborGetStringField`, `cborGetFloat64Field`) and dispatched on the `"type"` field:
- `AUTH_OK` → set `auth_ok_`, open MAVLink streams, post `AUTH_OK` event
- `AUTH_FAIL` → log reason, post `AUTH_FAIL` event → triggers 60s reconnect penalty
- `PING` → immediately send back `{"type":"PONG","ts":<ts>}` (framed) on control stream
- Other → `ROS_DEBUG`

### InternalEvent types
`FRAME_RECEIVED`, `STATE_CHANGED`, `AUTH_OK`, `AUTH_FAIL`

---

## Server Python Key Files

| File | Role |
|------|------|
| `protocol.py` | `RelayProtocol` — per-connection state machine |
| `control.py` | `handle_auth`, `handle_subscribe`, `handle_ping`, `encode_control` |
| `framing.py` | `encode_frame`, `FrameDecoder` |
| `registry.py` | `SessionRegistry`, `VehicleSession`, `GCSSession` |
| `config.py` | `ServerConfig`, `TokenStore` |
| `stats.py` | `StatsCollector` |

---

## Token Encoding

The C++ `sendAuth()` calls `base64Decode(config_.auth_token)` to convert the
base64 config string to raw bytes before placing them in the CBOR `token` bstr.
The server YAML stores the same base64 string and decodes it via `base64.b64decode()`
at startup. Both sides now operate on identical raw bytes — `TokenStore.validate()` succeeds.

`auth_token` in `relay_params.yaml` must be the exact base64 string from the server YAML
`auth.tokens[].token`. If the value is not valid base64, `base64Decode()` returns an empty
vector and `sendAuth()` logs `ROS_ERROR` before proceeding (AUTH_FAIL will follow).

See `server/AUTHENTICATION.md` for full token format and security notes.

---

## Build

```bash
# catkin workspace at /home/kevin/workspace/MavlinkRelay
catkin build mavlink_quic_relay
# With custom msquic:
catkin build mavlink_quic_relay --cmake-args -DMSQUIC_ROOT=/opt/msquic
```

## Tests

```bash
# C++ (catkin)
catkin run_tests mavlink_quic_relay
# Python server
cd server && .venv/bin/pytest tests/ -v
```
