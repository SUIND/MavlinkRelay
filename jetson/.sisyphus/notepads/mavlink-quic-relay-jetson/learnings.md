# Learnings — mavlink-quic-relay-jetson

## Project Context
- Working dir: `/home/kevin/workspace/MavlinkRelay/jetson/`
- Catkin workspace root: `/home/kevin/workspace/MavlinkRelay/jetson/` (package goes here as `mavlink_quic_relay/`)
- The ROS package must be created inside: `/home/kevin/workspace/MavlinkRelay/jetson/mavlink_quic_relay/`
- Platform: Jetson Xavier NX / Orin Nano, ARM64, Ubuntu 20.04 (also 18.04 compat), ROS 1 Noetic
- Build system: `catkin build` (catkin_tools), NOT `catkin_make`

## Existing Server Reference
- Python aioquic server lives at `/home/kevin/workspace/MavlinkRelay/mavlink_relay_server/`
- `framing.py` implements `encode_frame(payload)` and `FrameDecoder` — use same wire format in C++
- Wire format: `[u16_le 2-byte length][raw bytes]` on all streams
- Control stream uses CBOR-encoded messages
- Server port default: 14550 (NOT 5000 as in plan — verify with server team, use plan default 5000 for relay config)
- Auth tokens in config: base64-encoded, e.g. `"AAAAAAAAAAAAAAAAAAAAAA=="`
- ALPN: `"mavlink-quic-v1"` (must match server)

## Stream IDs
- Stream 0: Control (AUTH, PING/PONG) — Bidirectional
- Stream 4: Priority MAVLink — Bidirectional
- Stream 8: Bulk MAVLink — Bidirectional

## msquic Notes
- Headers: `/usr/local/include/msquic.h` (system install from source)
- Library: `/usr/local/lib/libmsquic.so`
- Callbacks fire on msquic worker threads — NEVER call ros::Publisher::publish() from callbacks
- Use lock-free or mutex-protected queue between msquic callbacks and ROS thread
- SEND_COMPLETE event fires before buffer can be freed
- PeerBidiStreamCount must be > 0 for server-initiated streams (set to 1)
- KeepAliveIntervalMs = 15000, IdleTimeoutMs = 60000

## Package Structure
- catkin workspace src: `/home/kevin/workspace/MavlinkRelay/jetson/`
- Package: `mavlink_quic_relay` at `/home/kevin/workspace/MavlinkRelay/jetson/mavlink_quic_relay/`
- C++17 standard required
- Compile flags: `-Wall -Wextra -Werror`
- mavros_msgs available via: `ros-noetic-mavros-msgs` (apt)

## Package Scaffold (Task 1)
- Package created at: `/home/kevin/workspace/MavlinkRelay/jetson/mavlink_quic_relay/`
- Files created: `CMakeLists.txt`, `package.xml`, `src/main.cpp`, `README.md`
- Directories created: `include/mavlink_quic_relay/`, `src/`, `launch/`, `config/`, `test/` (each with `.gitkeep`)
- `catkin init` run at workspace root `/home/kevin/workspace/MavlinkRelay/`
- Workspace source space configured: `catkin config --source-space jetson`
- **Build environment note**: Dev host is CachyOS x86_64 (NOT Jetson). ROS Noetic, msquic, mavros_msgs not installed on dev host.
- `catkin build` fails on dev host with `catkin CMake module not found` — expected. Will succeed on Jetson with ROS sourced.
- `package.xml` validated with `catkin_pkg.parse_package()` — format 2, deps correct: build+exec=roscpp,mavros_msgs,std_msgs; test=rostest
- CMake syntax verified: cmake processes through C++17/compile-options/msquic sections before failing on missing catkin — syntax clean
- msquic not installed on dev host (`/usr/local/include/msquic.h` missing) — CMakeLists.txt handles gracefully with `message(WARNING)`, skips node target
- **On Jetson**: `source /opt/ros/noetic/setup.bash && catkin build mavlink_quic_relay` should succeed (skipping node target if msquic not yet built)
- **With msquic**: `catkin build mavlink_quic_relay -DMSQUIC_ROOT=/opt/msquic` or install to `/usr/local` then rebuild
- catkin workspace `.catkin_tools/` config file written at `/home/kevin/workspace/MavlinkRelay/.catkin_tools/`

## PriorityClassifier Module (Task 4)
- Files created:
  - `mavlink_quic_relay/include/mavlink_quic_relay/priority_classifier.h`
  - `mavlink_quic_relay/src/priority_classifier.cpp`
- Compile check: `g++ -std=c++17 -Wall -Wextra -Werror -c src/priority_classifier.cpp -Iinclude` → EXIT:0 (clean, zero output)
- 18 priority msgids: 0,4,20,22,23,39,40,41,44,45,47,51,73,75,76,77,111,253
- `classify(0)` → PRIORITY (HEARTBEAT), `classify(76)` → PRIORITY (COMMAND_LONG)
- `classify(30)` → BULK (ATTITUDE), `classify(9999)` → BULK (unknown)
- Uses `std::unordered_set<uint32_t>` for O(1) average lookup
- `[[nodiscard]]` + `noexcept` on both query methods
- No ROS/QUIC/mavros headers — pure C++17 utility
- Custom constructor `explicit PriorityClassifier(std::unordered_set<uint32_t>)` for test overrides

## RosInterface Module (Task 3)
- Files created:
  - `mavlink_quic_relay/include/mavlink_quic_relay/ros_interface.h`
  - `mavlink_quic_relay/src/ros_interface.cpp`
- `MavlinkFrame` struct: `uint32_t msgid` + `std::vector<uint8_t> raw_bytes`
- `BoundedQueue`: mutex-protected `std::queue<MavlinkFrame>`, drop-oldest on overflow, `tryPop()` returns `std::optional`
- `RosInterfaceConfig`: default topics `/mavlink/from` + `/mavlink/to`, queue max 500, drain period 1ms, warn timeout 10s
- `mavlinkFromCallback`: sets `received_any_message_` atomic, extracts `msg->msgid`, calls `toRawBytes`, pushes to `outbound_queue_`
- `drainInboundCallback`: one-shot warn after 10s with `warn_logged_` flag; drains up to `kMaxDrainPerTick=10` per tick; calls `mavlink_pub_.publish()` (safe — ROS timer thread)
- `toRawBytes`: MAVLink v1 (0xFE) = 6-byte header + payload + 2-byte LE checksum; MAVLink v2 (0xFD) = 10-byte header + payload + 2-byte LE checksum; payload unpacked from `payload64[]` big-endian words up to `msg.len` bytes
- `fromRawBytes`: inverse parse; packs payload bytes into `payload64[]` big-endian words, pads last word with zeros
- `mavros_msgs::Mavlink::checksum` is uint64 but only low 16 bits used; wire format is LE (low byte first)
- `mavros_msgs::Mavlink::payload64` uses big-endian packing (MSB of each uint64 is first payload byte)
- Thread safety: `outbound_queue_` written by ROS callback / read by sender thread; `inbound_queue_` written by msquic thread via `pushInbound()` / read by ROS timer; both use `std::lock_guard<std::mutex>`
- `received_any_message_` uses `std::atomic<bool>` with relaxed ordering (no sync needed, just a flag)
- Publisher NEVER called from msquic thread — only from `drainInboundCallback` (ROS timer)

## Launch & Config Files (Task 5)
- Files created:
  - `mavlink_quic_relay/launch/relay.launch`
  - `mavlink_quic_relay/config/relay_params.yaml`
- `relay.launch` uses `<rosparam command="load">` inside `<node>` tag — all YAML keys are automatically scoped to `/mavlink_quic_relay/<key>` (no manual namespace prefix needed)
- Override pattern: `<param ... if="$(eval arg('x') != '')">` — only overwrites YAML value when non-default arg is passed on the command line
- `required="true"` on the node: if the node exits (e.g. ROS_FATAL + return 1), roslaunch tears down the whole launch group — correct for a relay that must not silently fail
- `auth_token: "CHANGE_ME"` in YAML is intentional sentinel; `main.cpp` validates at startup and calls `ROS_FATAL` + `ros::shutdown()` + `return 1` if still "CHANGE_ME" or empty
- `server_host` also validated at startup — ROS_FATAL if empty string
- All 16 parameters documented in `relay_params.yaml` with units, defaults, and semantic notes
- `$(find mavlink_quic_relay)` resolves to package install/devel prefix at runtime — correct for package-relative paths
- `server_port` default in YAML is 5000 (plan spec); server `config.example.yaml` uses 14550 — operator must align these manually

## QuicClient Module (Task 6)
- Files created:
  - `mavlink_quic_relay/include/mavlink_quic_relay/quic_client.h`
  - `mavlink_quic_relay/src/quic_client.cpp`
- CMakeLists.txt updated: `add_executable` now includes `src/quic_client.cpp` and `src/priority_classifier.cpp`
- **Dual-compile guard**: `#ifdef MAVLINK_QUIC_RELAY_HAVE_MSQUIC` wraps all msquic-dependent code; stub impls provided in the `#else` branch for dev host builds without msquic
- **SendBuffer**: `data` vector holds `[u16_le len][payload]`; `quic_buf.Buffer` points into `data.data()` — safe because `data` is owned by the struct and outlives any StreamSend() call
- **StreamContext**: `new StreamContext{this, index}` allocated per stream and passed as callback context to `StreamOpen`. Freed in `STREAM_SHUTDOWN_COMPLETE` handler. One-time leak on abrupt shutdown is acceptable; process exits anyway.
- **AUTH flow**: `openStreams()` opens control stream only → `sendAuth()` sends CBOR `{token, role, vehicle_id}` → `onStreamEvent` detects CBOR tstr `"ok"` (bytes `0x62 0x6f 0x6b`) in control stream receive → sets `auth_ok_=true` → `openMavlinkStreams()` opens priority + bulk streams
- **CBOR encoding**: manual, no external library. Map(3) = `0xa3`, then key/value pairs using `cborAppendTextString` / `cborAppendByteString` / `cborAppendUint32` helpers. Handles lengths 0-23 (1-byte), 24-255 (2-byte), 256-65535 (3-byte).
- **AUTH_OK detection heuristic**: scans for byte sequence `{0x62, 0x6f, 0x6b}` = CBOR tstr(2) "ok". Adjust if server changes response format.
- **Frame decoder**: stateful `StreamRecvState` per stream accumulates fragmented msquic receive buffers. Fully handles partial header (< 2 bytes) and partial payload across multiple RECEIVE events.
- **SendBuffer cleanup on failed StreamSend**: queue is rebuilt without the failed entry (std::queue has no erase; rebuild is O(n) but the queue is small and this is an error path).
- **processEvents() double-lock**: callbacks are captured under the same `event_queue_mutex_` as the queue swap — ensures consistent snapshot even if caller replaces callbacks between ticks.
- **PEER_STREAM_STARTED**: server-initiated stream accepted via `SetCallbackHandler` with `this` as context (no StreamContext allocation — server streams not tracked separately; add if needed).
- **Compile check on dev host**: LSP shows `'msquic.h' not found` and `'ros/ros.h' not found` — expected, not a defect. Builds cleanly on Jetson with msquic installed at `/usr/local`.

## RelayNode Module (Task 7)
- Files created:
  - `mavlink_quic_relay/include/mavlink_quic_relay/relay_node.h`
  - `mavlink_quic_relay/src/relay_node.cpp`
- Files updated:
  - `mavlink_quic_relay/src/main.cpp` — now calls `loadRelayNodeConfig`, constructs `RelayNode`, `start()`/`stop()`
  - `mavlink_quic_relay/CMakeLists.txt` — `add_executable` now includes `relay_node.cpp` and `ros_interface.cpp`
- **Single outbound queue design**: `RosInterface` has ONE outbound queue; `senderLoop` classifies per-frame via `PriorityClassifier`. This avoids dual-queue complexity while still routing to the correct QUIC stream. Priority vs. bulk classification is at send time, not at receive time.
- **Bulk drop-oldest policy**: `BoundedQueue` already implements drop-oldest on overflow — no extra code needed in `RelayNode`.
- **Thread model enforced**: `processEvents()` only called from `quicEventCallback` (ROS timer thread). `onFrameReceived`/`onConnectionStateChanged` run on ROS thread. `senderLoop` never touches ROS publishers — only `pushInbound` bridging via `RosInterface`.
- **stop() idempotent guard**: checks `running_ && sender_thread_.joinable()` before logging/joining to handle double-stop (e.g., from `~RelayNode` and explicit `relay.stop()` in main).
- **`/*event*/`** comment on unused `ros::TimerEvent` param — suppresses `-Wunused-parameter` under `-Werror` without a `(void)` cast.
- **MAVLink msgid extraction for inbound**: v2 = bytes[7..9] (24-bit LE), v1 = byte[5] (8-bit). Fallback msgid=0 if frame too short. Used for potential future inbound classification; current relay doesn't need it but `MavlinkFrame` requires it.
- **connect() non-fatal**: `start()` calls `connect()` but only logs a warning on false return — connection is async and state arrives via `onConnectionStateChanged` callback.
- **Compile check**: g++ -std=c++17 -Wall -Wextra -Werror stub test passes for both `relay_node.cpp` and `main.cpp` (exit 0, zero output).

## Unit & Integration Tests (Task 8)
- Files created:
  - `test/test_priority_classifier.cpp` — 30 test cases (18 priority + 5 bulk + 3 edge + 4 inspect + 4 custom set + 2 enum value); `TEST_F` fixture + `TEST` standalone; `#include <limits>` for `std::numeric_limits<uint32_t>::max()`
  - `test/test_thread_safe_queue.cpp` — 12 tests: empty pop, push/pop, FIFO order, drop-oldest (single + multi overflow), size tracking, clear + re-push, size-1 edge case, raw_bytes preserved, concurrent 1000-frame push/pop with no data loss, 4-thread concurrent push; `ros::Time::init()` in main (required by ros headers even without roscore)
  - `test/test_mavlink_framing.cpp` — 13 tests: pure C++17 stdlib (no ROS), mirrors `framing.py` wire format `[u16_le][payload]`; covers small/large payloads, LE encoding, partial header (1 byte), partial frame, byte-by-byte feed, 10-frame batch, v1+v2 heartbeat roundtrips; `g++ -std=c++17 -Wall -Wextra -Werror` → EXIT:0 on dev host
  - `test/test_relay_roundtrip.test` — rostest XML; starts `mock_quic_server.py` on port 15551 + relay node; 30s time-limit
  - `test/mock_quic_server.py` — aioquic mock server; import-guarded with `AIOQUIC_AVAILABLE`; AUTH: scans frame for `TEST_TOKEN` bytes → sends `CBOR_AUTH_OK = {0x62, 0x6f, 0x6b}`; echoes MAVLink frames back on same stream; self-signed cert auto-generated via `cryptography` (EC P-256, 1-day); prints `FRAME_RECEIVED stream=N len=M total=T` for test verification
  - `test/test_relay_roundtrip.py` — rostest script checks `/mavlink/to` is advertised after 3s sleep
- CMakeLists.txt test block: `catkin_add_gtest` for all 3 unit suites; `add_rostest` for integration; `catkin_install_python` for `.py` test scripts
- `test_priority_classifier` — links only `priority_classifier.cpp`, no ROS at link time
- `test_thread_safe_queue` — links `ros_interface.cpp` + `${catkin_LIBRARIES}` (ros::Time needed for `RosInterfaceConfig::drain_period` default constructor)
- `test_mavlink_framing` — no extra source files; self-contained FrameDecoder/encodeFrame impl inside test
- Integration test requires `pip install aioquic cryptography` on Jetson before running `catkin run_tests`

## ReconnectManager Module (Task 8)
- Files created: include/mavlink_quic_relay/reconnect_manager.h, src/reconnect_manager.cpp
- Files modified: relay_node.h, relay_node.cpp, quic_client.h, quic_client.cpp, CMakeLists.txt
- State machine: DISCONNECTED → CONNECTING → AUTHENTICATING → CONNECTED → DISCONNECTED
- Backoff: 1s/2s/4s/8s/16s/30s cap, ±10% jitter via std::uniform_real_distribution
- Auth failure: 60s flat penalty, resets attempt counter
- Reconnect thread sleeps in 100ms increments checking running_ flag
- QuicClient: added AUTH_OK event type, setAuthOkCallback(), auth_ok_cb_ (both ifdef branches)
- stop() sequence: running_=false → timer.stop() → reconnect_manager.stop() → client.shutdown() → join sender
- onDisconnected() NOT called during shutdown (running_=false guard prevents spurious reconnect)
- rng_ seeded with std::random_device{}() in ReconnectManager constructor

## Test Framework Expansion (completed Mar 1 2026)

### New files added:
- `test/test_reconnect_manager.cpp` — 15 GTest cases; tests state machine only (start()/stop() never called); uses ros::init(AnonymousName) + ros::Time::init() in main(); no rosmaster needed; QuicClient uses #else stub branch; RosInterface constructed via ros::init trick
- `test/test_ros_interface_framing.cpp` — 18 GTest cases; toRawBytes/fromRawBytes duplicated as private static free functions labeled "keep in sync with ros_interface.cpp"; covers v1+v2 round-trips, wire format, LE encoding, edge cases
- `test/mock_quic_server.py` — updated: CBOR_AUTH_FAIL=bytes([0x62,0x6E,0x6F]) added; --auth-fail flag rejects all auth, prints AUTH_REJECTED to stdout; make_protocol() closure threads auth_fail through
- `test/test_relay_roundtrip.py` — upgraded from shallow (topic check only) to real end-to-end: publishes HEARTBEAT (msgid=0) and COMMAND_LONG (msgid=76) on /mavlink/from, polls /mavlink/to for echo with 10s timeout; setUpClass shares rospy.init_node; extra 3s sleep for QUIC auth

### CMakeLists.txt additions:
- `catkin_add_gtest(test_reconnect_manager ...)` — sources: reconnect_manager.cpp, ros_interface.cpp, quic_client.cpp
- `catkin_add_gtest(test_ros_interface_framing ...)` — source: test file only (self-contained duplicated impls)
- Both link ${catkin_LIBRARIES}

### Framing logic verified:
- Standalone g++ -std=c++17 -Wall -Wextra -Werror compile+run: EXIT:0, all 4 logic checks PASS
