# Decisions — mavlink-quic-relay-jetson

## 2026-02-28 — Initial Architecture Decisions
- C++ standard: **C++17** (latest ratified standard; "C++18" does not exist — next is C++20, not available on Ubuntu 18.04 GCC 7.5)
- Thread-safe queue implementation: `std::queue<MavlinkFrame>` + `std::mutex` + `std::condition_variable` (simpler, preferred over lock-free for correctness)
- CBOR library: `tinycbor` (lightweight, C, no heavy deps) — verify availability on ARM64 Ubuntu
- No dynamic_reconfigure — all config at launch time via ROS params
- No MAVROS dep — only mavros_msgs package
- Auth validation: ROS_FATAL + exit if token == "CHANGE_ME"
- Reconnect backoff cap: 30s (not 60s as mentioned elsewhere in plan)
- Auth failure backoff: 60s (to avoid spamming server with bad token)
- Publisher thread safety: publish ONLY from ROS spin thread (ros::Timer drain)
- AsyncSpinner with 2 threads for ROS callbacks
