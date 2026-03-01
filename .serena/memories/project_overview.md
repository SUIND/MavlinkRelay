# MavlinkRelay — Project Overview

## Purpose
Transparent MAVLink frame relay over QUIC/TLS. Two components:
- **`server/`** — Python aioquic relay server (this project's primary focus)
- **`jetson/mavlink_quic_relay/`** — C++ ROS 1 node (msquic) running on NVIDIA Jetson

The server is a dumb relay: it does NOT parse MAVLink messages, does NOT route by sysid/compid, and does NOT store frames. It classifies connections as vehicles or GCS via token auth, then forwards frames between them on separate priority/bulk streams.

## Tech Stack (server)
- **Python 3.12+** (bytecache shows cpython-314 = 3.14 dev, but requires-python = >=3.10)
- **aioquic 1.3.0** — QUIC/TLS transport
- **cbor2** — CBOR encoding for control messages
- **PyYAML** — config loading
- **pytest + pytest-asyncio** — testing (`asyncio_mode = "auto"` in pyproject.toml)
- **hatchling** — build backend, entry point `mavlink-relay-server`
- **mypy** — static type checking (optional)

## Repository layout
```
MavlinkRelay/
├── README.md
├── server/
│   ├── pyproject.toml
│   ├── config.example.yaml
│   ├── Dockerfile
│   ├── docker-compose.yml            # production
│   ├── docker-compose.test.yml       # integration tests
│   ├── AUTHENTICATION.md
│   ├── README.md
│   ├── certs/
│   │   ├── cert.pem / key.pem
│   │   └── generate_certs.sh
│   ├── mavlink_relay_server/
│   │   ├── __main__.py    # CLI + entry point
│   │   ├── server.py      # run_server(), QuicConfiguration, signal handlers
│   │   ├── protocol.py    # RelayProtocol (per-connection state machine)
│   │   ├── registry.py    # SessionRegistry, VehicleSession, GCSSession
│   │   ├── framing.py     # encode_frame(), FrameDecoder
│   │   ├── control.py     # encode_control, decode_control, handle_auth
│   │   ├── config.py      # ServerConfig, TokenStore, load_config
│   │   └── stats.py       # StatsCollector, ConnectionStats, ServerStats
│   └── tests/
│       ├── conftest.py
│       ├── test_framing.py
│       ├── test_framing_extended.py
│       ├── test_registry.py
│       ├── test_config.py
│       ├── test_control.py
│       ├── test_security.py
│       ├── test_protocol_logic.py
│       ├── test_stats.py
│       └── integration/
│           ├── config.test.yaml
│           ├── test_client.py        # aioquic VehicleClient + GCSClient
│           └── Dockerfile.test
└── jetson/mavlink_quic_relay/        # C++ ROS 1 node (separate component)
```
