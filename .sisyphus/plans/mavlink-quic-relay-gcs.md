# MAVLink QUIC Relay System — QGroundControl GCS Link Implementation Plan

## TL;DR

> **Quick Summary**: Add a new QUIC link type to a custom QGroundControl fork (Qt 6.6.3) that connects to the Python aioquic relay server over msquic, authenticates, subscribes to a vehicle, and bidirectionally relays MAVLink frames — integrating seamlessly with QGC's existing LinkInterface architecture so all existing MAVLink handling (parsing, widgets, mission management) works transparently.
>
> **Deliverables**:
> - `QUICLink` class extending `LinkInterface` with msquic QUIC client
> - `QUICLinkConfiguration` extending `LinkConfiguration` with QUIC-specific settings
> - 3 multiplexed QUIC streams (control, priority, bulk) matching wire protocol
> - AUTH + SUBSCRIBE control protocol (CBOR on stream 0)
> - MAVLink priority classification on outbound (same 18-msgid table as Jetson)
> - Inbound MAVLink injection via `bytesReceived` signal into QGC parsing pipeline
> - Certificate pinning for self-signed server CA
> - Reconnection with exponential backoff (1s–30s, ±10% jitter)
> - QML settings UI for QUIC link configuration
> - msquic build integration via CMake (desktop Linux + Android NDK cross-compile)
> - GTest/QTest unit tests
>
> **Estimated Effort**: XL
> **Parallel Execution**: YES — 4 waves
> **Critical Path**: Task 1 (msquic build) → Task 2 (QUICLink skeleton) → Task 4 (msquic client) → Task 6 (relay integration) → Task 9 (tests)

---

## Context

### Original Request
Add a QUIC link type to an existing custom QGroundControl fork (based on Qt 6.6.3) that connects to the MAVLink QUIC relay server as a GCS client. This is part of a 3-component system: Jetson vehicle node → Python relay server → QGC GCS.

### Interview Summary
**Key Discussions**:
- **QGC fork**: Custom fork based on Qt 6.6.3 — NOT upstream QGC. User maintains their own build.
- **QUIC library**: msquic (Microsoft) — same as Jetson node for consistency. Native C++ integration with QGC.
- **Target platforms**: Desktop Linux (primary development), Android (production deployment via NDK).
- **Wire protocol**: `[u16_le length][raw MAVLink bytes]` per stream — shared with Jetson and Server plans.
- **Control messages**: CBOR encoded on stream 0 (AUTH, SUBSCRIBE, PING, PONG, etc.).
- **Streams**: 3 persistent bidirectional QUIC streams per connection (control=0, priority=4, bulk=8).
- **Bidirectional**: GCS sends commands to vehicle AND receives telemetry from vehicle.
- **Test strategy**: Tests after implementation, no TDD.
- **Scope**: ONLY the QGC QUIC link addition. Not the server, not the Jetson node.

### Research Findings
- **QGC LinkInterface architecture**: `LinkInterface` base class with virtual `_writeBytes(QByteArray)` for sending, `bytesReceived(LinkInterface*, QByteArray)` signal for receiving. `LinkConfiguration` handles persistent settings. `LinkManager` orchestrates link lifecycle.
- **UDPLink pattern**: Worker thread pattern using `QThread`, `QMetaObject::invokeMethod` for thread safety, `writeBytesThreadSafe()` routes from any thread to link's thread.
- **LinkConfiguration enum**: `TypeSerial, TypeUdp, TypeTcp, TypeMock, TypeLog` — needs new `TypeQuic` entry.
- **QML settings**: `LinkSettings.qml` provides UI for configuring link types — needs QUIC-specific fields.
- **msquic on Android**: Buildable via CMake + Android NDK (ARM64, API 26+). Zero JNI overhead — native C++ integration. ~600KB footprint. Experimental but functional.
- **msquic on desktop Linux**: Mature, standard CMake `find_package(msquic)` or `FetchContent`.
- **Cronet eliminated**: HTTP/3 only, no custom ALPN, no raw stream access.

### Metis Review
**Identified Gaps** (all addressed):
- **Thread model**: msquic callbacks fire on msquic worker threads, NOT Qt event loop. Must bridge via `QMetaObject::invokeMethod(Qt::QueuedConnection)` or thread-safe queue. **Applied**: All msquic callbacks post to a `QueuedConnection` invoke on the QUICLink object (which lives in its own QThread).
- **QGC link lifecycle**: `_connect()` and `_disconnect()` are called by LinkManager. Must map cleanly to msquic `ConnectionStart` / `ConnectionShutdown`. **Applied**: `_connect()` starts msquic connection; `_disconnect()` performs graceful QUIC shutdown.
- **Android NDK msquic build**: Experimental. Plan includes a dedicated build verification task. **Applied**: Task 1 is msquic build integration with fallback guidance.
- **Certificate pinning**: msquic supports custom certificate validation via `QUIC_CREDENTIAL_CONFIG`. Self-signed CA loaded from file. **Applied**: CA cert path in `QUICLinkConfiguration`.
- **MAVLink injection**: `emit bytesReceived(this, data)` on link → triggers `MAVLinkProtocol::receiveBytes()`. Must emit complete MAVLink frames (not partial). **Applied**: FrameDecoder accumulates until complete frame before emitting.
- **Priority classification is client responsibility**: Server does NOT classify. GCS must classify outbound MAVLink by msgid before routing to priority/bulk stream. **Applied**: Same 18-msgid priority table as Jetson plan.
- **Settings persistence**: QGC persists link configs via `QSettings`. `QUICLinkConfiguration` must implement `saveSettings()` / `loadSettings()`. **Applied**: All QUIC fields serialized to QSettings.
- **SUBSCRIBE timing**: GCS must send SUBSCRIBE after AUTH_OK, before expecting telemetry. **Applied**: Connection state machine handles this sequence.
- **Multiple QUIC links**: User may want to connect to multiple vehicles (different servers or different vehicle_ids on same server). QGC supports multiple links. **Applied**: Each QUICLink is independent.

---

## System Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ QGroundControl (Custom Fork — Qt 6.6.3)                        │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ LinkManager                                               │  │
│  │   _rgLinks: [ ..., QUICLink*, ... ]                      │  │
│  │   createConnectedLink(QUICLinkConfiguration) → QUICLink  │  │
│  └──────────────────────┬───────────────────────────────────┘  │
│                         │ manages                               │
│  ┌──────────────────────┴───────────────────────────────────┐  │
│  │ QUICLink : LinkInterface                                  │  │
│  │                                                           │  │
│  │  _writeBytes(QByteArray) ──► PriorityClassifier           │  │
│  │                               │ msgid→PRIORITY or BULK    │  │
│  │                               ▼                           │  │
│  │                          msquic Client                     │  │
│  │                          ┌─────────────────────────┐      │  │
│  │                          │ Stream 0: Control       │      │  │
│  │                          │   AUTH → AUTH_OK         │      │  │
│  │                          │   SUBSCRIBE → SUB_OK    │      │  │
│  │                          │   PING ← → PONG         │      │  │
│  │                          │ Stream 4: Priority      │──────│──│──► Server
│  │                          │   HEARTBEAT, COMMAND_*   │      │  │
│  │                          │ Stream 8: Bulk          │──────│──│──► Server
│  │                          │   ATTITUDE, GPS, IMU     │      │  │
│  │                          └─────────────────────────┘      │  │
│  │                                                           │  │
│  │  Receive path:                                            │  │
│  │    msquic StreamReceive → FrameDecoder                    │  │
│  │      → emit bytesReceived(this, mavlink_bytes)            │  │
│  │        → MAVLinkProtocol::receiveBytes()                  │  │
│  │          → all QGC widgets/vehicles/missions work         │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ QUICLinkConfiguration : LinkConfiguration                 │  │
│  │   serverHost, serverPort, authToken, vehicleId,           │  │
│  │   caCertPath, autoSubscribe                               │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ LinkSettings.qml (QUIC section)                           │  │
│  │   Server: [______________] Port: [_____]                  │  │
│  │   Token:  [______________] Vehicle ID: [___]              │  │
│  │   CA Cert: [Browse...]                                    │  │
│  └──────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
                         │ QUIC/TLS 1.3 (UDP)
                         ▼
              ┌────────────────────┐
              │ Python aioquic     │
              │ Relay Server       │
              └────────────────────┘
```

### Data Flow

```
OUTBOUND (QGC → Server → Vehicle):
  1. QGC widget/mission/command generates MAVLink
  2. MAVLinkProtocol serializes → calls QUICLink::_writeBytes(bytes)
  3. PriorityClassifier inspects MAVLink msgid from header
  4. Routes to Stream 4 (priority) or Stream 8 (bulk)
  5. Wraps in [u16_le length][payload] frame
  6. msquic StreamSend()

INBOUND (Vehicle → Server → QGC):
  1. msquic StreamReceive callback fires (msquic worker thread)
  2. FrameDecoder accumulates bytes, extracts complete frames
  3. QMetaObject::invokeMethod(this, Qt::QueuedConnection) → QUICLink thread
  4. emit bytesReceived(this, mavlink_frame)
  5. MAVLinkProtocol::receiveBytes() parses → updates Vehicle, widgets, maps
```

### Shared Protocol Constants (Cross-Plan Consistency)

| Constant | Value | Also In |
|----------|-------|---------|
| ALPN | `"mavlink-quic-v1"` | Jetson plan, Server plan |
| Control stream ID | 0 (first client bidi) | Jetson plan, Server plan |
| Priority stream ID | 4 (second client bidi) | Jetson plan, Server plan |
| Bulk stream ID | 8 (third client bidi) | Jetson plan, Server plan |
| Wire framing | `[u16_le length][raw MAVLink]` | Jetson plan, Server plan |
| Control encoding | CBOR | Jetson plan, Server plan |
| Keepalive interval | 15 seconds | Jetson plan, Server plan |
| Keepalive timeout | 45 seconds (3× missed) | Jetson plan, Server plan |
| Reconnect backoff | 1s→2s→4s→8s→16s→30s cap, ±10% jitter | Jetson plan |
| AUTH token | Opaque 128-bit random | Jetson plan, Server plan |

### Control Message Formats (CBOR — Must Match Server)

```
AUTH (GCS → server):
  {
    "type": "AUTH",
    "token": <bytes: 16-byte auth token>,
    "role": "gcs",
    "gcs_id": <str: unique GCS identifier>
  }

AUTH_OK (server → GCS):
  {"type": "AUTH_OK"}

AUTH_FAIL (server → GCS):
  {"type": "AUTH_FAIL", "reason": <str>}

SUBSCRIBE (GCS → server):
  {"type": "SUBSCRIBE", "vehicle_id": <int>}

SUB_OK (server → GCS):
  {"type": "SUB_OK", "vehicle_id": <int>}

SUB_FAIL (server → GCS):
  {"type": "SUB_FAIL", "vehicle_id": <int>, "reason": <str>}

PING (either → either):
  {"type": "PING", "ts": <float: unix timestamp>}

PONG (either → either):
  {"type": "PONG", "ts": <float: original timestamp from PING>}

VEHICLE_OFFLINE (server → GCS):
  {"type": "VEHICLE_OFFLINE", "vehicle_id": <int>}
```

### MAVLink Priority Classification Table (Same as Jetson)

| msgid | Name | Stream |
|-------|------|--------|
| 0 | HEARTBEAT | Priority (4) |
| 4 | PING | Priority (4) |
| 20 | PARAM_REQUEST_LIST / PARAM_REQUEST_READ | Priority (4) |
| 22 | PARAM_VALUE | Priority (4) |
| 23 | PARAM_SET | Priority (4) |
| 39 | MISSION_ITEM | Priority (4) |
| 40 | MISSION_REQUEST | Priority (4) |
| 41 | MISSION_SET_CURRENT | Priority (4) |
| 44 | MISSION_COUNT | Priority (4) |
| 45 | MISSION_CLEAR_ALL | Priority (4) |
| 47 | MISSION_ACK | Priority (4) |
| 51 | MISSION_REQUEST_INT | Priority (4) |
| 73 | MISSION_ITEM_INT | Priority (4) |
| 75 | COMMAND_INT | Priority (4) |
| 76 | COMMAND_LONG | Priority (4) |
| 77 | COMMAND_ACK | Priority (4) |
| 111 | TIMESYNC | Priority (4) |
| 253 | STATUSTEXT | Priority (4) |
| * | Everything else | Bulk (8) |

---

## Work Objectives

### Core Objective
Add a production-ready QUIC link type to an existing QGroundControl fork that transparently integrates with QGC's MAVLink infrastructure, enabling remote vehicle connectivity through the QUIC relay server.

### Concrete Deliverables
- New source files in `src/Comms/`:
  - `QUICLink.h` / `QUICLink.cc` — link implementation
  - `QUICLinkConfiguration.h` / `QUICLinkConfiguration.cc` — link settings
  - `QUICClient.h` / `QUICClient.cc` — msquic wrapper
  - `QUICFrameDecoder.h` / `QUICFrameDecoder.cc` — length-prefix framing
  - `QUICPriorityClassifier.h` / `QUICPriorityClassifier.cc` — msgid priority routing
  - `QUICControlProtocol.h` / `QUICControlProtocol.cc` — CBOR control handler
- Updated files:
  - `LinkConfiguration.h` — add `TypeQuic` enum
  - `LinkManager.h/.cc` — register QUIC link type in factory
  - `CMakeLists.txt` — add msquic dependency and new source files
- QML settings UI:
  - `src/UI/preferences/QUICLinkSettings.qml` — QUIC-specific config panel
  - Update `LinkSettings.qml` — add QUIC type to link type selector
- Build integration:
  - CMake `FindMsQuic.cmake` or `FetchContent` for msquic
  - Android NDK cross-compile support for msquic
- Tests:
  - `test/Comms/QUICFrameDecoderTest.cc`
  - `test/Comms/QUICPriorityClassifierTest.cc`

### Definition of Done
- [ ] QGC builds with msquic on desktop Linux: `cmake --build build/` succeeds
- [ ] QGC builds with msquic for Android via NDK cross-compilation
- [ ] QUIC link type appears in QGC Link Settings UI
- [ ] Creating a QUIC link with valid settings connects to relay server
- [ ] AUTH + SUBSCRIBE handshake completes (AUTH_OK + SUB_OK received)
- [ ] Telemetry from vehicle appears in QGC (map, HUD, values widget)
- [ ] Commands sent from QGC reach the vehicle (verified via server relay logs)
- [ ] VEHICLE_OFFLINE notification is handled (link state updated)
- [ ] Reconnection works after server/network drop
- [ ] Link settings persist across QGC restarts (QSettings)
- [ ] All unit tests pass

### Must Have
- msquic QUIC client with TLS 1.3 and ALPN `"mavlink-quic-v1"`
- 3 persistent QUIC streams (control=0, priority=4, bulk=8) — client-initiated bidirectional
- CBOR-encoded control messages on stream 0 (AUTH, SUBSCRIBE, PING/PONG handling)
- Length-prefix wire framing `[u16_le length][payload]` matching Jetson and Server
- MAVLink priority classification (17 high-priority msgids) on outbound
- Inbound frames emitted via `bytesReceived` signal for transparent QGC integration
- Certificate pinning (load self-signed CA from file path)
- Reconnection with exponential backoff (1s→30s cap, ±10% jitter)
- `QUICLinkConfiguration` with QSettings persistence (host, port, token, vehicle_id, CA path)
- QML settings UI panel for QUIC link configuration
- Thread-safe bridge from msquic callbacks to Qt event loop
- Connection state machine: DISCONNECTED → CONNECTING → AUTHENTICATING → SUBSCRIBING → CONNECTED
- VEHICLE_OFFLINE control message handling (update link state / emit signal)
- `gcs_id` generation: use a persistent UUID stored in QSettings, or derive from QGC installation ID

### Must NOT Have (Guardrails)
- **NO** MAVLink frame parsing beyond extracting msgid from the 3-byte header offset — transparent relay
- **NO** custom MAVLink routing or sysid/compid filtering — all frames relay transparently
- **NO** QUIC server functionality — GCS is client-only
- **NO** QUIC datagram support — reliable streams only
- **NO** TLS certificate generation — cert paths are configuration only
- **NO** JNI (Java Native Interface) — msquic integrates directly as native C++ with QGC
- **NO** custom congestion control — use msquic/QUIC defaults
- **NO** modification to MAVLinkProtocol.h/.cc — inject via standard `bytesReceived` signal
- **NO** multi-server connection per QUICLink — one link = one server connection
- **NO** vehicle discovery or listing — user provides vehicle_id in config, subscribes explicitly
- **NO** changes to QGC's UDP, TCP, or Serial link implementations
- **NO** data persistence or logging beyond QGC's existing logging infrastructure
- **NO** blocking operations in the Qt main thread or in msquic callbacks
- **NO** tinycbor dependency — use Qt's built-in `QCborStreamWriter`/`QCborStreamReader` (Qt 6 has native CBOR support)

---

## Verification Strategy

> **UNIVERSAL RULE: ZERO HUMAN INTERVENTION**
>
> ALL tasks are verifiable WITHOUT any human action.

### Test Decision
- **Infrastructure exists**: YES (QGC has its own test framework based on QTest/GTest)
- **Automated tests**: YES (tests after implementation)
- **Framework**: QTest (Qt 6) for unit tests, GTest where QGC uses it

### Agent-Executed QA Scenarios (MANDATORY — ALL tasks)

Every task includes specific agent-executable QA scenarios using Bash (CMake build, ctest, Python mock server).

**Verification Tool by Deliverable Type:**

| Type | Tool | How Agent Verifies |
|------|------|-------------------|
| Build/Compile | Bash (cmake --build) | Build succeeds with msquic linked |
| Link Type Registration | Bash (grep/ctest) | TypeQuic appears in enum, factory returns QUICLink |
| QUIC Connection | Bash (mock server + QGC headless) | AUTH_OK received, frames relayed |
| Unit Tests | Bash (ctest) | All test assertions pass |
| QML UI | Playwright (if needed) | Settings panel loads, fields editable |

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately):
├── Task 1: msquic build integration (CMake + Android NDK)
├── Task 3: Frame decoder + priority classifier (standalone, no deps)
└── Task 5: CBOR control protocol handler (standalone, Qt CBOR only)

Wave 2 (After Wave 1):
├── Task 2: QUICLink + QUICLinkConfiguration skeleton (depends: Task 1 for msquic linkage)
├── Task 4: msquic QUIC client wrapper (depends: Task 1 for msquic build)
└── Task 7: QML settings UI (depends: Task 2 for configuration class)

Wave 3 (After Wave 2):
├── Task 6: Full relay integration wiring (depends: Tasks 2, 3, 4, 5)
└── Task 8: Reconnection + VEHICLE_OFFLINE handling (depends: Task 6)

Wave 4 (After Wave 3):
└── Task 9: Tests — QTest unit + integration (depends: Tasks 6, 8)

Critical Path: Task 1 → Task 4 → Task 6 → Task 9
Parallel Speedup: ~40% faster than sequential
```

### Dependency Matrix

| Task | Depends On | Blocks | Can Parallelize With |
|------|------------|--------|---------------------|
| 1 | None | 2, 4 | 3, 5 |
| 2 | 1 | 6, 7 | 3, 4, 5 |
| 3 | None | 6 | 1, 2, 4, 5, 7 |
| 4 | 1 | 6 | 2, 3, 5, 7 |
| 5 | None | 6 | 1, 2, 3, 4, 7 |
| 6 | 2, 3, 4, 5 | 8, 9 | 7 |
| 7 | 2 | 9 | 3, 4, 5, 6, 8 |
| 8 | 6 | 9 | 7 |
| 9 | 6, 8 | None | 7 |

### Agent Dispatch Summary

| Wave | Tasks | Recommended Agents |
|------|-------|-------------------|
| 1 | 1, 3, 5 | task(category="deep") for msquic CMake; task(category="quick") for decoder+classifier; task(category="quick") for control protocol |
| 2 | 2, 4, 7 | task(category="unspecified-high") for QUICLink skeleton; task(category="deep") for msquic client; task(category="visual-engineering", load_skills=["frontend-ui-ux"]) for QML |
| 3 | 6, 8 | task(category="deep") for relay integration; task(category="unspecified-high") for reconnection |
| 4 | 9 | task(category="unspecified-high") for tests |

---

## TODOs

- [ ] 1. Integrate msquic into QGC CMake build system (desktop + Android NDK)

  **What to do**:
  - Add msquic as a dependency to QGC's CMake build:
    - **Option A (preferred for desktop)**: System-installed msquic via `find_package(msquic)` or `find_library(MSQUIC_LIB msquic)` + `find_path(MSQUIC_INCLUDE msquic.h)`
    - **Option B (preferred for Android + fallback)**: `FetchContent` to download and build msquic from source:
      ```cmake
      include(FetchContent)
      FetchContent_Declare(
        msquic
        GIT_REPOSITORY https://github.com/microsoft/msquic.git
        GIT_TAG v2.4.5  # pin to stable release
        GIT_SHALLOW TRUE
      )
      set(QUIC_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
      set(QUIC_BUILD_TEST OFF CACHE BOOL "" FORCE)
      set(QUIC_BUILD_PERF OFF CACHE BOOL "" FORCE)
      FetchContent_MakeAvailable(msquic)
      ```
    - Create `cmake/FindMsQuic.cmake` module for Option A
    - Add CMake option: `option(QGC_ENABLE_QUIC "Enable QUIC link type" ON)`
    - When `QGC_ENABLE_QUIC=ON`:
      - Link against `msquic` target
      - Add compile definition `QGC_QUIC_ENABLED`
      - Add new source files to the comm target (placeholder .h/.cc files with empty classes)
    - For Android NDK cross-compilation:
      - msquic CMake supports Android NDK toolchain natively
      - Set `CMAKE_ANDROID_NDK`, `CMAKE_ANDROID_API=26`, `CMAKE_ANDROID_ARCH_ABI=arm64-v8a`
      - Verify msquic builds for Android ARM64 within QGC's existing Android build pipeline
  - Create placeholder files (empty classes, just enough to compile):
    - `src/Comms/QUICLink.h` — empty `QUICLink` class inheriting `LinkInterface`
    - `src/Comms/QUICLink.cc` — empty implementation
  - Verify: `cmake --build build/` succeeds with msquic linked, QGC launches

  **Must NOT do**:
  - Do NOT implement any QUIC logic — just verify build integration
  - Do NOT modify any existing link types
  - Do NOT add Android build verification if the user's build pipeline isn't available — document the expected NDK flags instead

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: CMake build system integration across desktop + Android NDK with external C library; requires understanding QGC's CMake structure and msquic's build options
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `frontend-ui-ux`: No UI in this task
    - `playwright`: No browser testing

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 3, 5)
  - **Blocks**: Tasks 2, 4
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References** (existing code to follow):
  - QGC's existing `CMakeLists.txt` — how other libraries are linked (look for `find_package` patterns, the comm target name, how source files are added)
  - QGC's Android build setup — look for existing `CMAKE_ANDROID_*` variables and NDK toolchain usage

  **API/Type References**:
  - msquic CMake target: `msquic` (when built via FetchContent) or `msquic::msquic` (when installed)
  - msquic header: `#include <msquic.h>` — single header API
  - msquic build options: https://github.com/microsoft/msquic/blob/main/CMakeLists.txt — `QUIC_BUILD_TOOLS`, `QUIC_BUILD_TEST`, etc.

  **External References**:
  - msquic build docs: https://github.com/microsoft/msquic/blob/main/docs/BUILD.md
  - msquic CMake integration: https://github.com/microsoft/msquic/blob/main/docs/cmake.md (if exists) or inspect their CMakeLists.txt
  - QGC build docs for Qt 6: check QGC repo README or docs/ for build instructions

  **WHY Each Reference Matters**:
  - QGC's CMakeLists.txt structure is essential — msquic must integrate without breaking existing build
  - Android NDK flags in QGC's build tell you how to pass them through to msquic's sub-build

  **Acceptance Criteria**:

  - [ ] `cmake -B build -DQGC_ENABLE_QUIC=ON` configures successfully, finds msquic
  - [ ] `cmake --build build/` compiles QGC with msquic linked (no linker errors)
  - [ ] `grep -r "QGC_QUIC_ENABLED" build/` shows the compile definition is set
  - [ ] Placeholder `QUICLink.h` includes `<msquic.h>` without errors
  - [ ] QGC executable launches and runs (QUIC link type not yet functional — just build verification)

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: QGC builds with msquic enabled
    Tool: Bash
    Preconditions: Qt 6.6.3 SDK available, QGC source checked out
    Steps:
      1. cmake -B build -DQGC_ENABLE_QUIC=ON 2>&1
      2. Assert: output contains "msquic" found/fetched
      3. Assert: exit code 0
      4. cmake --build build/ -j$(nproc) 2>&1
      5. Assert: exit code 0
      6. Assert: no "undefined reference" errors for msquic symbols
    Expected Result: Clean build with msquic
    Evidence: CMake + build output captured

  Scenario: QGC builds with QUIC disabled (no regression)
    Tool: Bash
    Steps:
      1. cmake -B build-noquic -DQGC_ENABLE_QUIC=OFF 2>&1
      2. cmake --build build-noquic/ -j$(nproc)
      3. Assert: exit code 0, no msquic references
    Expected Result: Existing build unaffected when QUIC disabled
    Evidence: Build output captured
  ```

  **Commit**: YES
  - Message: `build(gcs): integrate msquic into QGC CMake build system`
  - Files: `cmake/FindMsQuic.cmake`, `CMakeLists.txt` (updated), `src/Comms/QUICLink.h`, `src/Comms/QUICLink.cc`
  - Pre-commit: `cmake --build build/`

---

- [ ] 2. Implement QUICLink and QUICLinkConfiguration skeleton

  **What to do**:
  - Implement `QUICLinkConfiguration` in `src/Comms/QUICLinkConfiguration.h/.cc`:
    - Extend `LinkConfiguration` (follow pattern of `UDPConfiguration` or `TCPConfiguration`)
    - Fields:
      - `QString _serverHost` (default: `""`)
      - `quint16 _serverPort` (default: `14550`)
      - `QByteArray _authToken` (raw 16 bytes)
      - `int _vehicleId` (default: `1`)
      - `QString _gcsId` (auto-generated UUID if empty)
      - `QString _caCertPath` (default: `""`)
      - `bool _autoSubscribe` (default: `true` — subscribe immediately after AUTH_OK)
    - Override methods:
      - `type()` → `LinkConfiguration::TypeQuic`
      - `copyFrom(LinkConfiguration*)` — copy QUIC-specific fields
      - `saveSettings(QSettings&, const QString& root)` — serialize all QUIC fields
      - `loadSettings(QSettings&, const QString& root)` — deserialize
      - `settingsURL()` → QML path to QUIC settings component
      - `settingsTitle()` → `"QUIC Link"`
      - `isAutoConnectAllowed()` → `true`
      - `isHighLatencyAllowed()` → `true`

  - Add `TypeQuic` to `LinkConfiguration` enum in `LinkConfiguration.h`:
    - Add `TypeQuic` after the last existing type
    - Guard with `#ifdef QGC_QUIC_ENABLED` / `#endif`

  - Implement `QUICLink` skeleton in `src/Comms/QUICLink.h/.cc`:
    - Extend `LinkInterface`
    - Override:
      - `_connect()` → stub returning `true` (actual connection in Task 4/6)
      - `_disconnect()` → stub
      - `_writeBytes(QByteArray)` → stub (log and discard)
      - `isConnected()` → `_connected` member
      - `isSecure()` → `true` (TLS 1.3)
      - `getBytes()` → return bytes received counter
    - Signals: standard `bytesReceived`, `bytesSent`, `connected`, `disconnected`, `communicationError`
    - Thread: `QUICLink` runs in its own `QThread` (following `UDPLink` pattern)

  - Register in `LinkManager`:
    - In `LinkManager::_createLink()` or equivalent factory method, add `case TypeQuic:` → create `QUICLink`
    - In `LinkManager::_createConfiguration()`, add `case TypeQuic:` → create `QUICLinkConfiguration`
    - Guard all QUIC code with `#ifdef QGC_QUIC_ENABLED`

  **Must NOT do**:
  - Do NOT implement msquic connection logic — that's Task 4
  - Do NOT implement relay logic — that's Task 6
  - Do NOT create QML settings UI — that's Task 7
  - Do NOT modify any existing link type implementations

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Requires understanding QGC's LinkInterface architecture, inheritance patterns, and LinkManager factory — moderately complex integration
  - **Skills**: []
  - **Skills Evaluated but Omitted**:
    - `frontend-ui-ux`: No UI in this task
    - `playwright`: No browser

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 4, 7)
  - **Blocks**: Tasks 6, 7
  - **Blocked By**: Task 1

  **References**:

  **Pattern References** (existing code to follow):
  - `src/Comms/UDPLink.h/.cc` — worker thread pattern, `QMetaObject::invokeMethod` for thread safety, `_writeBytes` and `bytesReceived` usage. **This is the primary pattern to follow.**
  - `src/Comms/TCPLink.h/.cc` — simpler client-side link (no server), relevant for connect/disconnect lifecycle
  - `src/Comms/LinkConfiguration.h` — `TypeSerial, TypeUdp, TypeTcp, ...` enum, `saveSettings()` / `loadSettings()` virtual methods, `settingsURL()` pattern
  - `src/Comms/LinkManager.h/.cc` — `_createLink()` factory switch, `createConnectedLink()` lifecycle, `_rgLinks` list

  **API/Type References**:
  - `LinkInterface` virtuals: `_connect()`, `_disconnect()`, `_writeBytes(QByteArray)`, `isConnected()`, `bytesReceived(LinkInterface*, QByteArray)` signal
  - `writeBytesThreadSafe()` — routes from any thread to link thread via `QMetaObject::invokeMethod`
  - `LinkConfiguration` virtuals: `type()`, `copyFrom()`, `saveSettings()`, `loadSettings()`, `settingsURL()`, `settingsTitle()`

  **External References**:
  - QGC upstream `LinkInterface.h`: https://github.com/mavlink/qgroundcontrol/blob/master/src/Comms/LinkInterface.h
  - QGC upstream `LinkManager.cc`: https://github.com/mavlink/qgroundcontrol/blob/master/src/Comms/LinkManager.cc — factory pattern reference

  **WHY Each Reference Matters**:
  - UDPLink is the closest analog: both are UDP-based transport (QUIC runs over UDP), both need worker threads, both handle `_writeBytes` → network send
  - LinkConfiguration save/load pattern is critical for settings persistence — QGC will crash if these aren't implemented correctly
  - LinkManager factory is the entry point — without registering TypeQuic there, QGC can never create a QUIC link

  **Acceptance Criteria**:

  - [ ] `LinkConfiguration::TypeQuic` exists and compiles
  - [ ] `QUICLinkConfiguration` saves/loads settings via QSettings without crash
  - [ ] `QUICLink` inherits `LinkInterface`, compiles, and all virtual overrides are present
  - [ ] `LinkManager` factory recognizes `TypeQuic` and creates `QUICLink` instance
  - [ ] `cmake --build build/` succeeds with all new files
  - [ ] Existing link types (UDP, TCP, Serial) still work — no regressions

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: QUICLink builds and registers in LinkManager
    Tool: Bash
    Preconditions: QGC built with QGC_ENABLE_QUIC=ON
    Steps:
      1. cmake --build build/ 2>&1
      2. Assert: exit code 0
      3. Assert: QUICLink.cc compiled (appears in build log)
      4. grep -rn "TypeQuic" src/Comms/LinkConfiguration.h
      5. Assert: TypeQuic enum value exists
    Expected Result: QUIC link type registered
    Evidence: Build output + grep results

  Scenario: LinkConfiguration save/load roundtrip
    Tool: Bash
    Preconditions: Built, test binary available
    Steps:
      1. Run unit test (from Task 9) or inline test that:
         - Creates QUICLinkConfiguration
         - Sets serverHost="test.example.com", serverPort=5000, vehicleId=42
         - Saves to QSettings (in-memory)
         - Creates new QUICLinkConfiguration
         - Loads from same QSettings
         - Asserts: host, port, vehicleId match
      2. Assert: all assertions pass
    Expected Result: Settings persist correctly
    Evidence: Test output captured
  ```

  **Commit**: YES
  - Message: `feat(gcs): add QUICLink and QUICLinkConfiguration skeleton with LinkManager registration`
  - Files: `src/Comms/QUICLink.h`, `src/Comms/QUICLink.cc`, `src/Comms/QUICLinkConfiguration.h`, `src/Comms/QUICLinkConfiguration.cc`, `src/Comms/LinkConfiguration.h` (updated), `src/Comms/LinkManager.h` (updated), `src/Comms/LinkManager.cc` (updated)
  - Pre-commit: `cmake --build build/`

---

- [ ] 3. Implement frame decoder and priority classifier (standalone modules)

  **What to do**:
  - Create `src/Comms/QUICFrameDecoder.h/.cc`:
    - `class QUICFrameDecoder`:
      - `QVector<QByteArray> feed(const QByteArray& data)` — accumulate bytes, return complete frames
      - Internal state: `QByteArray _buffer` for accumulation
      - Wire format: `[u16_le length][length bytes of payload]`
      - Handles: partial frames across calls, multiple frames in one call, partial length prefix
      - Validates: frame length > 0, frame length ≤ 65535
      - Static utility: `static QByteArray encodeFrame(const QByteArray& payload)` — wrap in length prefix
    - **MUST match** exactly the framing in Jetson and Server plans (little-endian u16)

  - Create `src/Comms/QUICPriorityClassifier.h/.cc`:
    - `enum class QUICStreamType { Priority, Bulk };`
    - `class QUICPriorityClassifier`:
      - Constructor: `QUICPriorityClassifier()` — initializes default high-priority msgid set
      - `QUICStreamType classify(uint32_t msgid) const` — O(1) lookup
      - `static uint32_t extractMsgId(const QByteArray& mavlinkFrame)` — extract msgid from MAVLink header bytes:
        - MAVLink v1 (magic 0xFE): msgid at byte offset 5 (1 byte)
        - MAVLink v2 (magic 0xFD): msgid at byte offset 7 (3 bytes, little-endian u24)
      - Uses `QSet<uint32_t>` for O(1) lookup of the 18 high-priority msgids
    - Same 18-entry priority table as Jetson plan (see table above)
    - These are standalone modules — no msquic, no Qt network, no QGC dependencies beyond Qt Core

  **Must NOT do**:
  - Do NOT include msquic headers — standalone Qt Core only
  - Do NOT include QGC-specific headers (LinkInterface etc.)
  - Do NOT validate MAVLink CRC or parse beyond msgid extraction
  - Do NOT add CBOR logic — that's Task 5

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Simple byte-level utilities with no external dependencies beyond Qt Core
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 5)
  - **Blocks**: Task 6
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - Jetson plan priority classifier (Task 4): same msgid table, same classification logic — MUST produce identical results
  - Server plan framing (Task 3): same `[u16_le length][payload]` format — MUST be wire-compatible
  - MAVLink packet format: https://mavlink.io/en/guide/serialization.html — byte offsets for msgid

  **API/Type References**:
  - `qFromLittleEndian<quint16>(data)` — Qt endian conversion for reading u16_le length
  - `qToLittleEndian<quint16>(len)` — Qt endian conversion for writing u16_le length
  - `QByteArray::mid(offset, length)` — extract sub-array

  **External References**:
  - MAVLink v1 format: magic(1) + len(1) + seq(1) + sysid(1) + compid(1) + **msgid(1)** + payload + crc(2)
  - MAVLink v2 format: magic(1) + len(1) + incompat(1) + compat(1) + seq(1) + sysid(1) + compid(1) + **msgid(3 LE)** + payload + crc(2) + sig(13)?

  **WHY Each Reference Matters**:
  - Wire compatibility is critical — if frame encoding differs between Jetson, Server, and GCS, the entire system breaks
  - MAVLink header offsets are exact — msgid extraction must handle both v1 and v2 format

  **Acceptance Criteria**:

  - [ ] `QUICFrameDecoder().feed(encoded_frame)` returns original payload
  - [ ] `QUICFrameDecoder::encodeFrame(payload)` prepends correct u16_le length
  - [ ] Partial frame accumulation works (1 byte at a time)
  - [ ] Multiple frames in single `feed()` call returns all complete frames
  - [ ] `QUICPriorityClassifier().classify(0)` returns `Priority` (HEARTBEAT)
  - [ ] `QUICPriorityClassifier().classify(76)` returns `Priority` (COMMAND_LONG)
  - [ ] `QUICPriorityClassifier().classify(30)` returns `Bulk` (ATTITUDE)
  - [ ] `extractMsgId()` works for both MAVLink v1 (0xFE) and v2 (0xFD) frames
  - [ ] No msquic or QGC-specific includes

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Frame encoder/decoder roundtrip
    Tool: Bash
    Preconditions: Built
    Steps:
      1. ctest --test-dir build -R QUICFrameDecoder
      2. Assert: all tests pass
      3. Assert: encode→decode roundtrip produces original payload
      4. Assert: partial feed accumulates correctly
    Expected Result: All framing tests pass
    Evidence: ctest output captured

  Scenario: Priority classification matches Jetson plan
    Tool: Bash
    Steps:
      1. ctest --test-dir build -R QUICPriorityClassifier
      2. Assert: all 18 priority msgids classify as Priority
      3. Assert: ATTITUDE(30), GPS_RAW_INT(24) classify as Bulk
      4. Assert: unknown msgid(65535) classifies as Bulk
    Expected Result: Classification identical to Jetson plan
    Evidence: ctest output captured
  ```

  **Commit**: YES
  - Message: `feat(gcs): add QUIC frame decoder and MAVLink priority classifier`
  - Files: `src/Comms/QUICFrameDecoder.h`, `src/Comms/QUICFrameDecoder.cc`, `src/Comms/QUICPriorityClassifier.h`, `src/Comms/QUICPriorityClassifier.cc`
  - Pre-commit: `cmake --build build/`

---

- [ ] 4. Implement msquic QUIC client wrapper class

  **What to do**:
  - Create `src/Comms/QUICClient.h/.cc` — msquic wrapper for GCS client:
    - `class QUICClient : public QObject`:
      - Uses Q_OBJECT for signal/slot threading
      - **Initialization**: `MsQuicOpen2()` → `Registration` → `Configuration`:
        - ALPN: `"mavlink-quic-v1"`
        - TLS: one-way server cert validation, load CA cert from path
        - Settings: `KeepAliveIntervalMs = 15000`, `IdleTimeoutMs = 60000`
        - `PeerBidiStreamCount = 0` (GCS does not accept server-initiated streams in this protocol)
      - **Connect**: `ConnectionOpen()` + `ConnectionStart(host, port)`
      - **Stream management**: Open 3 client-initiated bidirectional streams after handshake:
        - Track by open order: first = control (stream 0), second = priority (stream 4), third = bulk (stream 8)
      - **Send interface**:
        - `void sendControl(const QByteArray& cborData)` — send on control stream with length prefix
        - `void sendPriority(const QByteArray& mavlinkFrame)` — send on priority stream with length prefix
        - `void sendBulk(const QByteArray& mavlinkFrame)` — send on bulk stream with length prefix
        - Uses `StreamSend()` with RAII buffer wrapper (`SendBuffer` struct, freed on `SEND_COMPLETE`)
      - **Receive**: msquic `STREAM_RECEIVE` callback fires on msquic worker thread:
        - Must bridge to Qt thread via `QMetaObject::invokeMethod(this, [=]{ ... }, Qt::QueuedConnection)`
        - Emits signals: `controlDataReceived(QByteArray)`, `priorityDataReceived(QByteArray)`, `bulkDataReceived(QByteArray)`
      - **Connection events** (emitted as Qt signals):
        - `connected()` — handshake complete
        - `disconnected(quint64 errorCode, QString reason)` — connection terminated
        - `connectionFailed(QString reason)` — failed to connect
      - **Shutdown**: `ConnectionShutdown(QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0)` → wait for `SHUTDOWN_COMPLETE` → cleanup
      - **Buffer lifecycle** (same pattern as Jetson plan):
        ```cpp
        struct SendBuffer {
            QUIC_BUFFER quicBuf;
            QByteArray data;  // owns the bytes
        };
        ```
        - Allocated on send, freed on `SEND_COMPLETE` callback
        - Track pending sends, free all on shutdown

    - **Static callbacks** (msquic C-style):
      - `static QUIC_STATUS connectionCallback(HQUIC, void* context, QUIC_CONNECTION_EVENT*)`
      - `static QUIC_STATUS streamCallback(HQUIC, void* context, QUIC_STREAM_EVENT*)`
      - Cast `context` pointer to `QUICClient*`, dispatch to member methods
      - **NEVER do Qt operations in these callbacks** — use invokeMethod

  **Must NOT do**:
  - Do NOT implement AUTH/SUBSCRIBE logic — that's Task 5/6
  - Do NOT implement reconnection — that's Task 8
  - Do NOT block in msquic callbacks
  - Do NOT call Qt GUI or QGC methods from msquic threads
  - Do NOT implement priority classification — that's Task 3

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Novel integration of msquic C API with Qt C++ threading model; requires careful understanding of msquic callback model, buffer ownership, and Qt thread safety
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 2, 7)
  - **Blocks**: Task 6
  - **Blocked By**: Task 1

  **References**:

  **Pattern References**:
  - Jetson plan Task 2 (`QuicClient`): Same msquic wrapper pattern — buffer lifecycle, stream management, callback model. **Follow the same design, adapted for Qt signals instead of ROS publishers.**
  - msquic sample client: https://github.com/microsoft/msquic/blob/main/src/tools/sample/sample.c — canonical connection lifecycle
  - QGC `UDPLink` worker thread: `src/Comms/UDPLink.cc` — how QGC handles network I/O in a worker thread

  **API/Type References**:
  - msquic: `MsQuicOpen2()`, `ConnectionOpen()`, `ConnectionStart()`, `StreamOpen()`, `StreamStart()`, `StreamSend()`, `StreamReceiveComplete()`
  - msquic events: `QUIC_CONNECTION_EVENT_CONNECTED`, `QUIC_STREAM_EVENT_RECEIVE`, `QUIC_STREAM_EVENT_SEND_COMPLETE`, `QUIC_CONNECTION_EVENT_SHUTDOWN_COMPLETE`
  - Qt: `QMetaObject::invokeMethod(obj, lambda, Qt::QueuedConnection)` for thread-safe bridging
  - Qt: `QByteArray` for buffer management

  **External References**:
  - msquic API docs: https://github.com/microsoft/msquic/blob/main/docs/API.md
  - msquic settings: https://github.com/microsoft/msquic/blob/main/docs/Settings.md
  - msquic TLS configuration: https://github.com/microsoft/msquic/blob/main/docs/TLS.md

  **WHY Each Reference Matters**:
  - Jetson plan Task 2 is the sibling implementation — same msquic API, same protocol. The GCS wrapper differs only in using Qt signals instead of ROS publishers.
  - msquic sample client is the canonical lifecycle example — follow it exactly for connection/stream/shutdown ordering
  - UDPLink shows how QGC bridges between network threads and the Qt event loop — copy this pattern

  **Acceptance Criteria**:

  - [ ] `QUICClient` compiles as part of QGC build
  - [ ] Can be instantiated with host, port, token, caCertPath parameters
  - [ ] `connectToServer()` attempts QUIC handshake (may fail without server — OK for this task)
  - [ ] `shutdown()` cleans up all msquic resources without leaks or crashes
  - [ ] `connected()`, `disconnected()`, `connectionFailed()` signals emit correctly
  - [ ] Receive callbacks bridge to Qt thread via `invokeMethod(Qt::QueuedConnection)`
  - [ ] No compiler warnings

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: QUICClient compiles and links
    Tool: Bash
    Preconditions: QGC built with QGC_ENABLE_QUIC=ON
    Steps:
      1. cmake --build build/ 2>&1
      2. Assert: exit code 0
      3. Assert: QUICClient.cc compiled successfully
      4. Assert: no "undefined reference" for msquic symbols
    Expected Result: Clean build
    Evidence: Build output captured

  Scenario: QUICClient lifecycle without crash
    Tool: Bash
    Preconditions: Built
    Steps:
      1. Run unit test: create QUICClient, connect (expect fail), shutdown
      2. Assert: no segfault, no ASAN violations
      3. Assert: connectionFailed signal emitted
    Expected Result: Clean lifecycle even without server
    Evidence: Test output captured
  ```

  **Commit**: YES
  - Message: `feat(gcs): implement msquic QUIC client wrapper with Qt signal bridging`
  - Files: `src/Comms/QUICClient.h`, `src/Comms/QUICClient.cc`
  - Pre-commit: `cmake --build build/`

---

- [ ] 5. Implement CBOR control protocol handler (Qt native CBOR)

  **What to do**:
  - Create `src/Comms/QUICControlProtocol.h/.cc`:
    - Uses Qt 6 native CBOR: `QCborStreamWriter` / `QCborStreamReader` / `QCborMap` / `QCborValue`
    - **Encoding functions**:
      - `static QByteArray encodeAuth(const QByteArray& token, const QString& gcsId)`:
        - Returns CBOR map: `{"type": "AUTH", "token": <bytes>, "role": "gcs", "gcs_id": <str>}`
      - `static QByteArray encodeSubscribe(int vehicleId)`:
        - Returns CBOR map: `{"type": "SUBSCRIBE", "vehicle_id": <int>}`
      - `static QByteArray encodePong(double ts)`:
        - Returns CBOR map: `{"type": "PONG", "ts": <float>}`
    - **Decoding**:
      - `struct ControlMessage`:
        ```cpp
        struct ControlMessage {
            QString type;            // "AUTH_OK", "AUTH_FAIL", "SUB_OK", etc.
            QString reason;          // for AUTH_FAIL, SUB_FAIL
            int vehicleId = 0;       // for SUB_OK, SUB_FAIL, VEHICLE_OFFLINE
            double ts = 0.0;         // for PING
        };
        ```
      - `static ControlMessage decode(const QByteArray& cborData)`:
        - CBOR decode → populate ControlMessage fields
        - Unknown message types: log warning, return with type set to "UNKNOWN"
    - **MUST match** CBOR encoding from Server plan and Jetson plan:
      - Same field names: "type", "token", "role", "gcs_id", "vehicle_id", "ts", "reason"
      - Same CBOR data types: strings for type/role/gcs_id/reason, int for vehicle_id, float64 for ts, bytes for token

  **Must NOT do**:
  - Do NOT add third-party CBOR library — use Qt 6 built-in `QCborValue` / `QCborMap`
  - Do NOT include msquic or network headers — standalone Qt Core
  - Do NOT implement connection logic — just encode/decode control messages
  - Do NOT include framing — frame encoding is in QUICFrameDecoder (Task 3)

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: Straightforward CBOR serialization with well-documented Qt 6 CBOR API
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1 (with Tasks 1, 3)
  - **Blocks**: Task 6
  - **Blocked By**: None (can start immediately)

  **References**:

  **Pattern References**:
  - Server plan control message formats (Context section): exact field names and types for each message
  - Jetson plan Task 2: AUTH message encoding — same fields (but role="vehicle" vs role="gcs")

  **API/Type References**:
  - `QCborMap` — construct CBOR maps: `QCborMap({{"type", "AUTH"}, {"token", QCborValue(tokenBytes)}, ...})`
  - `QCborValue::fromCbor(QByteArray)` — decode CBOR bytes to `QCborValue`
  - `QCborValue::toMap()` — get map from decoded value
  - `QCborMap::value(key)` — get field value

  **External References**:
  - Qt 6 CBOR docs: https://doc.qt.io/qt-6/qcborvalue.html
  - Qt 6 QCborMap: https://doc.qt.io/qt-6/qcbormap.html

  **Cross-Plan Consistency** (CRITICAL):
  - Jetson sends AUTH with tinycbor/nlohmann — GCS sends AUTH with Qt CBOR. Both MUST produce wire-compatible CBOR.
  - Server decodes with Python cbor2. All 3 encoders must produce compatible CBOR maps.
  - CBOR is a well-defined standard — as long as all use standard CBOR map encoding, compatibility is guaranteed.

  **Acceptance Criteria**:

  - [ ] `encodeAuth(token, "gcs-1")` produces valid CBOR decodable by Python `cbor2.loads()`
  - [ ] `encodeSubscribe(42)` produces `{"type": "SUBSCRIBE", "vehicle_id": 42}` in CBOR
  - [ ] `decode()` correctly parses AUTH_OK, AUTH_FAIL, SUB_OK, SUB_FAIL, PING, VEHICLE_OFFLINE
  - [ ] Unknown message type → `type == "UNKNOWN"`, no crash
  - [ ] No third-party CBOR library used — only Qt 6 built-in
  - [ ] CBOR output is wire-compatible with Python `cbor2` and C `tinycbor` (standard CBOR)

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: CBOR encode/decode roundtrip
    Tool: Bash
    Steps:
      1. ctest --test-dir build -R QUICControlProtocol
      2. Assert: AUTH encode → decode produces matching fields
      3. Assert: SUBSCRIBE encode → decode produces matching vehicleId
      4. Assert: PONG encode → decode preserves timestamp
    Expected Result: All control protocol tests pass
    Evidence: ctest output captured

  Scenario: Cross-language CBOR compatibility
    Tool: Bash
    Steps:
      1. Run C++ test that encodes AUTH to binary file
      2. Run Python one-liner: python3 -c "import cbor2; msg = cbor2.loads(open('auth.cbor','rb').read()); assert msg['type'] == 'AUTH'; assert msg['role'] == 'gcs'; print('COMPAT OK')"
      3. Assert: Python decodes C++ CBOR successfully
    Expected Result: Wire-compatible CBOR across C++ and Python
    Evidence: Python output captured
  ```

  **Commit**: YES
  - Message: `feat(gcs): add CBOR control protocol handler using Qt native CBOR`
  - Files: `src/Comms/QUICControlProtocol.h`, `src/Comms/QUICControlProtocol.cc`
  - Pre-commit: `cmake --build build/`

---

- [ ] 6. Wire up full bidirectional relay integration

  **What to do**:
  - Update `QUICLink` to compose all components and implement the full relay:
    - **Members**:
      - `QUICClient* _client`
      - `QUICFrameDecoder _controlDecoder, _priorityDecoder, _bulkDecoder` (one per stream)
      - `QUICPriorityClassifier _classifier`
      - `QUICControlProtocol` (static methods, no instance needed)
    - **Connection state machine**:
      ```
      DISCONNECTED → CONNECTING → AUTHENTICATING → SUBSCRIBING → CONNECTED → DISCONNECTED
                       ↑                                                        │
                       └──────────────── (reconnect, Task 8) ──────────────────┘
      ```
    - **`_connect()` implementation** (called by LinkManager):
      1. Create `QUICClient` with config params
      2. Connect signals: `connected → _onConnected`, `disconnected → _onDisconnected`, `controlDataReceived → _onControlData`, `priorityDataReceived → _onPriorityData`, `bulkDataReceived → _onBulkData`
      3. Call `_client->connectToServer(host, port)`
      4. Set state = CONNECTING

    - **`_onConnected()` slot**:
      1. Set state = AUTHENTICATING
      2. Build AUTH message: `QUICControlProtocol::encodeAuth(token, gcsId)`
      3. Wrap in frame: `QUICFrameDecoder::encodeFrame(authCbor)`
      4. Send on control stream: `_client->sendControl(framedAuth)`

    - **`_onControlData(QByteArray data)` slot**:
      1. Feed to `_controlDecoder.feed(data)` → get complete frames
      2. For each frame: `QUICControlProtocol::decode(frame)` → `ControlMessage`
      3. Dispatch by type:
         - `AUTH_OK`: Set state = SUBSCRIBING. If autoSubscribe: send SUBSCRIBE.
         - `AUTH_FAIL`: Log error, set state = DISCONNECTED, emit `communicationError`
         - `SUB_OK`: Set state = CONNECTED. Emit `connected`. Log "Subscribed to vehicle {id}"
         - `SUB_FAIL`: Log error, emit `communicationError`
         - `PING`: Send PONG with same timestamp: `_client->sendControl(encodeFrame(encodePong(msg.ts)))`
         - `VEHICLE_OFFLINE`: Log "Vehicle {id} went offline", emit `communicationError("Vehicle offline")`

    - **`_onPriorityData(QByteArray data)` / `_onBulkData(QByteArray data)` slots** (inbound relay):
      1. Feed to appropriate `_decoder.feed(data)` → complete MAVLink frames
      2. For each frame: `emit bytesReceived(this, frame)`
         - This triggers QGC's `MAVLinkProtocol::receiveBytes()` → all standard QGC functionality works
      3. Update byte counter

    - **`_writeBytes(QByteArray data)` override** (outbound relay):
      1. Extract msgid from MAVLink header: `QUICPriorityClassifier::extractMsgId(data)`
      2. Classify: `_classifier.classify(msgid)` → Priority or Bulk
      3. Wrap in frame: `QUICFrameDecoder::encodeFrame(data)`
      4. Route: `_client->sendPriority(frame)` or `_client->sendBulk(frame)`
      5. Update byte counter

    - **`_disconnect()` implementation**:
      1. Set state = DISCONNECTED
      2. `_client->shutdown()`
      3. Emit `disconnected()`

  **Must NOT do**:
  - Do NOT implement reconnection — that's Task 8. For now, on disconnect: log and stay disconnected.
  - Do NOT parse MAVLink content beyond msgid extraction
  - Do NOT modify MAVLinkProtocol.h/.cc
  - Do NOT add any filtering or routing logic beyond priority classification

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: Core integration task combining 4 components (QUICClient, FrameDecoder, PriorityClassifier, ControlProtocol) with state machine, Qt signals/slots, and QGC LinkInterface integration
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 3 (sequential — depends on Tasks 2, 3, 4, 5)
  - **Blocks**: Tasks 8, 9
  - **Blocked By**: Tasks 2, 3, 4, 5

  **References**:

  **Pattern References**:
  - Jetson plan Task 5 (relay integration): Same conceptual design — compose client + classifier + framing. Adapt for Qt signals instead of ROS pub/sub.
  - `UDPLink::_writeBytes()` in `src/Comms/UDPLink.cc` — how QGC handles outbound bytes in an existing link. Follow this pattern for `_writeBytes`.
  - `UDPLink::_readBytes()` or similar — how `bytesReceived(this, data)` is emitted. Follow this for inbound path.

  **API/Type References**:
  - `QUICClient` from Task 4 — `sendControl()`, `sendPriority()`, `sendBulk()`, signals
  - `QUICFrameDecoder` from Task 3 — `feed()`, `encodeFrame()`
  - `QUICPriorityClassifier` from Task 3 — `classify()`, `extractMsgId()`
  - `QUICControlProtocol` from Task 5 — `encodeAuth()`, `encodeSubscribe()`, `encodePong()`, `decode()`
  - `LinkInterface::bytesReceived` signal — emitting this makes QGC's MAVLink parsing work

  **Cross-Plan Consistency** (CRITICAL):
  - AUTH message must use role="gcs" (not "vehicle"). Server validates role.
  - SUBSCRIBE must be sent AFTER AUTH_OK (server rejects SUBSCRIBE before auth)
  - Frame encoding `[u16_le len][payload]` on all streams — must match Server expectation
  - PONG response to server PING must include original `ts` value

  **Acceptance Criteria**:

  - [ ] Creating QUIC link → connects to server → AUTH_OK → SUB_OK → state == CONNECTED
  - [ ] Telemetry from vehicle appears: frames arrive via `bytesReceived` → QGC parses MAVLink → vehicle appears in QGC vehicle list
  - [ ] Commands from QGC: `_writeBytes()` called → classified → sent on correct stream → arrives at server
  - [ ] HEARTBEAT (msgid=0) → sent on priority stream (4)
  - [ ] ATTITUDE (msgid=30) → sent on bulk stream (8)
  - [ ] Server PING → PONG response sent
  - [ ] AUTH_FAIL → `communicationError` signal, state = DISCONNECTED
  - [ ] VEHICLE_OFFLINE → `communicationError` signal with "Vehicle offline" message
  - [ ] `_disconnect()` → clean QUIC shutdown, state = DISCONNECTED

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Full AUTH + SUBSCRIBE + relay via mock server
    Tool: Bash
    Preconditions: Python mock server (from server plan test infrastructure) running on localhost:14550
    Steps:
      1. Start mock aioquic server that:
         - Accepts AUTH(role=gcs) → sends AUTH_OK
         - Accepts SUBSCRIBE(vehicle_id=1) → sends SUB_OK
         - Echoes any frame received on priority/bulk streams back to sender
      2. Launch QGC in headless/test mode with QUIC link configured:
         - serverHost=127.0.0.1, serverPort=14550, vehicleId=1, token=<valid>
      3. Wait 10s for connection
      4. Assert: mock server log shows AUTH received with role=gcs
      5. Assert: mock server log shows SUBSCRIBE received with vehicle_id=1
      6. Assert: mock server sent AUTH_OK + SUB_OK
      7. Send a MAVLink HEARTBEAT from mock server to QGC
      8. Assert: QGC log shows vehicle connected (or MAVLink heartbeat received)
    Expected Result: Full handshake + relay works
    Evidence: Server log + QGC log captured

  Scenario: AUTH failure handling
    Tool: Bash
    Steps:
      1. Start mock server that rejects all AUTH (sends AUTH_FAIL)
      2. Launch QGC with QUIC link, wrong token
      3. Assert: QGC log shows "AUTH_FAIL" or "authentication failed"
      4. Assert: link state is disconnected
    Expected Result: Graceful AUTH failure handling
    Evidence: QGC log captured

  Scenario: Priority classification on outbound
    Tool: Bash
    Steps:
      1. Start mock server, QGC connected
      2. Trigger QGC to send COMMAND_LONG (msgid=76) — e.g., arm/disarm command
      3. Assert: mock server received frame on priority stream (stream 4), not bulk
      4. Trigger QGC to send position setpoint or similar bulk message
      5. Assert: mock server received frame on bulk stream (stream 8)
    Expected Result: Outbound classification matches priority table
    Evidence: Mock server stream logs captured
  ```

  **Commit**: YES
  - Message: `feat(gcs): wire up full bidirectional QUIC relay with AUTH/SUBSCRIBE state machine`
  - Files: `src/Comms/QUICLink.h` (updated), `src/Comms/QUICLink.cc` (updated)
  - Pre-commit: `cmake --build build/`

---

- [ ] 7. Create QML settings UI for QUIC link configuration

  **What to do**:
  - Create `src/UI/preferences/QUICLinkSettings.qml`:
    - QML component that binds to `QUICLinkConfiguration` properties
    - Fields:
      - **Server Host**: `TextField` bound to `serverHost` (placeholder: "relay.example.com")
      - **Server Port**: `SpinBox` or `TextField` bound to `serverPort` (default: 14550)
      - **Auth Token**: `TextField` bound to `authToken` (input mode: password/hidden)
      - **Vehicle ID**: `SpinBox` bound to `vehicleId` (min: 1, max: 255)
      - **CA Certificate**: `TextField` + browse button bound to `caCertPath`
      - **Auto Subscribe**: `CheckBox` bound to `autoSubscribe` (default: checked)
    - Follow existing QGC QML style — match padding, font sizes, component hierarchy of other link settings (e.g., UDP, TCP settings QML files)
    - Use QGC's standard QML components (if available) for consistent look

  - Update `LinkSettings.qml` (or equivalent link type selector):
    - Add `"QUIC"` to the link type ComboBox/selector
    - When QUIC selected, load `QUICLinkSettings.qml` component
    - Guard with `QGC_QUIC_ENABLED` (expose as context property if needed)

  - Update `QUICLinkConfiguration`:
    - Add Q_PROPERTY declarations for all fields with NOTIFY signals (needed for QML binding)
    - `settingsURL()` → return path to `QUICLinkSettings.qml`

  **Must NOT do**:
  - Do NOT redesign QGC's link settings architecture — just add a new panel
  - Do NOT add fancy UI (animations, custom widgets) — match existing QGC style exactly
  - Do NOT modify other link type QML files

  **Recommended Agent Profile**:
  - **Category**: `visual-engineering`
    - Reason: QML UI development matching existing design language
  - **Skills**: [`frontend-ui-ux`]
    - `frontend-ui-ux`: Needed for QML layout, property binding, and consistent UI design
  - **Skills Evaluated but Omitted**:
    - `playwright`: Not needed for QML UI — QGC settings are native Qt, not web

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2 (with Tasks 2, 4) — depends only on Task 2 for QUICLinkConfiguration
  - **Blocks**: Task 9
  - **Blocked By**: Task 2

  **References**:

  **Pattern References**:
  - Existing link settings QML files in QGC — look for `UDPLinkSettings.qml`, `TCPLinkSettings.qml`, or similar in `src/UI/preferences/`. **Copy the structure, adapt for QUIC fields.**
  - `LinkSettings.qml` — the parent component that switches between link type settings panels
  - QGC QML style guide (if any) — check for shared QML components, styling constants

  **API/Type References**:
  - Qt 6 QML `TextField`, `SpinBox`, `CheckBox`, `ComboBox`, `FileDialog` (for CA cert browse)
  - `Q_PROPERTY(QString serverHost READ serverHost WRITE setServerHost NOTIFY serverHostChanged)`
  - `QQmlApplicationEngine::rootContext()->setContextProperty("QGC_QUIC_ENABLED", true)`

  **Acceptance Criteria**:

  - [ ] "QUIC" appears in link type selector in QGC settings
  - [ ] Selecting QUIC shows settings panel with all 6 fields
  - [ ] Changing server host in UI → `QUICLinkConfiguration::serverHost` updates
  - [ ] Settings persist after save → reopen shows saved values
  - [ ] Browse button for CA cert opens file dialog
  - [ ] QML has no binding errors (check QGC console output for QML warnings)

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: QUIC settings panel loads without errors
    Tool: Bash
    Preconditions: QGC built with QGC_ENABLE_QUIC=ON
    Steps:
      1. Launch QGC
      2. Navigate to Settings → Comm Links → Add
      3. Select link type "QUIC"
      4. Assert: QML loads without errors in console
      5. Assert: all 6 fields visible (host, port, token, vehicleId, caCert, autoSubscribe)
      6. Fill in fields: host="test.example.com", port=5000, vehicleId=3
      7. Save link
      8. Close and reopen link settings
      9. Assert: saved values persist
    Expected Result: Settings UI functional and persistent
    Evidence: Screenshots or QGC console output captured

  Scenario: No QML binding errors
    Tool: Bash
    Steps:
      1. Launch QGC with QML_IMPORT_TRACE=1 or similar debug flag
      2. Navigate to QUIC settings
      3. grep QGC log for "QML" and "Warning" or "Error"
      4. Assert: no QML-related warnings/errors
    Expected Result: Clean QML bindings
    Evidence: QGC log captured
  ```

  **Commit**: YES
  - Message: `feat(gcs): add QML settings UI for QUIC link configuration`
  - Files: `src/UI/preferences/QUICLinkSettings.qml`, `LinkSettings.qml` (updated), `QUICLinkConfiguration.h` (Q_PROPERTY additions)
  - Pre-commit: `cmake --build build/`

---

- [ ] 8. Implement reconnection, exponential backoff, and VEHICLE_OFFLINE handling

  **What to do**:
  - **Reconnection with exponential backoff** (add to QUICLink):
    - On `_onDisconnected(errorCode, reason)`:
      1. If state was CONNECTED or AUTHENTICATING or SUBSCRIBING:
         - Log "Connection lost: {reason}. Reconnecting in {backoff}ms..."
         - Start QTimer single-shot with current backoff delay
         - On timer expiry: call `_client->connectToServer(host, port)`, set state = CONNECTING
      2. On successful reconnect (AUTH_OK + SUB_OK):
         - Reset backoff to 1000ms
         - Emit `connected()`
      3. On reconnect failure:
         - Increase backoff: `backoff = min(backoff * 2, 30000)`
         - Add jitter: `backoff += random(-10%, +10%)`
         - Schedule next attempt
    - Backoff sequence: 1000ms → 2000ms → 4000ms → 8000ms → 16000ms → 30000ms (cap)
    - On AUTH_FAIL during reconnect: extended backoff (60000ms) — token likely wrong
    - Use `QTimer` for scheduling (Qt native, thread-safe with `QueuedConnection`)

  - **VEHICLE_OFFLINE handling** (update control message dispatch):
    - When VEHICLE_OFFLINE received:
      1. Log "Vehicle {vehicleId} went offline"
      2. Emit custom signal: `vehicleOffline(int vehicleId)`
      3. Do NOT disconnect — stay connected to server, waiting for vehicle to come back
      4. Optionally: send SUBSCRIBE again (server may auto-notify when vehicle reconnects)

  - **Graceful shutdown** (update `_disconnect()`):
    1. Cancel reconnect timer (if running)
    2. Set state = DISCONNECTED
    3. `_client->shutdown()` — graceful QUIC close
    4. Wait for msquic shutdown callbacks
    5. Emit `disconnected()`
    6. Delete `_client`

  - **Connection state tracking**:
    - Add `Q_PROPERTY(ConnectionState state READ state NOTIFY stateChanged)` for QML binding
    - Enum: `Disconnected, Connecting, Authenticating, Subscribing, Connected, Reconnecting`
    - QML can display connection status in the link settings or status bar

  **Must NOT do**:
  - Do NOT implement QUIC connection migration (0-RTT resumption) — full reconnect
  - Do NOT reconnect on user-initiated disconnect (`_disconnect()` called)
  - Do NOT flood server with rapid reconnects — backoff is mandatory
  - Do NOT close the QUIC link on VEHICLE_OFFLINE — stay connected to server

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: State machine, timer management, Qt signal/slot reconnection logic — moderately complex
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: YES (can overlap with Task 7 in Wave 3)
  - **Parallel Group**: Wave 3 (with Task 6)
  - **Blocks**: Task 9
  - **Blocked By**: Task 6

  **References**:

  **Pattern References**:
  - Jetson plan Task 8 (reconnection): Same backoff sequence, same state machine concept — adapted for Qt timers instead of std::thread sleep
  - Server plan keepalive: Server sends PING. GCS must respond with PONG (already handled in Task 6). This task handles the case where the connection drops entirely.

  **API/Type References**:
  - `QTimer::singleShot(msec, this, &QUICLink::_attemptReconnect)` — non-blocking delay
  - `QRandomGenerator::global()->bounded(min, max)` — jitter generation
  - `Q_PROPERTY(ConnectionState state ...)` — expose to QML

  **Acceptance Criteria**:

  - [ ] After server disconnect: QUICLink automatically attempts reconnect after backoff
  - [ ] Backoff increases: 1s → 2s → 4s → ... → 30s cap
  - [ ] Successful reconnect: backoff resets to 1s, AUTH + SUBSCRIBE repeated, state = CONNECTED
  - [ ] AUTH_FAIL on reconnect: extended 60s backoff
  - [ ] User disconnect (`_disconnect()`): NO reconnect attempted
  - [ ] VEHICLE_OFFLINE: logged, signal emitted, link stays connected to server
  - [ ] `state` property reflects current connection phase
  - [ ] No dangling timers after `_disconnect()`

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: Automatic reconnection after server drop
    Tool: Bash
    Preconditions: Mock server, QGC with QUIC link connected
    Steps:
      1. Start mock server, connect QGC QUIC link
      2. Verify: state == CONNECTED
      3. Kill mock server
      4. Wait 2s
      5. Assert: QGC log shows "Connection lost" and "Reconnecting in ~1000ms"
      6. Restart mock server
      7. Wait 10s
      8. Assert: QGC log shows "Reconnected" and state == CONNECTED
    Expected Result: Automatic reconnection
    Evidence: QGC log captured

  Scenario: Exponential backoff timing
    Tool: Bash
    Steps:
      1. Start QGC QUIC link with unreachable server address
      2. Capture log for 60s
      3. Extract reconnect attempt timestamps
      4. Assert: intervals approximately 1s, 2s, 4s, 8s, 16s, 30s, 30s...
    Expected Result: Exponential backoff with cap
    Evidence: QGC log timestamps captured

  Scenario: VEHICLE_OFFLINE keeps link alive
    Tool: Bash
    Steps:
      1. Mock server connected, QGC subscribed to vehicle 1
      2. Mock server sends VEHICLE_OFFLINE(vehicle_id=1) on control stream
      3. Assert: QGC log shows "Vehicle 1 went offline"
      4. Assert: QUIC connection still alive (state != DISCONNECTED)
      5. Assert: vehicleOffline signal emitted
    Expected Result: Link persists through vehicle offline
    Evidence: QGC log + connection state captured
  ```

  **Commit**: YES
  - Message: `feat(gcs): add reconnection with exponential backoff and VEHICLE_OFFLINE handling`
  - Files: `src/Comms/QUICLink.h` (updated), `src/Comms/QUICLink.cc` (updated)
  - Pre-commit: `cmake --build build/`

---

- [ ] 9. Implement unit tests and integration tests

  **What to do**:
  - **Unit tests** (QTest/GTest, no network required):
    - `test/Comms/QUICFrameDecoderTest.cc`:
      - Test encode/decode roundtrip (single frame)
      - Test multiple frames in one `feed()` call
      - Test partial frame accumulation (1 byte at a time)
      - Test partial length prefix (1 byte, then rest)
      - Test empty/zero-length frame rejection
      - Test max-size frame (65535 bytes)
    - `test/Comms/QUICPriorityClassifierTest.cc`:
      - Test all 18 high-priority msgids → `Priority`
      - Test common bulk msgids (ATTITUDE=30, GPS_RAW_INT=24, RAW_IMU=27, GLOBAL_POSITION_INT=33) → `Bulk`
      - Test unknown msgid (65535) → `Bulk`
      - Test `extractMsgId()` with MAVLink v1 (magic=0xFE) frame
      - Test `extractMsgId()` with MAVLink v2 (magic=0xFD) frame
    - `test/Comms/QUICControlProtocolTest.cc`:
      - Test AUTH encode → decode roundtrip
      - Test SUBSCRIBE encode → decode roundtrip
      - Test PONG encode → decode roundtrip
      - Test decode AUTH_OK, AUTH_FAIL, SUB_OK, SUB_FAIL, PING, VEHICLE_OFFLINE
      - Test unknown message type → type == "UNKNOWN"
      - Test CBOR cross-compatibility: encode in C++ → decode in Python (test script)
    - Register in CMakeLists.txt using QGC's test infrastructure (look for how existing tests are added)

  - **Integration tests** (require mock server):
    - `test/Comms/QUICLinkIntegrationTest.cc`:
      - Create minimal mock aioquic server (Python script) that:
        - Accepts AUTH(role=gcs) → sends AUTH_OK
        - Accepts SUBSCRIBE → sends SUB_OK
        - Echoes received frames back on same stream
        - Sends VEHICLE_OFFLINE on command
      - Test: QUICLink connects → AUTH → SUBSCRIBE → sends frame → receives echo
      - Test: QUICLink handles AUTH_FAIL gracefully
      - Test: QUICLink reconnects after server drop
      - Test: VEHICLE_OFFLINE signal is emitted
    - Mock server script: `test/mock_quic_server.py` (reuse from Server plan test infrastructure if possible)

  **Must NOT do**:
  - Do NOT aim for 100% coverage — focus on critical paths and wire compatibility
  - Do NOT write tests that require real drone or real relay server
  - Do NOT test msquic internals — test the wrapper interface
  - Do NOT create complex test infrastructure — keep tests focused

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
    - Reason: Multiple test files covering unit + integration with async QUIC and Qt test patterns
  - **Skills**: []

  **Parallelization**:
  - **Can Run In Parallel**: NO
  - **Parallel Group**: Wave 4 (after Tasks 6, 8)
  - **Blocks**: None
  - **Blocked By**: Tasks 6, 7, 8

  **References**:

  **Pattern References**:
  - Existing QGC test files — look in `test/` directory for QTest/GTest patterns used by QGC
  - Server plan Task 8 (pytest): mock server patterns — reuse the mock server concept
  - Jetson plan Task 7 (GTest): GTest patterns for framing and classifier

  **API/Type References**:
  - QTest: `QVERIFY()`, `QCOMPARE()`, `QTEST_MAIN()`
  - GTest: `TEST()`, `EXPECT_EQ()`, `ASSERT_TRUE()`
  - ctest: `ctest --test-dir build -R QUIC`

  **External References**:
  - aioquic server for mock: https://github.com/aiortc/aioquic/blob/main/examples/ — adapt for simple mock

  **Acceptance Criteria**:

  - [ ] `ctest --test-dir build -R QUIC` → all tests pass
  - [ ] ≥15 test cases covering: framing, classifier, control protocol, integration
  - [ ] Frame encoder/decoder produces identical output to Server plan's Python `framing.py` for same input
  - [ ] Priority classifier produces identical results to Jetson plan's C++ classifier for all 18 msgids
  - [ ] CBOR output is decodable by Python `cbor2.loads()` (cross-language test)
  - [ ] Integration test validates AUTH → SUBSCRIBE → relay roundtrip with mock server
  - [ ] No test requires internet access or external services
  - [ ] Tests complete in under 30 seconds total

  **Agent-Executed QA Scenarios:**

  ```
  Scenario: All unit tests pass
    Tool: Bash
    Preconditions: QGC built with tests
    Steps:
      1. ctest --test-dir build -R QUIC -V
      2. Assert: exit code 0
      3. Assert: all test cases passed (no failures)
      4. Assert: at least 15 test items ran
    Expected Result: Full test suite green
    Evidence: ctest output captured

  Scenario: Integration test with mock server
    Tool: Bash
    Preconditions: Python 3, aioquic installed
    Steps:
      1. Start mock server: python3 test/mock_quic_server.py &
      2. ctest --test-dir build -R QUICLinkIntegration -V
      3. Assert: AUTH + SUBSCRIBE + relay roundtrip passes
      4. Kill mock server
    Expected Result: End-to-end relay validated
    Evidence: ctest + mock server output captured

  Scenario: Cross-language CBOR compatibility
    Tool: Bash
    Steps:
      1. ctest --test-dir build -R QUICControlProtocolCrossLang -V
      2. Assert: C++ encoded CBOR decoded by Python successfully
    Expected Result: Wire compatibility confirmed
    Evidence: Test output captured
  ```

  **Commit**: YES
  - Message: `test(gcs): add QTest/GTest unit tests and QUIC integration tests`
  - Files: `test/Comms/QUICFrameDecoderTest.cc`, `test/Comms/QUICPriorityClassifierTest.cc`, `test/Comms/QUICControlProtocolTest.cc`, `test/Comms/QUICLinkIntegrationTest.cc`, `test/mock_quic_server.py`
  - Pre-commit: `ctest --test-dir build -R QUIC`

---

## Commit Strategy

| After Task | Message | Files | Verification |
|------------|---------|-------|--------------|
| 1 | `build(gcs): integrate msquic into QGC CMake build system` | CMakeLists.txt, cmake/FindMsQuic.cmake, placeholder QUICLink.h/.cc | cmake --build |
| 2 | `feat(gcs): add QUICLink and QUICLinkConfiguration skeleton` | QUICLink*, QUICLinkConfiguration*, LinkConfiguration.h, LinkManager.* | cmake --build |
| 3 | `feat(gcs): add QUIC frame decoder and MAVLink priority classifier` | QUICFrameDecoder*, QUICPriorityClassifier* | cmake --build |
| 4 | `feat(gcs): implement msquic QUIC client wrapper` | QUICClient* | cmake --build |
| 5 | `feat(gcs): add CBOR control protocol handler` | QUICControlProtocol* | cmake --build |
| 6 | `feat(gcs): wire up full bidirectional QUIC relay` | QUICLink* (updated) | cmake --build + mock test |
| 7 | `feat(gcs): add QML settings UI for QUIC link` | QUICLinkSettings.qml, LinkSettings.qml | cmake --build |
| 8 | `feat(gcs): add reconnection with exponential backoff` | QUICLink* (updated) | cmake --build |
| 9 | `test(gcs): add QUIC link unit and integration tests` | test/Comms/QUIC* | ctest -R QUIC |

---

## Success Criteria

### Verification Commands
```bash
# Build succeeds
cmake -B build -DQGC_ENABLE_QUIC=ON && cmake --build build/ -j$(nproc)
# Expected: Build succeeded, msquic linked

# All tests pass
ctest --test-dir build -R QUIC -V
# Expected: All tests passed, 0 failures

# QGC launches with QUIC link available
./build/QGroundControl
# Expected: QUIC appears in link type selector

# QUIC disabled build still works (no regression)
cmake -B build-noquic -DQGC_ENABLE_QUIC=OFF && cmake --build build-noquic/ -j$(nproc)
# Expected: Build succeeded, no msquic references
```

### Final Checklist
- [ ] All "Must Have" features present and working
- [ ] All "Must NOT Have" guardrails respected (no MAVLink parsing, no JNI, no tinycbor, etc.)
- [ ] All unit tests pass (`ctest -R QUIC`)
- [ ] Integration test validates end-to-end relay with mock server
- [ ] QUIC link settings UI appears and functions in QGC
- [ ] Settings persist across QGC restarts
- [ ] Wire protocol matches Jetson and Server plans exactly (u16_le framing, CBOR control, same ALPN, same stream IDs)
- [ ] Priority classification table matches Jetson plan exactly (same 18 msgids)
- [ ] Builds on desktop Linux with Qt 6.6.3
- [ ] Android NDK cross-compilation documented (and builds if NDK available)
- [ ] Existing link types (UDP, TCP, Serial) unaffected — no regressions
- [ ] QGC_ENABLE_QUIC=OFF compiles cleanly without msquic
