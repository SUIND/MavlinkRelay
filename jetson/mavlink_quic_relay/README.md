MAVLink QUIC Relay
==================

Lightweight ROS node that relays MAVLink frames over a QUIC/TLS connection (msquic). Bridges a local Flight Controller (via MAVROS) and a remote QUIC server: outbound MAVLink frames from ROS are classified and sent over QUIC streams; inbound frames from QUIC are published back to ROS.

Quick reference
---------------

| Property | Value |
|---|---:|
| Wire format | `[u16_le 2-byte length][raw MAVLink bytes]` |
| ALPN | `mavlink-quic-v1` |
| Default server port | `14550` |
| ROS topics | subscribe: `/mavlink/from` — publish: `/mavlink/to` |
| Target platform | NVIDIA Jetson Xavier NX / Orin Nano, ARM64, Ubuntu 18.04 / 20.04 |

Architecture
------------

Logical data flow:

```
FC/MAVROS ──[/mavlink/from]──► RosInterface ──► BoundedQueue ──► senderLoop
                                                                         │
                                                           PriorityClassifier
                                                          ┌──────┴──────┐
                                                    PRIORITY          BULK
                                                    Stream 4         Stream 8
                                                          └──────┬──────┘
                                                            QuicClient
                                                            (msquic)
                                                               │  QUIC/TLS
                                                            Server
                                                               │
                                    FC/MAVROS ◄──[/mavlink/to]──◄ RosInterface ◄── inbound queue ◄── QuicClient
```

Thread model

- ROS AsyncSpinner threads (2): subscriber callbacks + timer callbacks
- Sender thread: drains outbound queue, classifies frames, calls sendPriorityFrame()/sendBulkFrame()
- ReconnectManager thread: waits on condvar, triggers connect() after backoff
- msquic worker threads (internal): fire callbacks that post to event_queue_ only — never touch ROS
- ROS 1ms timer: processEvents() — the only place msquic events flow to ROS callbacks

Wire protocol
-------------

- Per-frame encoding on all streams: `[u16_le 2-byte little-endian length][payload bytes]`.
- ALPN: `"mavlink-quic-v1"`.

Authentication (Stream 0)

- Client → Server: CBOR map `{"type": "AUTH", "token": <bytes>, "role": "vehicle", "vehicle_id": <text>}` on Stream 0 (length-prefixed with `[u16_le]` like all frames).
- Server → Client success: CBOR map `{"type": "AUTH_OK"}`.
- Server → Client failure: CBOR map `{"type": "AUTH_FAIL", "reason": "..."}` — client applies a 60s reconnect penalty.
- After AUTH_OK the server sends keepalive `{"type": "PING", "ts": <unix_float>}` every 15s; client must reply `{"type": "PONG", "ts": <same_ts>}` on the control stream.

**Token encoding**: `auth_token` in `relay_params.yaml` must be the same base64 string that appears in the server YAML `auth.tokens[].token`. `sendAuth()` calls `base64Decode()` to convert the string to raw bytes before embedding them in the CBOR bstr — matching exactly what the server stores in `TokenStore` at startup.

Stream table
------------

| Stream ID | Name     | Direction     | Content                        |
|-----------:|----------|---------------|--------------------------------|
| 0         | Control  | Bidirectional | CBOR AUTH, keepalive           |
| 4         | Priority | Bidirectional | High-priority MAVLink frames   |
| 8         | Bulk     | Bidirectional | All other MAVLink telemetry    |

ROS topics
----------

| Topic           | Direction  | Type                    | Description                                              |
|-----------------|------------|-------------------------|----------------------------------------------------------|
| `/mavlink/from` | Subscribed | `mavros_msgs/Mavlink`   | MAVLink frames from FC/MAVROS → relay → server           |
| `/mavlink/to`   | Published  | `mavros_msgs/Mavlink`   | MAVLink frames from server → relay → FC/MAVROS           |

ROS parameters
--------------

The node reads configuration from ROS parameters. Defaults are shown; required parameters are noted.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `server_host` | string | `""` | QUIC server hostname/IP. **Required** — node exits with `ROS_FATAL` if empty |
| `server_port` | int | `14550` | QUIC server UDP port |
| `auth_token` | string | `"CHANGE_ME"` | Auth token. **Required** — node exits with `ROS_FATAL` if still `"CHANGE_ME"` or empty |
| `vehicle_id` | string | `BB_000001` | Vehicle ID in `BB_NNNNNN` format — matched against server `auth.tokens[].vehicle_id` |
| `ca_cert_path` | string | `""` | Path to CA cert PEM for TLS verification. Empty = use system trust store |
| `alpn` | string | `"mavlink-quic-v1"` | QUIC ALPN protocol identifier — must match server |
| `keepalive_interval_ms` | int | `15000` | QUIC PING interval (ms) — keeps NAT mappings alive |
| `idle_timeout_ms` | int | `60000` | QUIC idle timeout (ms) — connection dropped if no traffic |
| `mavlink_from_topic` | string | `"/mavlink/from"` | ROS topic to subscribe for outbound MAVLink |
| `mavlink_to_topic` | string | `"/mavlink/to"` | ROS topic to publish inbound MAVLink |
| `priority_queue_size` | int | `100` | Max frames in priority outbound queue; drop-oldest when full |
| `bulk_queue_size` | int | `500` | Max frames in bulk outbound queue; drop-oldest when full |
| `no_message_warn_timeout_s` | double | `10.0` | Log `ROS_WARN` if no `/mavlink/from` messages after N seconds |
| `drain_period_ms` | double | `1.0` | Inbound queue drain timer period (ms) |
| `inbound_queue_max` | int | `500` | Max inbound frames before drop-oldest |
| `outbound_queue_max` | int | `500` | (derived from `bulk_queue_size`) Max outbound queue depth |

Note: `priority_queue_size` and `bulk_queue_size` configure the unified `BoundedQueue` via `outbound_queue_max`; separate priority/bulk queues are reserved for future use.

Reconnect / backoff policy
--------------------------

- Backoff sequence (base, before jitter):
  - Attempt 0 → 1s
  - Attempt 1 → 2s
  - Attempt 2 → 4s
  - Attempt 3 → 8s
  - Attempt 4 → 16s
  - Attempt 5+ → 30s (cap)
- Add ±10% uniform jitter to each backoff interval.
- On authentication failure the node applies a 60s flat penalty before the next connect attempt and resets the attempt counter.

Priority MAVLink message IDs
----------------------------

The following message IDs (18 total) are classified as priority and routed to Stream 4. All other message IDs are routed to the bulk stream (Stream 8):

`0` (HEARTBEAT), `4` (PING), `20` (PARAM_REQUEST_READ), `22` (PARAM_VALUE), `23` (PARAM_SET), `39` (MISSION_ITEM), `40` (MISSION_REQUEST), `41` (MISSION_SET_CURRENT), `44` (MISSION_COUNT), `45` (MISSION_CLEAR_ALL), `47` (MISSION_ACK), `51` (MISSION_REQUEST_INT), `73` (MISSION_ITEM_INT), `75` (COMMAND_INT), `76` (COMMAND_LONG), `77` (COMMAND_ACK), `111` (TIMESYNC), `253` (STATUSTEXT)

msquic installation
-------------------

This project uses msquic as the QUIC/TLS implementation.

1. Clone msquic and fetch submodules:

```bash
git clone https://github.com/microsoft/msquic.git /opt/msquic-src
cd /opt/msquic-src
git submodule update --init --recursive
```

2. Build and install to `/usr/local`:

```bash
mkdir build && cd build
cmake .. -DQUIC_BUILD_TOOLS=off -DQUIC_BUILD_TEST=off -DQUIC_BUILD_PERF=off
cmake --build . --config Release -j$(nproc)
sudo cmake --install . --prefix /usr/local
```

This installs `libmsquic.so` to `/usr/local/lib` and headers to `/usr/local/include`, which the package's CMakeLists finds automatically — no `-DMSQUIC_ROOT` needed.

3. (Optional) If you installed msquic to a non-standard prefix, point the build at it:

```bash
catkin build mavlink_quic_relay --cmake-args -DMSQUIC_ROOT=/your/prefix
```

Building the ROS package
------------------------

This package is built inside a catkin workspace. Example steps from workspace root (`/home/kevin/workspace/MavlinkRelay`):

```bash
# Ensure catkin_tools is installed and workspace configured
catkin build mavlink_quic_relay

# With custom msquic installation
catkin build mavlink_quic_relay --cmake-args -DMSQUIC_ROOT=/opt/msquic
```

After a successful build source the devel/setup.bash in order to run the node or launch files:

```bash
source /home/kevin/workspace/MavlinkRelay/devel/setup.bash
```

Running
-------

Preferred: use roslaunch (loads config/relay_params.yaml automatically):

```bash
# Preferred: via launch file (loads config/relay_params.yaml automatically)
roslaunch mavlink_quic_relay relay.launch server_host:=1.2.3.4 auth_token:=MyToken

# Override individual params at launch time:
roslaunch mavlink_quic_relay relay.launch \
  server_host:=relay.example.com \
  server_port:=14550 \
  auth_token:=MySecretToken \
  vehicle_id:=BB_000001
```

Alternative: rosrun (requires params pre-loaded on param server):

```bash
source /home/kevin/workspace/MavlinkRelay/devel/setup.bash
rosrun mavlink_quic_relay mavlink_quic_relay_node
```

Tests
-----

Prerequisites:

```bash
pip install aioquic cryptography
```

Run tests from the workspace root:

```bash
catkin run_tests mavlink_quic_relay
```

Test suites

| Suite | File | What it tests |
|-------|------|---------------|
| `test_priority_classifier` | `test/test_priority_classifier.cpp` | 30 GTest cases: all 18 priority msgids, bulk fallback, edge cases, custom set |
| `test_thread_safe_queue` | `test/test_thread_safe_queue.cpp` | 12 GTest cases: FIFO order, drop-oldest overflow, concurrent push/pop |
| `test_mavlink_framing` | `test/test_mavlink_framing.cpp` | 13 GTest cases: wire format `[u16_le][payload]`, fragmentation, v1/v2 heartbeat roundtrips |
| `test_reconnect_manager` | `test/test_reconnect_manager.cpp` | 15 GTest cases: state machine transitions (no threads launched) |
| `test_ros_interface_framing` | `test/test_ros_interface_framing.cpp` | 18 GTest cases: `toRawBytes`/`fromRawBytes` v1/v2 roundtrips, LE encoding, edge cases |
| `test_relay_roundtrip` | `test/test_relay_roundtrip.py` + `mock_quic_server.py` | rostest: end-to-end HEARTBEAT + COMMAND_LONG echo via real QUIC connection |

Package structure
-----------------

```
mavlink_quic_relay/
├── CMakeLists.txt
├── package.xml
├── README.md
├── config/
│   └── relay_params.yaml         # ROS parameter defaults
├── include/
│   └── mavlink_quic_relay/
│       ├── priority_classifier.h
│       ├── quic_client.h
│       ├── reconnect_manager.h
│       ├── relay_node.h
│       └── ros_interface.h
├── launch/
│   └── relay.launch              # roslaunch entry point
├── src/
│   ├── main.cpp
│   ├── priority_classifier.cpp
│   ├── quic_client.cpp
│   ├── reconnect_manager.cpp
│   ├── relay_node.cpp
│   └── ros_interface.cpp
└── test/
    ├── mock_quic_server.py       # aioquic mock server (AUTH + MAVLink echo)
    ├── test_mavlink_framing.cpp
    ├── test_priority_classifier.cpp
    ├── test_reconnect_manager.cpp
    ├── test_relay_roundtrip.py   # rostest end-to-end script
    ├── test_relay_roundtrip.test
    ├── test_ros_interface_framing.cpp
    └── test_thread_safe_queue.cpp
```

Contact / support
-----------------

Report issues and feature requests in the repository's issue tracker. For build/runtime problems include:

- ROS distro and Ubuntu version
- msquic version and install path
- exact node invocation or launch arguments
- relevant log excerpts (use `ROS_LOG_LEVEL=DEBUG` if helpful)
