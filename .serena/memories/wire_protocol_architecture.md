# Wire Protocol and Architecture — MavlinkRelay Server

## QUIC connection parameters
- **ALPN**: `"mavlink-quic-v1"` (must match exactly)
- **Default UDP port**: `14550`
- **TLS**: Server uses self-signed EC cert (prime256v1). No client TLS cert required.
- Clients may optionally validate server cert via CA cert; can also skip validation.

## Stream IDs (client-initiated bidirectional QUIC streams)
| Stream ID | Name     | Content                        | Constant in control.py         |
|-----------|----------|--------------------------------|-------------------------------|
| 0         | Control  | CBOR messages (length-prefixed)| `_CONTROL_STREAM_ID = 0`      |
| 4         | Priority | Raw MAVLink frames             | `_PRIORITY_STREAM_ID = 4`     |
| 8         | Bulk     | Raw MAVLink frames             | `_BULK_STREAM_ID = 8`         |

Note: C++ client opens them as stream indices 0, 1, 2 which map to QUIC stream IDs 0, 4, 8.

## Wire framing (ALL streams)
```
[u16_le 2-byte little-endian length][raw payload bytes]
```
- Implemented in `framing.py`: `encode_frame(payload)` and `FrameDecoder`
- `_MAX_BUFFER_SIZE = 131072` (128 KiB) — FrameDecoder raises ValueError if exceeded
- Maximum frame payload: 65535 bytes (u16 max)

## Control stream encoding
- Payload is CBOR (cbor2) — a dict/map
- `_MAX_CONTROL_PAYLOAD = 65536` (64 KiB) — decode_control raises ValueError if exceeded
- Helper: `encode_control(msg: dict) -> bytes` returns length-prefixed CBOR
- Helper: `decode_control(data: bytes) -> dict` decodes raw CBOR payload (no length header)

## Auth flow (post-TLS handshake)
1. Server starts auth timeout (default 30s CLI / 10s config) on handshake complete
2. Client opens stream 0 and sends:
   `{"type": "AUTH", "token": <bytes>}` (CBOR, length-prefixed)
3. Server validates token via `TokenStore.validate()` (constant-time `hmac.compare_digest`)
4. **On success**: sends `{"type": "AUTH_OK"}`, cancels auth timeout, registers session, starts keepalive
5. **On failure**: sends `{"type": "AUTH_FAIL", "reason": "auth failed"}`, closes connection

## GCS SUBSCRIBE flow
- GCS clients send `{"type": "SUBSCRIBE", "vehicle_id": <int>}` after AUTH_OK
- Server replies `{"type": "SUB_OK", "vehicle_id": <int>}` or `{"type": "SUB_FAIL", ...}`

## Keepalive (after AUTH_OK)
- Server sends `{"type": "PING", "ts": <unix_float>}` every `keepalive_interval_s` (default 15s)
- Client must reply `{"type": "PONG", "ts": <same_ts>}` within `keepalive_timeout_s` (default 45s)
- Server closes connection if PONG not received in time

## Token format
- 16 raw bytes (128-bit opaque value)
- Stored in YAML as base64-encoded string (e.g. `"AAAAAAAAAAAAAAAAAAAAAA=="`)
- `TokenStore` decodes at startup with `base64.b64decode(token_b64)`
- Server expects AUTH to contain the **raw decoded bytes**, NOT the base64 string

## ⚠️ Known C++ client bug
`quic_client.cpp sendAuth()` sends ASCII bytes of the base64 string instead of base64-decoded raw bytes. Fix: base64-decode `config_.auth_token` before constructing `token_bytes` in the CBOR bstr. See `server/AUTHENTICATION.md`.

## Session registry
- `SessionRegistry`: tracks `VehicleSession` and `GCSSession` instances
- `VehicleSession`: holds protocol ref + stream IDs for a vehicle connection
- `GCSSession`: holds protocol ref + stream IDs + set of subscribed vehicle IDs
- GCS must SUBSCRIBE to a vehicle to receive its frames

## RelayProtocol state
Key instance attributes on `RelayProtocol`:
- `_authed: bool` — whether client has successfully authenticated
- `_role: str | None` — `"vehicle"` or `"gcs"` after auth
- `_session_id: str | None` — vehicle_id (as str) or gcs_id
- `_auth_timeout_handle` — asyncio handle, cancelled on successful auth
- `_decoders: dict[int, FrameDecoder]` — per-stream decoders
