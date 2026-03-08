MAVLink QUIC Relay — secure, low-latency MAVLink telemetry relay over QUIC/TLS

## What it is

MavlinkRelay provides a transparent frame relay for MAVLink telemetry between vehicles (Jetson/ROS) and ground control stations (GCS) over QUIC/TLS. The server component is implemented in Python (aioquic) and the client runs as a C++ ROS node on Jetson platforms using msquic.

## Repository layout

```
MavlinkRelay/
├── server/          # Python aioquic relay server
└── jetson/
    └── mavlink_quic_relay/   # C++ ROS node (msquic)
```

See the sub-READMEs for detailed installation and configuration guidance.

## Architecture overview

The system relays MAVLink frames from a flight computer (via MAVROS) through a Jetson-hosted C++ ROS node over QUIC/TLS to a Python QUIC server which forwards frames to subscribed GCS clients. Each GCS connection may subscribe to exactly one vehicle at a time.

ASCII diagram:

```
FC / MAVROS  →  [Jetson C++ ROS node]  →  QUIC/TLS  →  [Python Server]
                                     ← QUIC/TLS ←
                                         [GCS]
```

## Key facts

| Property | Value |
|---|---|
| ALPN | `mavlink-quic-v1` |
| Default port | UDP 14550 |
| Wire framing | `[u16_le length][raw bytes]` on all streams |
| Streams | control=0, priority=4, bulk=8 |
| Auth | Post-handshake token exchange (CBOR on stream 0), no client TLS certs required |
| Vehicle ID | String in `BB_NNNNNN` format (e.g. `BB_000001`) |
| GCS ID | String in `GCS_NNNNNN` format (e.g. `GCS_000001`) — each GCS token is authorized for exactly one matching vehicle |
| GCS subscription | One vehicle per GCS connection; unauthorized or duplicate subscribes rejected with `SUB_FAIL` |
| Configuration | SQLite database (stdlib `sqlite3`); swappable `ConfigBackend` protocol; managed with `manage.py` |
| Server language | Python 3.12+, aioquic 1.3.0 |
| Client language | C++ (ROS 1, msquic) |

Additional notes:
- Keepalive: server PINGs every 15s and will close the connection after 45s without a PONG.
- The server includes a comprehensive test suite and a Docker Compose setup for easier deployment and security hardening.

## Links to sub-components

- [Server README](server/README.md)
- [Jetson client README](jetson/mavlink_quic_relay/README.md)
- [Authentication guide](server/AUTHENTICATION.md)

## Quick start

To run the server, see `server/README.md` for installation, configuration, and examples.

To build and run the ROS node for Jetson, see `jetson/mavlink_quic_relay/README.md` for build instructions and platform notes (Jetson Xavier NX / Orin Nano, ARM64).

---

This README is a high-level overview. For configuration specifics, logging, parameter details, and advanced usage consult the component READMEs linked above.
