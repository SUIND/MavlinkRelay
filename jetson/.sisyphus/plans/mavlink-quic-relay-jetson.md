# MAVLink QUIC Relay System — Jetson Vehicle Node Implementation Plan

## TL;DR

> **Quick Summary**: Build a C++ ROS 1 Noetic node on NVIDIA Jetson that subscribes to MAVLink messages (via `mavros_msgs/Mavlink`), classifies them by priority, and relays them bidirectionally over QUIC (using msquic) to a Python aioquic relay server — replacing the original ESP32 vehicle-side component.
>
> **Deliverables**:
> - `mavlink_quic_relay` ROS package (catkin) with C++ node
> - msquic QUIC client with 3 multiplexed streams (control, priority, bulk)
> - Bidirectional relay: FC→Server telemetry + Server→FC commands
> - Priority classification by MAVLink msgid
> - Authentication, keepalive, and reconnection with exponential backoff
> - Launch file and configuration via ROS params
> - GTest unit tests + rostest integration tests
>
> **Estimated Effort**: Large
> **Parallel Execution**: YES — 3 waves
> **Critical Path**: Task 1 (scaffold) → Task 2 (QUIC client) → Task 3 (ROS integration) → Task 5 (bidirectional relay) → Task 7 (tests)

---

## Context

### Original Request
Update the vehicle-side component of a MAVLink QUIC relay system. The original plan used an ESP32 microcontroller with UART to a flight controller over cellular. The new design replaces the ESP32 with an NVIDIA Jetson running a C++ ROS 1 Noetic node.

### Interview Summary
**Key Discussions**:
- **Platform**: Jetson Xavier NX (now) → Orin Nano (later), both custom JetPack based on Ubuntu 20.04 (also must support 18.04). ROS 1 Noetic.
- **FC connection**: A separate custom ROS node handles UART to flight controller. OUT OF SCOPE for this plan.
- **Passthrough message**: Use `mavros_msgs/Mavlink.msg` which provides `sysid`, `compid`, `msgid`, and `payload64[]` fields — relay classifies by `msgid` without re-parsing raw bytes.
- **QUIC library**: msquic (Microsoft) — Tier-1 ARM64, CMake native, clean async API, built-in certificate pinning.
- **Bidirectional**: YES — FC→Server (telemetry uplink) AND Server→FC (GCS commands downlink).
- **Build system**: `catkin build` (catkin_tools).
- **Internet**: 4G/LTE USB modem managed by Linux NetworkManager.
- **Test strategy**: Tests after implementation (GTest + rostest), no TDD.
- **Scope**: ONLY the QUIC relay ROS node. Not the FC node, not the server, not the GCS.

### Research Findings
- **msquic** has Tier-1 ARM64 support, CMake build system compatible with catkin, and clean async callback-based API with built-in event loop (epoll on Linux).
- **AQUILA paper** (Dec 2024) validates MAVLink-over-QUIC architecture on ARM64 SBCs with priority scheduling.
- **No existing ROS1/ROS2 QUIC packages** — this is novel integration.
- **mavros_msgs** is available via `apt` for ROS Noetic on ARM64 (`ros-noetic-mavros-msgs`).

### Metis Review
**Identified Gaps** (all addressed):
- **msquic threading model**: Callbacks fire on msquic worker threads, NOT ROS threads. Must use thread-safe queue for cross-thread data. Applied: all publish/subscribe via lock-free queue.
- **Buffer ownership**: `StreamSend` buffers are owned by msquic until `SEND_COMPLETE` event. Applied: RAII buffer lifecycle in plan.
- **ALPN negotiation**: msquic requires ALPN string matching between client and server. Applied: defined as `"mavlink-quic-v1"`.
- **NAT keepalive**: Cellular NAT tables timeout UDP after 30-60s. Applied: keepalive at 15s.
- **PeerBidiStreamCount**: Must be set > 0 for server-initiated streams. Applied: set to 1 for server commands.
- **JetPack/Ubuntu version**: Verified — custom JetPack on Ubuntu 20.04 (also 18.04 compatible).
- **ROS publisher thread safety**: `ros::Publisher::publish()` is NOT guaranteed thread-safe. Applied: queue + publish from ROS spin thread only.
- **Stream model**: 3 persistent long-lived streams with `[u16_le length][payload]` framing (from original wire protocol design).
- **Shutdown sequence**: Must call `ConnectionShutdown()` before `MsQuicClose()`, drain queues, handle `ros::ok()` becoming false during msquic callbacks.

---

## System Architecture (Updated)

```
┌──────────────────────────────────────────────────────────┐
│ NVIDIA Jetson (Xavier NX / Orin Nano)                    │
│                                                          │
│  ┌─────────────────────┐    ┌──────────────────────────┐ │
│  │ FC ROS Node          │    │ mavlink_quic_relay Node  │ │
│  │ (OUT OF SCOPE)       │    │ (THIS PLAN)             │ │
│  │                      │    │                          │ │
│  │ UART ↔ ArduPilot FC  │    │ ┌──────────────────┐    │ │
│  │                      │    │ │ ROS Subscriber    │    │ │
│  │ Publishes:           │───►│ │ /mavlink/from     │    │ │
│  │ /mavlink/from        │    │ │ mavros_msgs/Mavlink│   │ │
│  │ (mavros_msgs/Mavlink)│    │ └────────┬─────────┘    │ │
│  │                      │    │          │ classify      │ │
│  │ Subscribes:          │◄───│ │        ▼ by msgid     │ │
│  │ /mavlink/to          │    │ ┌────────┴─────────┐    │ │
│  │ (mavros_msgs/Mavlink)│    │ │ Priority Router   │    │ │
│  │                      │    │ │ Prio Q │ Bulk Q   │    │ │
│  └─────────────────────┘    │ └───┬────┴────┬─────┘    │ │
│                              │     │         │          │ │
│                              │     ▼         ▼          │ │
│                              │ ┌────────────────────┐   │ │
│                              │ │ msquic QUIC Client  │   │ │
│                              │ │ Stream 0: Control   │   │ │
│                              │ │ Stream 4: Priority  │   │ │
│                              │ │ Stream 8: Bulk      │   │ │
│                              │ └─────────┬──────────┘   │ │
│                              └───────────┼──────────────┘ │
│                                          │                │
│                    ┌─────────────────────┘                │
│                    │ 4G/LTE USB Modem                     │
│                    │ (Linux NetworkManager)               │
└────────────────────┼─────────────────────────────────────┘
                     │ QUIC/TLS 1.3 (UDP)
                     ▼
            ┌────────────────────┐
            │ Python aioquic     │
            │ Relay Server       │
            │ (UNCHANGED)        │
            └────────────────────┘
```

### Data Flow: 3 QUIC Streams (Unchanged from Original)

| Stream ID | Purpose | Direction | Reliability | Drop Policy |
|-----------|---------|-----------|-------------|-------------|
| 0 | Control (AUTH, PING/PONG) | Bidirectional | Reliable | Never drop |
| 4 | MAVLink Priority (commands, missions, params, heartbeat) | Bidirectional | Reliable | Never drop |
| 8 | MAVLink Bulk (attitude, IMU, GPS, telemetry) | Bidirectional | Reliable | App-layer drop-old |

### Wire Protocol (Per Stream — Unchanged)

```
[u16_le length] [length bytes of raw MAVLink packet]
[u16_le length] [length bytes of raw MAVLink packet]
...
```

Overhead: 2 bytes per frame. Control stream uses CBOR-encoded messages (AUTH, PING, PONG).

---

## Work Objectives

### Core Objective
Build a production-ready C++ ROS 1 Noetic node (`mavlink_quic_relay`) that acts as a transparent, priority-aware, bidirectional MAVLink relay between a ROS topic and a remote QUIC server.

### Concrete Deliverables
- `mavlink_quic_relay` catkin package with:
  - `mavlink_quic_relay_node` executable
  - `relay.launch` launch file
  - `config/relay_params.yaml` configuration
  - GTest unit tests
  - rostest integration tests
- Documentation in package README

### Definition of Done
- [ ] `catkin build mavlink_quic_relay` succeeds with zero errors and zero warnings (`-Wall -Werror`)
- [ ] Node starts via `roslaunch mavlink_quic_relay relay.launch` and advertises `/mavlink/from` subscriber and `/mavlink/to` publisher
- [ ] MAVLink messages published to `/mavlink/from` are received by a mock aioquic server within 500ms
- [ ] Commands sent from mock server are published to `/mavlink/to` within 500ms
- [ ] Priority classification routes HEARTBEAT/COMMAND_LONG to priority stream, ATTITUDE/GPS to bulk stream
- [ ] Node reconnects after server disconnect within configured backoff max
- [ ] Node exits cleanly on `rosnode kill` with no zombie threads
- [ ] All GTest and rostest tests pass

### Must Have
- msquic QUIC client with TLS 1.3
- 3 persistent QUIC streams (control, priority, bulk)
- MAVLink priority classification by msgid
- Bidirectional relay (FC→Server AND Server→FC)
- Token-based authentication on control stream
- Keepalive PING every 15 seconds
- Exponential backoff reconnection (1s, 2s, 5s, 10s, 20s, 30s max + ±10% jitter)
- Thread-safe queue between msquic callbacks and ROS publisher
- Proper msquic buffer lifecycle (RAII, respect SEND_COMPLETE)
- Graceful shutdown sequence
- ROS param configuration (server host/port, token, vehicle_id, queue sizes)
- Launch file
- Compatibility with Ubuntu 18.04 and 20.04, ARM64

### Must NOT Have (Guardrails)
- **NO** TLS certificate generation or provisioning scripts — cert paths are ROS params only
- **NO** FC node implementation or mocking — relay assumes `/mavlink/from` topic exists
- **NO** Python server implementation — that's a separate component
- **NO** MAVROS dependency — only `mavros_msgs` for the message type
- **NO** QUIC datagrams — reliable streams only (datagrams are for video, not C2)
- **NO** app-level message retry — QUIC reliable transport handles this
- **NO** MAVLink raw parsing or checksum validation — use `msgid` field from `mavros_msgs/Mavlink` directly
- **NO** ROS services or dynamic_reconfigure — all config at launch time
- **NO** statistics/monitoring ROS topics — use ROS logging only
- **NO** multi-server connection support — single server only
- **NO** blocking operations inside msquic callbacks
- **NO** direct `ros::Publisher::publish()` from msquic callback threads

---

## Verification Strategy

> **UNIVERSAL RULE: ZERO HUMAN INTERVENTION**
>
> ALL tasks are verifiable WITHOUT any human action.

### Test Decision
- **Infrastructure exists**: NO (new package)
- **Automated tests**: YES (tests after implementation)
- **Framework**: GTest (unit) + rostest (integration)

### Agent-Executed QA Scenarios (MANDATORY — ALL tasks)

Every task includes specific agent-executable QA scenarios using Bash (compilation checks, roslaunch, rostopic, rostest).

**Verification Tool by Deliverable Type:**

| Type | Tool | How Agent Verifies |
|------|------|-------------------|
| Build/Compile | Bash (catkin build) | Build succeeds, zero warnings |
| ROS Node | Bash (roslaunch + rostopic) | Node starts, topics advertised |
| QUIC Connection | Bash (mock server + node) | Frames arrive at mock server |
| Unit Tests | Bash (catkin run_tests) | All GTest assertions pass |
| Integration Tests | Bash (rostest) | All rostest assertions pass |

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately):
├── Task 1: Scaffold catkin package + build system
└── Task 4: Priority classification module (standalone, no deps)

Wave 2 (After Wave 1):
├── Task 2: msquic QUIC client wrapper (depends: Task 1 scaffold)
├── Task 3: ROS subscriber/publisher + thread-safe queue (depends: Task 1 scaffold)
└── Task 6: Launch file + configuration (depends: Task 1 scaffold)

Wave 3 (After Wave 2):
├── Task 5: Full bidirectional relay integration (depends: Tasks 2, 3, 4)
└── Task 7: Tests — GTest + rostest (depends: Task 5)

Wave 4 (After Wave 3):
└── Task 8: Reconnection, backoff, and graceful shutdown (depends: Task 5)

Critical Path: Task 1 → Task 2 → Task 5 → Task 7
```

### Dependency Matrix

| Task | Depends On | Blocks | Can Parallelize With |
|------|------------|--------|---------------------|
| 1 | None | 2, 3, 4, 6 | 4 |
| 2 | 1 | 5 | 3, 4, 6 |
| 3 | 1 | 5 | 2, 4, 6 |
| 4 | None | 5 | 1, 2, 3, 6 |
| 5 | 2, 3, 4 | 7, 8 | 6 |
| 6 | 1 | 7 | 2, 3, 4, 5 |
| 7 | 5, 6 | None | 8 |
| 8 | 5 | None | 7 |

### Agent Dispatch Summary

| Wave | Tasks | Recommended Agents |
|------|-------|-------------------|
| 1 | 1, 4 | task(category="quick") for scaffold; task(category="business-logic") for priority |
| 2 | 2, 3, 6 | task(category="deep") for msquic; task(category="unspecified-high") for ROS; task(category="quick") for launch |
| 3 | 5, 7 | task(category="deep") for integration; task(category="unspecified-high") for tests |
| 4 | 8 | task(category="deep") for reconnection |

---

## TODOs

- [ ] 1. Scaffold catkin package and build system with msquic

  **What to do**:
  - Create the `mavlink_quic_relay` catkin package directory structure:
    ```
    mavlink_quic_relay/
    ├── CMakeLists.txt
    ├── package.xml
    ├── include/mavlink_quic_relay/
    ├── src/
    ├── launch/
    ├── config/
    └── test/
    ```
  - `package.xml`: Declare dependencies on `roscpp`, `mavros_msgs`, `std_msgs`, `rostest` (test_depend)
  - `CMakeLists.txt`:
    - Use `catkin_package()` with `INCLUDE_DIRS include` and `LIBRARIES mavlink_quic_relay`
    - Find msquic: use `pkg_check_modules` or `find_library` for `libmsquic` (system install from source)
    - Set C++17 standard (`CMAKE_CXX_STANDARD 17`)
    - Set `-Wall -Wextra -Werror` compile flags
    - Add conditional logic: if msquic is installed via system package, use `find_library(MSQUIC_LIB msquic)`; if built from source, use a provided path via `-DMSQUIC_ROOT`
  - Create a minimal `main.cpp` that initializes ROS, creates a node handle, spins, and exits cleanly
  - Create a `README.md` in the package with build prerequisites (msquic install instructions for ARM64 Ubuntu 18.04/20.04)
  - Verify it builds: `catkin build mavlink_quic_relay`

  **Must NOT do**:
  - Do NOT add MAVROS as a build dependency — only `mavros_msgs`
  - Do NOT install msquic as part of this task — assume it's pre-installed. Document the install steps in README.
  - Do NOT add any QUIC logic yet — just verify the skeleton compiles and links

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Standard catkin package scaffolding with well-known patterns
  - **Skills**: []
    - No special skills needed for package scaffolding
  - **Skills Evaluated but Omitted**:
    - `frontend-ui-ux`: No UI involved
    - `playwright`: No browser involved

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 4)
  - **Blocks**: Tasks 2, 3, 6
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References** (existing code to follow):
  - Standard ROS1 catkin package structure: `catkin_create_pkg mavlink_quic_relay roscpp mavros_msgs std_msgs`
  - msquic CMake integration: msquic installs to `/usr/local/lib/libmsquic.so` and `/usr/local/include/msquic.h` when built from source

  **API/Type References**:
  - `mavros_msgs/Mavlink.msg`: Available via `ros-noetic-mavros-msgs` apt package
  - msquic header: `#include <msquic.h>` — single header API

  **External References**:
  - msquic build from source (ARM64): https://github.com/microsoft/msquic/blob/main/docs/BUILD.md
  - catkin package.xml format 2: http://wiki.ros.org/catkin/package.xml
  - catkin CMakeLists.txt guide: http://wiki.ros.org/catkin/CMakeLists.txt

  **Acceptance Criteria**:

  - [ ] Directory structure exists with all required files
  - [ ] `catkin build mavlink_quic_relay` → BUILD SUCCESSFUL (zero errors)
  - [ ] `catkin build mavlink_quic_relay --cmake-args -DCMAKE_CXX_FLAGS="-Wall -Wextra -Werror"` → zero warnings
  - [ ] `rosrun mavlink_quic_relay mavlink_quic_relay_node` → starts, prints "Node initialized", exits on Ctrl+C

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Package builds successfully
    Tool: Bash
    Preconditions: catkin workspace exists, msquic installed
    Steps:
      1. catkin build mavlink_quic_relay 2>&1
      2. Assert: output contains "mavlink_quic_relay" and "Build succeeded"
      3. Assert: exit code is 0
    Expected Result: Clean build with no errors
    Evidence: Build output captured

  Scenario: Node executable runs and exits cleanly
    Tool: Bash
    Preconditions: Package built
    Steps:
      1. roscore &
      2. sleep 2
      3. timeout 5 rosrun mavlink_quic_relay mavlink_quic_relay_node 2>&1 || true
      4. Assert: output contains "Node initialized" or similar startup message
      5. kill roscore
    Expected Result: Node starts and can be terminated
    Evidence: Terminal output captured
  ```

  **Commit**: YES
  - Message: `feat(relay): scaffold catkin package with msquic build integration`
  - Files: `mavlink_quic_relay/*`
  - Pre-commit: `catkin build mavlink_quic_relay`

---

- [ ] 2. Implement msquic QUIC client wrapper class

  **What to do**:
  - Create `include/mavlink_quic_relay/quic_client.h` and `src/quic_client.cpp`
  - Implement `QuicClient` class encapsulating all msquic interaction:
    - **Initialization**: `MsQuicOpen2()` → create `Registration` → create `Configuration` with:
      - ALPN: `"mavlink-quic-v1"` (must match server)
      - TLS: one-way (server cert validation only, no client cert)
      - Certificate pinning: load CA cert file from path (ROS param)
      - Settings: `KeepAliveIntervalMs = 15000`, `IdleTimeoutMs = 60000`
      - `PeerBidiStreamCount = 1` (for server-initiated command stream)
    - **Connection**: `ConnectionOpen()` + `ConnectionStart()` to server host:port
    - **Stream management**: Open 3 client-initiated bidirectional streams on connection success:
      - Stream 0 (first opened): Control stream
      - Stream 4 (second opened): Priority MAVLink stream
      - Stream 8 (third opened): Bulk MAVLink stream
      - Note: msquic assigns stream IDs automatically; track by open order
    - **Send interface**: `sendControlMessage(cbor_bytes)`, `sendPriorityFrame(mavlink_bytes)`, `sendBulkFrame(mavlink_bytes)`
      - Each wraps data in `[u16_le length][payload]` framing
      - Uses `StreamSend()` with RAII buffer wrapper that frees on `SEND_COMPLETE`
    - **Receive handling**: Stream receive callbacks extract length-prefixed frames and invoke a callback function
    - **Authentication**: On control stream open, send AUTH message:
      ```
      CBOR: {token: <bytes>, role: "vehicle", vehicle_id: <int>}
      ```
      Wait for AUTH_OK response before opening MAVLink streams
    - **Keepalive**: Handled automatically by msquic's `KeepAliveIntervalMs` setting
    - **Callbacks**: All msquic callbacks post to a thread-safe queue (`std::mutex` + `std::queue` or lock-free ring buffer); never process ROS logic in callbacks
    - **Shutdown**: `ConnectionShutdown()` → wait for `SHUTDOWN_COMPLETE` → `ConnectionClose()` → `ConfigurationClose()` → `RegistrationClose()` → `MsQuicClose()`

  - **Buffer lifecycle** (CRITICAL):
    - Create `SendBuffer` RAII class:
      ```cpp
      struct SendBuffer {
          QUIC_BUFFER quic_buf;
          std::vector<uint8_t> data;
          // Constructor takes ownership of data
          // Destructor is called only after SEND_COMPLETE
      };
      ```
    - Track pending sends; free on `QUIC_STREAM_EVENT_SEND_COMPLETE`
    - On connection drop, free ALL pending send buffers in `QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE`

  - **Error handling**:
    - Log all QUIC status codes via `ROS_ERROR` / `ROS_WARN`
    - On connection failure: set `connected_ = false`, trigger reconnection (Task 8)
    - On stream error: log and attempt stream re-open

  **Must NOT do**:
  - Do NOT implement reconnection logic here — that's Task 8
  - Do NOT call `ros::Publisher::publish()` from callbacks — use the queue
  - Do NOT block in any msquic callback
  - Do NOT implement MAVLink priority classification — that's Task 4
  - Do NOT parse or validate MAVLink content — relay raw bytes

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Novel integration of msquic C API with C++ ROS node; requires careful understanding of msquic threading model, buffer ownership, and async patterns
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `frontend-ui-ux`: No UI
    - `playwright`: No browser

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 3, 6)
  - **Blocks**: Task 5
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - msquic sample client: https://github.com/microsoft/msquic/blob/main/src/tools/sample/sample.c — shows connection, stream, send/receive patterns
  - msquic API documentation: https://github.com/microsoft/msquic/blob/main/docs/API.md

  **API/Type References**:
  - `msquic.h`: `QUIC_API_TABLE`, `QUIC_CONNECTION_EVENT`, `QUIC_STREAM_EVENT`, `QUIC_BUFFER`
  - Key functions: `MsQuicOpen2()`, `ConnectionOpen()`, `ConnectionStart()`, `StreamOpen()`, `StreamStart()`, `StreamSend()`, `StreamReceiveComplete()`
  - Key events: `QUIC_CONNECTION_EVENT_CONNECTED`, `QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE`, `QUIC_STREAM_EVENT_RECEIVE`, `QUIC_STREAM_EVENT_SEND_COMPLETE`

  **External References**:
  - msquic settings reference: https://github.com/microsoft/msquic/blob/main/docs/Settings.md
  - msquic TLS configuration: https://github.com/microsoft/msquic/blob/main/docs/TLS.md
  - CBOR C/C++ libraries for control messages: `tinycbor` or `nlohmann/json` with CBOR support

  **WHY Each Reference Matters**:
  - The msquic sample client is the canonical example of connection lifecycle — follow this exactly
  - Buffer ownership rules are documented in the API docs under `StreamSend` — violating them causes silent memory corruption
  - Settings docs show exact parameter names for keepalive, idle timeout, peer stream counts

  **Acceptance Criteria**:

  - [ ] `QuicClient` class compiles as part of the package (no linker errors)
  - [ ] Class can be instantiated with server host, port, token, vehicle_id parameters
  - [ ] `connect()` method attempts QUIC handshake (may fail without server — that's OK for this task)
  - [ ] `shutdown()` method cleans up all msquic resources without leaks or crashes
  - [ ] No compiler warnings with `-Wall -Wextra -Werror`

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: QuicClient compiles and links with msquic
    Tool: Bash
    Preconditions: Task 1 scaffold exists, msquic installed
    Steps:
      1. catkin build mavlink_quic_relay 2>&1
      2. Assert: exit code 0
      3. Assert: no "undefined reference" errors for msquic symbols
    Expected Result: Clean build
    Evidence: Build output captured

  Scenario: QuicClient instantiation and shutdown without crash
    Tool: Bash
    Preconditions: Package built, no server needed
    Steps:
      1. Write a minimal test main() that creates QuicClient, calls connect() (expect failure), calls shutdown()
      2. catkin build && catkin run_tests
      3. Assert: no segfault, no AddressSanitizer violations
    Expected Result: Clean lifecycle even without server
    Evidence: Test output captured
  ```

  **Commit**: YES
  - Message: `feat(relay): implement msquic QUIC client wrapper with stream management`
  - Files: `mavlink_quic_relay/include/mavlink_quic_relay/quic_client.h`, `mavlink_quic_relay/src/quic_client.cpp`
  - Pre-commit: `catkin build mavlink_quic_relay`

---

- [ ] 3. Implement ROS subscriber/publisher with thread-safe queue

  **What to do**:
  - Create `include/mavlink_quic_relay/ros_interface.h` and `src/ros_interface.cpp`
  - Implement `RosInterface` class:
    - **Subscriber**: Subscribe to `/mavlink/from` topic (`mavros_msgs/Mavlink`) with queue size 100
      - Callback receives `mavros_msgs::Mavlink` messages
      - Converts `payload64[]` to raw MAVLink bytes using `mavros_msgs::mavlink::convert()` utility (or manual uint64→uint8 unpacking)
      - Extracts `msgid` from the message (available directly as `msg->msgid`)
      - Enqueues `{msgid, raw_bytes}` pair into a thread-safe outbound queue
    - **Publisher**: Publish to `/mavlink/to` topic (`mavros_msgs/Mavlink`) with queue size 100
      - Consumes from a thread-safe inbound queue (fed by QUIC receive path)
      - Converts raw MAVLink bytes back to `mavros_msgs::Mavlink` message format
      - Publishes ONLY from the ROS spin thread (never from msquic callback thread)
    - **Thread-safe queues** (2 queues):
      - `outbound_queue_`: ROS callback → QUIC sender (mavlink frames going to server)
      - `inbound_queue_`: QUIC receiver → ROS publisher (mavlink frames coming from server)
      - Implementation: `std::queue<MavlinkFrame>` protected by `std::mutex` + `std::condition_variable`
      - OR: lock-free SPSC ring buffer (single-producer single-consumer) for lower latency
      - Max queue depth: configurable via ROS param (default: 500 for bulk, 100 for priority)
    - **Queue drain**: Use a `ros::Timer` (e.g., 1ms period) to drain the inbound queue and publish
    - **MavlinkFrame struct**:
      ```cpp
      struct MavlinkFrame {
          uint32_t msgid;
          std::vector<uint8_t> raw_bytes;  // Complete MAVLink frame
      };
      ```
    - **mavros_msgs conversion**:
      - `mavros_msgs::Mavlink` stores payload as `uint64[]` (8-byte aligned words)
      - To get raw bytes: unpack `magic`, `len`, `seq`, `sysid`, `compid`, `msgid`, then unpack `payload64[]` into bytes using the `len` field
      - Use `mavlink::convert()` from `<mavros_msgs/mavlink_convert.h>` if available for ROS1, or implement manually
    - **Topic names**: Configurable via ROS params with defaults:
      - `~mavlink_from_topic` → default `/mavlink/from`
      - `~mavlink_to_topic` → default `/mavlink/to`
    - **No-publisher warning**: If no messages received on `/mavlink/from` within 10 seconds of node start, log `ROS_WARN("No MAVLink messages received on /mavlink/from — is the FC node running?")`

  **Must NOT do**:
  - Do NOT classify messages by priority here — that's Task 4
  - Do NOT connect to QUIC here — that's Task 2
  - Do NOT parse MAVLink beyond extracting msgid and raw bytes
  - Do NOT add dynamic_reconfigure

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Standard ROS1 patterns but with thread-safety considerations for cross-thread queue design
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 2, 6)
  - **Blocks**: Task 5
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - `mavros_msgs/Mavlink.msg` definition: fields `magic`, `len`, `incompat_flags`, `compat_flags`, `seq`, `sysid`, `compid`, `msgid`, `checksum`, `payload64[]`, `signature[]`
  - ROS1 subscriber pattern: `ros::NodeHandle::subscribe<mavros_msgs::Mavlink>(topic, queue_size, callback)`
  - ROS1 timer pattern: `ros::NodeHandle::createTimer(ros::Duration(0.001), callback)` for 1ms drain

  **API/Type References**:
  - `mavros_msgs::Mavlink` C++ type (auto-generated from .msg)
  - `mavros_msgs/mavlink_convert.h` — utility to convert between `mavlink_message_t` and `mavros_msgs::Mavlink`

  **External References**:
  - ROS1 roscpp subscriber tutorial: http://wiki.ros.org/roscpp/Overview/Publishers%20and%20Subscribers
  - mavros_msgs package: https://github.com/mavlink/mavros/tree/master/mavros_msgs

  **Acceptance Criteria**:

  - [ ] `RosInterface` class compiles cleanly
  - [ ] Subscriber callback receives mavros_msgs/Mavlink and extracts msgid + raw bytes
  - [ ] Publishing from inbound queue to `/mavlink/to` works from ROS thread
  - [ ] Thread-safe queue operations don't deadlock or corrupt data
  - [ ] No compiler warnings

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Subscriber receives and queues MAVLink messages
    Tool: Bash
    Preconditions: roscore running, package built
    Steps:
      1. roscore &
      2. rosrun mavlink_quic_relay mavlink_quic_relay_node &
      3. sleep 2
      4. rostopic pub /mavlink/from mavros_msgs/Mavlink "{msgid: 0, sysid: 1, compid: 1}" --once
      5. Assert: node log shows "Received MAVLink msgid=0" or similar
      6. Kill all
    Expected Result: Message received and logged
    Evidence: Terminal output captured

  Scenario: Publisher sends to /mavlink/to topic
    Tool: Bash
    Preconditions: roscore running, package built
    Steps:
      1. roscore &
      2. rosrun mavlink_quic_relay mavlink_quic_relay_node &
      3. sleep 2
      4. rostopic echo /mavlink/to --noarr -n 1 &
      5. # Trigger inbound queue push (via test helper or internal test)
      6. Assert: rostopic echo receives a message
      7. Kill all
    Expected Result: Message published to output topic
    Evidence: Terminal output captured
  ```

  **Commit**: YES
  - Message: `feat(relay): implement ROS subscriber/publisher with thread-safe queues`
  - Files: `mavlink_quic_relay/include/mavlink_quic_relay/ros_interface.h`, `mavlink_quic_relay/src/ros_interface.cpp`
  - Pre-commit: `catkin build mavlink_quic_relay`

---

- [ ] 4. Implement MAVLink priority classification module

  **What to do**:
  - Create `include/mavlink_quic_relay/priority_classifier.h` and `src/priority_classifier.cpp`
  - Implement `PriorityClassifier` class:
    - `classify(uint32_t msgid) → StreamType` where `StreamType` is `{PRIORITY, BULK}`
    - Classification uses the allowlist from the original plan (Section 7):

      **HIGH PRIORITY (→ Priority Stream)**:
      | msgid | Name |
      |-------|------|
      | 0 | HEARTBEAT |
      | 4 | PING |
      | 20 | PARAM_REQUEST_LIST / PARAM_REQUEST_READ |
      | 22 | PARAM_VALUE |
      | 23 | PARAM_SET |
      | 39 | MISSION_ITEM |
      | 40 | MISSION_REQUEST |
      | 41 | MISSION_SET_CURRENT |
      | 44 | MISSION_COUNT |
      | 45 | MISSION_CLEAR_ALL |
      | 47 | MISSION_ACK |
      | 51 | MISSION_REQUEST_INT |
      | 73 | MISSION_ITEM_INT |
      | 75 | COMMAND_INT |
      | 76 | COMMAND_LONG |
      | 77 | COMMAND_ACK |
      | 111 | TIMESYNC |
      | 253 | STATUSTEXT |

      **BULK (→ Bulk Stream)**: Everything else (default).

    - Use a `std::unordered_set<uint32_t>` for O(1) lookup
    - Make the priority msgid set configurable via a constructor parameter (for testing and future flexibility)
    - Keep this module standalone — no ROS or QUIC dependencies

  **Must NOT do**:
  - Do NOT parse MAVLink packets — this module only operates on `msgid` integer values
  - Do NOT include ROS headers — keep this a pure C++ utility
  - Do NOT add dynamic configuration — allowlist is set at construction time

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple lookup table with no external dependencies
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Task 1)
  - **Blocks**: Task 5
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - Original plan Section 7: Message Priority Allowlist table

  **API/Type References**:
  - MAVLink message IDs: defined in `common/common.h` from MAVLink C library, but this module uses raw integers (no MAVLink dependency needed)

  **Acceptance Criteria**:

  - [ ] `classify(0)` returns `PRIORITY` (HEARTBEAT)
  - [ ] `classify(76)` returns `PRIORITY` (COMMAND_LONG)
  - [ ] `classify(30)` returns `BULK` (ATTITUDE)
  - [ ] `classify(9999)` returns `BULK` (unknown → default bulk)
  - [ ] No ROS or QUIC headers included
  - [ ] Compiles standalone

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Priority classification correctness
    Tool: Bash
    Preconditions: Package built with GTest
    Steps:
      1. catkin run_tests mavlink_quic_relay --no-deps
      2. Assert: test_priority_classifier passes
      3. Assert: HEARTBEAT(0)→PRIORITY, COMMAND_LONG(76)→PRIORITY
      4. Assert: ATTITUDE(30)→BULK, GPS_RAW_INT(24)→BULK
      5. Assert: unknown msgid(65535)→BULK
    Expected Result: All classifications correct
    Evidence: GTest output captured
  ```

  **Commit**: YES (groups with Task 1)
  - Message: `feat(relay): add MAVLink priority classification by msgid`
  - Files: `mavlink_quic_relay/include/mavlink_quic_relay/priority_classifier.h`, `mavlink_quic_relay/src/priority_classifier.cpp`
  - Pre-commit: `catkin build mavlink_quic_relay`

---

- [ ] 5. Integrate full bidirectional relay (FC ↔ Server)

  **What to do**:
  - Create `include/mavlink_quic_relay/relay_node.h` and `src/relay_node.cpp` (main orchestrator)
  - Implement `RelayNode` class that composes `QuicClient`, `RosInterface`, and `PriorityClassifier`:
    - **Outbound path** (FC → Server):
      1. `RosInterface` subscriber callback receives `mavros_msgs/Mavlink` on `/mavlink/from`
      2. Extracts `msgid` and raw bytes, pushes to outbound queue
      3. A sender thread (or timer) drains the outbound queue:
         - Calls `PriorityClassifier::classify(msgid)` → determines `PRIORITY` or `BULK`
         - Calls `QuicClient::sendPriorityFrame(bytes)` or `QuicClient::sendBulkFrame(bytes)`
      4. **Bulk queue drop policy**: If bulk outbound queue exceeds max size, drop OLDEST entry (not newest — prioritize freshness)
      5. Priority queue: never drop — if full, log `ROS_WARN` but still enqueue (queue should be large enough)
    - **Inbound path** (Server → FC):
      1. `QuicClient` receive callback gets length-prefixed frames from server streams
      2. Pushes raw MAVLink bytes to `RosInterface` inbound queue
      3. `RosInterface` drain timer converts to `mavros_msgs::Mavlink` and publishes to `/mavlink/to`
      4. No priority classification needed on inbound — just relay all frames
    - **Control stream handling**:
      1. On connection established: send AUTH message (CBOR encoded)
      2. Wait for AUTH_OK before opening MAVLink streams
      3. AUTH failure: log error, trigger reconnect with backoff
      4. PING/PONG: respond to server PINGs on control stream (if server sends them)
    - **Sender thread design**:
      - Dedicated `std::thread` that loops:
        ```
        while (running_) {
          // Always drain priority first
          while (auto frame = priority_queue_.try_pop()) {
            quic_client_.sendPriorityFrame(frame->raw_bytes);
          }
          // Then bulk (if not congested)
          while (auto frame = bulk_queue_.try_pop()) {
            quic_client_.sendBulkFrame(frame->raw_bytes);
          }
          // Sleep 1ms or wait on condition_variable
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        ```
    - **Main node lifecycle** (update `main.cpp`):
      1. Initialize ROS: `ros::init(argc, argv, "mavlink_quic_relay")`
      2. Create `ros::NodeHandle` and `ros::NodeHandle("~")` for private params
      3. Load all parameters from ROS param server
      4. Create `RelayNode` instance
      5. Call `relay_node.start()` — opens QUIC connection, starts sender thread
      6. `ros::AsyncSpinner spinner(2)` — 2 threads for ROS callbacks (subscriber + timer)
      7. `spinner.start()` then `ros::waitForShutdown()`
      8. On shutdown: `relay_node.stop()` — stops sender thread, shuts down QUIC, joins threads

  **Must NOT do**:
  - Do NOT implement reconnection with backoff — that's Task 8. For now, log connection failure and exit.
  - Do NOT implement statistics or monitoring topics
  - Do NOT validate MAVLink frame content — transparent relay

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Core integration task combining 3 components with threading, queue management, and msquic callback handling
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 3 (sequential — depends on Tasks 2, 3, 4)
  - **Blocks**: Tasks 7, 8
  - **Blocked By**: Tasks 2, 3, 4

  **References**:

  **Pattern References**:
  - `QuicClient` from Task 2 — send/receive interface
  - `RosInterface` from Task 3 — subscriber/publisher + queues
  - `PriorityClassifier` from Task 4 — classify by msgid
  - `ros::AsyncSpinner` pattern: http://wiki.ros.org/roscpp/Overview/Callbacks%20and%20Spinning#Multi-threaded_Spinning

  **API/Type References**:
  - `ros::AsyncSpinner` — multi-threaded ROS callback processing
  - `ros::waitForShutdown()` — blocks until ROS shutdown signal
  - `std::condition_variable` — for efficient queue drain signaling

  **Acceptance Criteria**:

  - [ ] Node starts, connects to server (or fails gracefully without server), and advertises both topics
  - [ ] MAVLink frame published to `/mavlink/from` with msgid=0 (HEARTBEAT) is sent on QUIC priority stream
  - [ ] MAVLink frame published to `/mavlink/from` with msgid=30 (ATTITUDE) is sent on QUIC bulk stream
  - [ ] Frame sent from server on QUIC stream arrives as mavros_msgs/Mavlink on `/mavlink/to`
  - [ ] AUTH message is sent on control stream on connection
  - [ ] Bulk queue drops oldest when full (queue size exceeded)
  - [ ] Node exits cleanly — no zombie threads, no segfaults

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: End-to-end outbound relay (FC → Server)
    Tool: Bash
    Preconditions: Mock aioquic server running on localhost:5000, roscore running
    Steps:
      1. Start mock server: python3 mock_server.py &
      2. roscore &
      3. roslaunch mavlink_quic_relay relay.launch server_host:=127.0.0.1 server_port:=5000 &
      4. sleep 5 (wait for connection)
      5. rostopic pub /mavlink/from mavros_msgs/Mavlink "{msgid: 0, sysid: 1, compid: 1, magic: 254, len: 9, seq: 0, checksum: 0, payload64: [0]}" --once
      6. Assert: mock server log shows received frame with msgid=0 on priority stream
      7. Kill all
    Expected Result: HEARTBEAT relayed to server on priority stream
    Evidence: Server log + terminal output captured

  Scenario: End-to-end inbound relay (Server → FC)
    Tool: Bash
    Preconditions: Mock server running, roscore, node connected
    Steps:
      1. Start mock server, roscore, relay node (as above)
      2. rostopic echo /mavlink/to --noarr -n 1 &
      3. Trigger mock server to send a MAVLink frame (COMMAND_LONG msgid=76)
      4. Assert: rostopic echo receives message with msgid=76
      5. Kill all
    Expected Result: Command from server published to /mavlink/to
    Evidence: Terminal output captured

  Scenario: Priority routing correctness
    Tool: Bash
    Preconditions: Mock server with stream logging
    Steps:
      1. Start system (mock server, roscore, relay node)
      2. Publish msgid=0 (HEARTBEAT) to /mavlink/from
      3. Publish msgid=30 (ATTITUDE) to /mavlink/from
      4. Assert: mock server received msgid=0 on stream_id for priority
      5. Assert: mock server received msgid=30 on stream_id for bulk
    Expected Result: Correct stream routing
    Evidence: Server stream logs captured
  ```

  **Commit**: YES
  - Message: `feat(relay): integrate bidirectional MAVLink relay with priority routing`
  - Files: `mavlink_quic_relay/include/mavlink_quic_relay/relay_node.h`, `mavlink_quic_relay/src/relay_node.cpp`, `mavlink_quic_relay/src/main.cpp`
  - Pre-commit: `catkin build mavlink_quic_relay`

---

- [ ] 6. Create launch file and ROS parameter configuration

  **What to do**:
  - Create `launch/relay.launch`:
    ```xml
    <launch>
      <node name="mavlink_quic_relay" pkg="mavlink_quic_relay" type="mavlink_quic_relay_node" output="screen">
        <rosparam command="load" file="$(find mavlink_quic_relay)/config/relay_params.yaml" />
        <!-- Allow overrides via launch args -->
        <param name="server_host" value="$(arg server_host)" if="$(eval arg('server_host') != '')" />
        <param name="server_port" value="$(arg server_port)" if="$(eval arg('server_port') != 0)" />
      </node>
      <arg name="server_host" default="" />
      <arg name="server_port" default="0" />
    </launch>
    ```
  - Create `config/relay_params.yaml`:
    ```yaml
    # QUIC Server
    server_host: "quic.yourdomain.com"
    server_port: 5000

    # Authentication
    auth_token: "CHANGE_ME"
    vehicle_id: 1

    # TLS
    ca_cert_path: "/etc/mavlink_relay/server_ca.crt"

    # Topics
    mavlink_from_topic: "/mavlink/from"
    mavlink_to_topic: "/mavlink/to"

    # Queue sizes
    priority_queue_size: 100
    bulk_queue_size: 500

    # Reconnection
    reconnect_initial_ms: 1000
    reconnect_max_ms: 30000
    reconnect_jitter_pct: 10

    # Keepalive (msquic handles this via settings)
    keepalive_interval_ms: 15000
    idle_timeout_ms: 60000

    # ALPN
    alpn: "mavlink-quic-v1"
    ```
  - Ensure all parameters are loaded in `main.cpp` / `RelayNode` constructor via `ros::NodeHandle::param<T>()`
  - Add parameter validation: log `ROS_FATAL` and exit if `auth_token` is `"CHANGE_ME"` or empty

  **Must NOT do**:
  - Do NOT add dynamic_reconfigure
  - Do NOT add ROS services for runtime control

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Standard ROS launch file and YAML config — well-known patterns
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 2, 3)
  - **Blocks**: Task 7
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - ROS1 launch file format: http://wiki.ros.org/roslaunch/XML
  - ROS1 rosparam YAML: http://wiki.ros.org/rosparam

  **Acceptance Criteria**:

  - [ ] `roslaunch mavlink_quic_relay relay.launch` starts the node
  - [ ] `rosparam get /mavlink_quic_relay/server_host` returns configured value
  - [ ] Node exits with `ROS_FATAL` if `auth_token` is "CHANGE_ME"
  - [ ] Launch args override YAML defaults: `roslaunch mavlink_quic_relay relay.launch server_host:=1.2.3.4`

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Launch file loads parameters
    Tool: Bash
    Preconditions: roscore running, package built
    Steps:
      1. roscore &
      2. roslaunch mavlink_quic_relay relay.launch &
      3. sleep 3
      4. rosparam get /mavlink_quic_relay/server_host
      5. Assert: output matches value in relay_params.yaml
      6. rosparam get /mavlink_quic_relay/server_port
      7. Assert: output is 5000
      8. Kill all
    Expected Result: All params loaded correctly
    Evidence: Terminal output captured

  Scenario: Invalid auth_token causes fatal exit
    Tool: Bash
    Preconditions: roscore running
    Steps:
      1. roscore &
      2. roslaunch mavlink_quic_relay relay.launch 2>&1 | grep -i "fatal"
      3. Assert: output contains "auth_token" and "CHANGE_ME" or similar error
    Expected Result: Node refuses to start with default token
    Evidence: Terminal output captured
  ```

  **Commit**: YES
  - Message: `feat(relay): add launch file and parameter configuration`
  - Files: `mavlink_quic_relay/launch/relay.launch`, `mavlink_quic_relay/config/relay_params.yaml`
  - Pre-commit: `catkin build mavlink_quic_relay`

---

- [ ] 7. Implement GTest unit tests and rostest integration tests

  **What to do**:
  - **GTest unit tests** (no ROS or network required):
    - `test/test_priority_classifier.cpp`:
      - Test all 18 high-priority msgids → `PRIORITY`
      - Test common bulk msgids (ATTITUDE=30, GPS_RAW_INT=24, RAW_IMU=27) → `BULK`
      - Test unknown msgid (65535) → `BULK`
      - Test boundary: msgid=0 → `PRIORITY` (HEARTBEAT)
    - `test/test_thread_safe_queue.cpp`:
      - Test single-threaded push/pop correctness
      - Test multi-threaded concurrent push/pop (no data loss, no deadlock)
      - Test queue full behavior (oldest dropped for bulk queue)
      - Test queue empty behavior (try_pop returns nullopt/false)
    - `test/test_mavlink_framing.cpp`:
      - Test length-prefix encoding: `[u16_le len][payload]` → correct bytes
      - Test length-prefix decoding: bytes → extracted frames
      - Test multiple frames in one buffer (streaming decode)
      - Test empty payload
      - Test max-size MAVLink frame (280 bytes)
    - Register in `CMakeLists.txt`:
      ```cmake
      if(CATKIN_ENABLE_TESTING)
        catkin_add_gtest(test_priority_classifier test/test_priority_classifier.cpp src/priority_classifier.cpp)
        catkin_add_gtest(test_thread_safe_queue test/test_thread_safe_queue.cpp)
        catkin_add_gtest(test_mavlink_framing test/test_mavlink_framing.cpp)
      endif()
      ```

  - **rostest integration tests** (require roscore + mock server):
    - `test/test_relay_roundtrip.test` + `test/test_relay_roundtrip.py` (or .cpp):
      - Launch relay node with mock server params
      - Publish MAVLink to `/mavlink/from`
      - Assert: mock server receives frame within 500ms
    - `test/test_reconnect.test`:
      - Launch relay node
      - Kill mock server
      - Wait for reconnect attempt logs
      - Restart mock server
      - Assert: relay re-establishes connection
    - Note: Mock aioquic server script needed for integration tests — create a minimal Python script `test/mock_quic_server.py` using aioquic that accepts AUTH and echoes frames

  **Must NOT do**:
  - Do NOT aim for 100% code coverage — focus on critical paths
  - Do NOT test msquic internals — test the wrapper interface
  - Do NOT create complex test infrastructure — keep tests simple and fast

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Multiple test files across unit and integration, requires understanding of GTest patterns and rostest
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Task 8)
  - **Blocks**: None
  - **Blocked By**: Tasks 5, 6

  **References**:

  **Pattern References**:
  - ROS1 GTest with catkin: http://wiki.ros.org/catkin/CMakeLists.txt#Testing
  - rostest format: http://wiki.ros.org/rostest

  **API/Type References**:
  - GTest: `TEST()`, `EXPECT_EQ()`, `ASSERT_TRUE()`
  - rostest: `<test>` tag in launch file, `rostest` command

  **External References**:
  - aioquic minimal server example: https://github.com/aiortc/aioquic/blob/main/examples/

  **Acceptance Criteria**:

  - [ ] `catkin run_tests mavlink_quic_relay --no-deps` → all GTest tests pass
  - [ ] `test_priority_classifier`: 18+ test cases, all pass
  - [ ] `test_thread_safe_queue`: concurrent push/pop test passes without deadlock (timeout 10s)
  - [ ] `test_mavlink_framing`: encode/decode roundtrip test passes
  - [ ] Integration test `test_relay_roundtrip` passes with mock server

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: All unit tests pass
    Tool: Bash
    Preconditions: Package built with tests enabled
    Steps:
      1. catkin run_tests mavlink_quic_relay --no-deps 2>&1
      2. catkin_test_results build/mavlink_quic_relay 2>&1
      3. Assert: "0 failures" for all test suites
      4. Assert: exit code 0
    Expected Result: All GTest tests green
    Evidence: Test output captured

  Scenario: Integration roundtrip test passes
    Tool: Bash
    Preconditions: aioquic installed (pip3 install aioquic), roscore available
    Steps:
      1. rostest mavlink_quic_relay test_relay_roundtrip.test 2>&1
      2. Assert: "RESULT: SUCCESS" in output
    Expected Result: End-to-end relay verified
    Evidence: rostest output captured
  ```

  **Commit**: YES
  - Message: `test(relay): add GTest unit tests and rostest integration tests`
  - Files: `mavlink_quic_relay/test/*`
  - Pre-commit: `catkin run_tests mavlink_quic_relay --no-deps`

---

- [ ] 8. Implement reconnection, exponential backoff, and graceful shutdown

  **What to do**:
  - **Reconnection with exponential backoff**:
    - Create `include/mavlink_quic_relay/reconnect_manager.h` and `src/reconnect_manager.cpp`
    - `ReconnectManager` class:
      - Backoff sequence: 1s, 2s, 4s, 8s, 16s, 30s (capped) — exponential with cap
      - Jitter: ±10% of current backoff value (random)
      - On connection loss (msquic `SHUTDOWN_COMPLETE` event):
        1. Set `connected_ = false`
        2. Drop ALL bulk queue entries (stale telemetry is useless after reconnect)
        3. Retain priority queue entries (limited, may still be relevant)
        4. Wait for backoff period
        5. Attempt reconnect: `QuicClient::connect()`
        6. On success: reset backoff to 1s, re-authenticate, re-open streams
        7. On failure: increase backoff, loop
      - On AUTH failure (bad token): log `ROS_ERROR`, set longer backoff (60s) — token likely needs manual update, don't spam server
      - Thread: runs in its own `std::thread` to avoid blocking ROS or QUIC threads
      - Shutdown: `stop()` signals thread to exit, joins

  - **Graceful shutdown sequence** (update `RelayNode`):
    1. `ros::waitForShutdown()` returns (Ctrl+C or `rosnode kill`)
    2. Set `running_ = false`
    3. Signal sender thread to wake up and exit
    4. Stop reconnect manager
    5. Call `QuicClient::shutdown()`:
       - `ConnectionShutdown(QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0)` — graceful close
       - Wait for `QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE` (with 5s timeout)
       - Free all pending send buffers
       - `ConnectionClose()` → `ConfigurationClose()` → `RegistrationClose()` → `MsQuicClose()`
    6. Stop ROS spinner
    7. Join all threads
    8. Verify: no threads running, no memory leaks

  - **`ros::ok()` safety**:
    - All msquic callbacks check `running_` flag (atomic bool), NOT `ros::ok()`
    - `ros::ok()` is only checked in the ROS spin thread
    - This prevents race conditions where ROS shuts down while msquic callbacks are in progress

  - **Connection state machine**:
    ```
    DISCONNECTED → CONNECTING → AUTHENTICATING → CONNECTED → DISCONNECTED
                      ↑                                         │
                      └─────── (backoff wait) ──────────────────┘
    ```

  **Must NOT do**:
  - Do NOT implement QUIC connection migration (0-RTT resumption) — full reconnect is fine for v1
  - Do NOT add UI/visual connection status — use ROS logging only
  - Do NOT retry AUTH failures aggressively — bad token needs manual fix

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Complex threading, state machine, interaction between msquic lifecycle and ROS shutdown
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3 (with Task 7)
  - **Blocks**: None
  - **Blocked By**: Task 5

  **References**:

  **Pattern References**:
  - Original plan Section 4.5: Reconnect strategy table (same failure/action pairs apply)
  - msquic connection lifecycle: `QUIC_CONNECTION_EVENT_SHUTDOWN_INITIATED_BY_TRANSPORT`, `QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE`

  **API/Type References**:
  - `std::atomic<bool> running_` — thread-safe flag
  - `std::condition_variable` — for waking reconnect thread from sleep during shutdown
  - `ConnectionShutdown(QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, error_code)` — graceful QUIC close

  **Acceptance Criteria**:

  - [ ] Node reconnects after server kills connection (within backoff_max + 5s)
  - [ ] Backoff increases: 1s → 2s → 4s → ... → 30s cap
  - [ ] Bulk queue is cleared on reconnect (stale data dropped)
  - [ ] AUTH failure triggers extended backoff (60s)
  - [ ] `rosnode kill /mavlink_quic_relay` results in clean exit: no zombie threads, no segfault
  - [ ] `ps aux | grep mavlink_quic_relay | grep -v grep | wc -l` → 0 after kill

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Reconnection after server disconnect
    Tool: Bash
    Preconditions: Mock server running, relay connected
    Steps:
      1. Start mock server, roscore, relay node
      2. Verify connection established (check node log for "Connected" message)
      3. Kill mock server
      4. Wait 2s
      5. Assert: node log shows "Connection lost" and "Reconnecting in 1000ms"
      6. Restart mock server
      7. Wait 10s
      8. Assert: node log shows "Reconnected" and "Authenticated"
    Expected Result: Automatic reconnection
    Evidence: Terminal output captured

  Scenario: Clean shutdown with no zombie threads
    Tool: Bash
    Preconditions: Relay node running
    Steps:
      1. Start roscore, relay node
      2. sleep 3
      3. rosnode kill /mavlink_quic_relay
      4. sleep 3
      5. ps aux | grep mavlink_quic_relay | grep -v grep | wc -l
      6. Assert: output is "0"
    Expected Result: No processes remaining
    Evidence: ps output captured

  Scenario: Exponential backoff timing
    Tool: Bash
    Preconditions: No server available (relay can't connect)
    Steps:
      1. Start roscore, relay node (with server_host pointing to unreachable address)
      2. Capture log for 60s
      3. Extract reconnect timestamps from log
      4. Assert: intervals approximately 1s, 2s, 4s, 8s, 16s, 30s, 30s...
    Expected Result: Exponential backoff with cap at 30s
    Evidence: Log timestamps captured
  ```

  **Commit**: YES
  - Message: `feat(relay): add reconnection with exponential backoff and graceful shutdown`
  - Files: `mavlink_quic_relay/include/mavlink_quic_relay/reconnect_manager.h`, `mavlink_quic_relay/src/reconnect_manager.cpp`, updates to `relay_node.cpp`
  - Pre-commit: `catkin build mavlink_quic_relay`

---

## Commit Strategy

| After Task | Message | Files | Verification |
|------------|---------|-------|--------------|
| 1 | `feat(relay): scaffold catkin package with msquic build integration` | CMakeLists.txt, package.xml, src/main.cpp | catkin build |
| 2 | `feat(relay): implement msquic QUIC client wrapper with stream management` | quic_client.h, quic_client.cpp | catkin build |
| 3 | `feat(relay): implement ROS subscriber/publisher with thread-safe queues` | ros_interface.h, ros_interface.cpp | catkin build |
| 4 | `feat(relay): add MAVLink priority classification by msgid` | priority_classifier.h, priority_classifier.cpp | catkin build |
| 5 | `feat(relay): integrate bidirectional MAVLink relay with priority routing` | relay_node.h, relay_node.cpp, main.cpp | catkin build |
| 6 | `feat(relay): add launch file and parameter configuration` | relay.launch, relay_params.yaml | catkin build |
| 7 | `test(relay): add GTest unit tests and rostest integration tests` | test/* | catkin run_tests |
| 8 | `feat(relay): add reconnection with exponential backoff and graceful shutdown` | reconnect_manager.h, reconnect_manager.cpp | catkin build |

---

## Success Criteria

### Verification Commands
```bash
# Build succeeds
catkin build mavlink_quic_relay
# Expected: "Build succeeded"

# All tests pass
catkin run_tests mavlink_quic_relay --no-deps && catkin_test_results build/mavlink_quic_relay
# Expected: "0 failures"

# Node starts and advertises topics
roslaunch mavlink_quic_relay relay.launch &
sleep 3
rostopic list | grep mavlink
# Expected: /mavlink/from and /mavlink/to listed

# Node exits cleanly
rosnode kill /mavlink_quic_relay && sleep 2 && ps aux | grep mavlink_quic | grep -v grep | wc -l
# Expected: 0
```

### Final Checklist
- [ ] All "Must Have" items present and working
- [ ] All "Must NOT Have" guardrails respected (no MAVROS dep, no dynamic_reconfigure, etc.)
- [ ] All GTest and rostest tests pass
- [ ] Builds on ARM64 Ubuntu 18.04 and 20.04 with C++17
- [ ] Compatible with Jetson Xavier NX and Orin Nano
- [ ] No compiler warnings with `-Wall -Wextra -Werror`
- [ ] No memory leaks (tested with Valgrind or ASan on at least one task)
- [ ] Clean shutdown with no zombie threads
