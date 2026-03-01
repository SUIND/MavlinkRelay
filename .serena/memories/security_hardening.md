# Security Hardening — MavlinkRelay Server

## Applied security measures (as of session where these were added)

### 1. Re-auth guard (`control.py` → `handle_auth`)
- `if protocol._authed: return False` at the top of `handle_auth`
- Prevents a connected client from re-authenticating as a different identity
- Logs a warning with the session_id

### 2. Auth fail reason sanitization (`control.py` → `_send_auth_fail`)
- Sends `{"type": "AUTH_FAIL", "reason": "auth failed"}` — plain opaque string
- Does NOT echo back which token was provided or why validation failed
- `quic.close(error_code=0x02, reason_phrase="auth failed")` — no sensitive data

### 3. Control payload size limit (`control.py` → `decode_control`)
- `_MAX_CONTROL_PAYLOAD = 65536` (64 KiB)
- Raises `ValueError` before calling `cbor2.loads()` if payload exceeds limit
- Prevents memory bomb via maliciously oversized CBOR

### 4. Frame buffer size limit (`framing.py` → `FrameDecoder.feed`)
- `_MAX_BUFFER_SIZE = 131072` (128 KiB)
- Raises `ValueError` if `len(self._buffer) + len(data) > _MAX_BUFFER_SIZE`
- Prevents unbounded buffer growth from malformed or adversarial streams

### 5. Constant-time token comparison (`config.py` → `TokenStore.validate`)
- Iterates all stored tokens using `hmac.compare_digest(stored_token, token_bytes)`
- Prevents timing-based token enumeration attacks

## What is NOT implemented (by design)
- No client TLS certificates required
- No MAVLink message parsing or validation (transparent relay)
- No token rotation API
- No persistent storage or database
- No HTTP/REST/WebSocket API — QUIC only
- No MAVLink routing by sysid/compid
- No QUIC datagram support — reliable streams only

## Auth timeout
- Server starts a timeout on QUIC handshake completion
- Default: 10s (config) / 30s (CLI `--auth-timeout` default)
- Connection is closed if AUTH not received in time
- Timeout handle stored in `protocol._auth_timeout_handle`, cancelled on successful auth

## Test coverage for security
File: `tests/test_security.py` (12 tests)
- Re-auth guard test
- Token constant-time comparison tests
- Payload size limit enforcement tests
- AUTH_FAIL reason opacity tests
