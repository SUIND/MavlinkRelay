Overview
========

This document describes authentication for the MAVLink QUIC relay server.
Authentication is performed after the QUIC/TLS handshake using a small
post-handshake token exchange over the encrypted control stream. No
SSL/TLS client certificate is required.

Full Authentication Flow
========================

1. TLS handshake
   - Client connects to the server using QUIC (ALPN "mavlink-quic-v1").
   - The server presents its certificate (the server typically uses a
     self-signed EC certificate, prime256v1).
   - The client may optionally validate the server certificate using a
     CA certificate configured via ca_cert_path. If no CA is provided,
     server certificate validation may be skipped (common in trusted
     networks).

2. Auth timeout starts
   - When the TLS handshake completes the server starts an auth timeout
     (default: 10 seconds, configurable as auth_timeout_s). The client
     must authenticate before this timeout expires.

3. Client sends AUTH on control stream
   - Client opens the control stream (QUIC stream 0) and sends a CBOR
     map with four fields:

        {
          "type":       "AUTH",          // tstr — required; dispatches server handler
          "token":      <bytes>,         // bstr — raw token bytes (see Token format below)
          "role":       "vehicle",       // tstr — always "vehicle" for the C++ client
          "vehicle_id": <tstr>           // tstr — vehicle identifier (CBOR text string) in BB_NNNNNN format
        }

     The control stream uses length-prefixed framing: every frame is
     encoded as [u16_le length][raw bytes]. The CBOR payload is the
     frame payload (no extra envelope).

   - The "token" field is a CBOR byte string (bstr). The Python server
     expects the raw decoded bytes (see Token format below).

4. Server validates token
   - The Python server loads tokens from the YAML config (auth.tokens)
     where tokens are stored as base64-encoded strings.
   - On startup the server decodes each token entry with
     base64.b64decode(token_b64) and stores the resulting raw bytes in
     memory (TokenStore).
   - When an AUTH message arrives the server extracts the token bytes
     from the CBOR message and looks them up in the TokenStore via a
     direct bytes lookup (constant-time comparison via storage +
     hmac.compare_digest semantics implicitly through the bytes mapping).

5. On failure
   - If validation fails the server sends back on the control stream
     {"type": "AUTH_FAIL", "reason": "..."} (CBOR, length-prefixed)
     and schedules a connection close (gives the client a chance to
     read the message).

6. On success
   - The server sends {"type": "AUTH_OK"} on the control stream,
     cancels the auth timeout, registers the session (vehicle or GCS)
     and starts the keepalive loop.

7. Post-auth
   - Authenticated clients may send SUBSCRIBE (GCS) or begin sending
     MAVLink frames on the priority (stream 4) and bulk (stream 8)
     channels.

Do clients need SSL client certificates?
=======================================

Short answer: NO. The server does not require client TLS certificates.

- The Python server presents an EC certificate (prime256v1). It does
  not request or require client certificates.
- The Jetson C++ client configures msquic with QUIC_CREDENTIAL_TYPE_NONE
  and QUIC_CREDENTIAL_FLAG_CLIENT — i.e. no client cert is supplied.
- Clients may optionally validate the server certificate by supplying
  ca_cert_path in relay_params.yaml. If provided, msquic will load that
  certificate file and validate the server certificate chain against it.
- Authentication (vehicle/GCS identity) is provided exclusively by the
  post-handshake token exchange over the encrypted QUIC channel.

Token format and storage
========================

- Tokens are 128-bit values (16 raw bytes).
- In the server YAML (auth.tokens[].token) the token is stored as a
  base64-encoded string. Example (in config.example.yaml):

  - token: "AAAAAAAAAAAAAAAAAAAAAA=="
    role: "vehicle"
    vehicle_id: "BB_000001"

- On startup the server decodes each token using base64.b64decode and
  stores the raw bytes as the lookup key in TokenStore._lookup.

Generating a token
------------------

Use this command to generate a new token and print its base64 form:

```bash
python3 -c "import os, base64; print(base64.b64encode(os.urandom(16)).decode())"
```

Store the printed string in the server YAML under auth.tokens[].token and
  put the same base64 string into the client's relay_params.yaml auth_token
  field (both sides decode the base64 string identically).

Token Encoding (C++ client)
============================

The C++ client `sendAuth()` in `quic_client.cpp` calls `base64Decode()` on
`config_.auth_token` before embedding the result as the CBOR `token` bstr:

  const std::vector<uint8_t> token_bytes = base64Decode(config_.auth_token);

This means both sides operate on the same 16 raw bytes:
- The server YAML stores the token as base64 (`auth.tokens[].token`).
- On startup the server decodes it with `base64.b64decode()`.
- The C++ client reads the same base64 string from `relay_params.yaml`
  (`auth_token`) and decodes it with the inline `base64Decode()` helper.
- Both produce identical raw bytes → `TokenStore.validate()` succeeds.

If `auth_token` is not valid base64, `base64Decode()` returns an empty
vector and `sendAuth()` logs a `ROS_ERROR` before proceeding. The server
will then reject the AUTH with `AUTH_FAIL`.

Token security considerations

============================

- Use distinct tokens per device: issue one token per vehicle and one
  per GCS. Do not reuse tokens between roles.
- Tokens are compared using constant-time techniques (server stores
  bytes and uses a direct lookup) to reduce timing-attack exposure.
- Distribute tokens out-of-band over secure channels (not over the
  relay itself). Treat tokens like passwords.
- Rotate tokens by updating both server and client configs and
  restarting the processes. There is no dynamic token revocation API
  in the current design.

Keepalive after authentication
==============================

- After successful AUTH the server starts a keepalive loop:
  - Sends {"type": "PING", "ts": <unix_float>} every
    keepalive_interval_s (default 15s).
  - Client must respond with {"type": "PONG", "ts": <same_ts>}.
- If the server doesn't receive a PONG within keepalive_timeout_s
  (default 45s) it closes the connection.

GCS subscription rules
======================

- A single GCS connection may subscribe to exactly one vehicle at a time.
- After authentication a GCS may send SUBSCRIBE requests on the control
  stream to request forwarding for a particular vehicle_id (CBOR text
  string in BB_NNNNNN format).
- Server behavior on SUBSCRIBE:
  - If the requested vehicle is connected the server registers the
    subscription and replies with {"type": "SUB_OK", "vehicle_id": ...}.
  - If the requested vehicle is not connected the server replies with
    {"type": "SUB_FAIL", "vehicle_id": ..., "reason": "vehicle not connected"}.
  - If the GCS connection already has an active subscription the server
    hard-rejects subsequent SUBSCRIBE requests with
    {"type": "SUB_FAIL", "vehicle_id": ..., "reason": "already subscribed"}.
    To subscribe to a different vehicle the GCS must close and reopen the
    connection (i.e. reconnect) and perform AUTH/SUBSCRIBE on the new
    connection.

Quick reference — Auth troubleshooting
=====================================

Symptom: AUTH_FAIL immediately
Likely cause: Wrong token value — the base64 string in relay_params.yaml
does not match any entry in the server YAML auth.tokens list.
Fix: Copy the exact base64 token string from the server config into
relay_params.yaml auth_token (both sides decode it identically).

Symptom: Connection closed after ~10s
Likely cause: Client never sent AUTH within auth_timeout_s.
Fix: Ensure client opens control stream 0 and sends AUTH promptly after
handshake.

Symptom: TLS handshake fails
Likely cause: Cert paths incorrect or CA not provided.
Fix: Check server cert/key paths on server and ca_cert_path on client
if you want verification. For testing on trusted networks you may skip
verification.

Symptom: Connection dropped every ~45s
Likely cause: Client not responding to PINGs.
Fix: Ensure the client decodes incoming control frames, detects
{"type": "PING"}, and replies with {"type": "PONG", "ts": <same_ts>}
on the control stream. The C++ client handles this in handleControlFrame().

Symptom: SUB_FAIL "already subscribed"
Likely cause: GCS attempted to subscribe again on the same connection
            (one-vehicle-per-connection enforcement).
Fix: Reconnect the GCS and perform AUTH then SUBSCRIBE for the desired
     vehicle on the new connection.

Appendix: Wire framing and encodings (implementation notes)
=========================================================

- ALPN: "mavlink-quic-v1" (client and server must match).
- Streams: control=0, priority=4, bulk=8 (QUIC client-initiated
  bidirectional stream numbering used by the Python server). The C++
  client opens control stream index 0, then priority (1) and bulk
  (2) after AUTH_OK; the Python server maps those to QUIC stream IDs
  4 and 8 respectively.
- Framing: All streams use a 2-byte little-endian u16 length prefix
  followed by the raw payload. The client SendBuffer constructs this
  prefix in quic_client.cpp and the server FrameDecoder expects it.
- Control encoding: CBOR (cbor2 on Python side). Control messages are
  CBOR maps carried as the frame payload.
