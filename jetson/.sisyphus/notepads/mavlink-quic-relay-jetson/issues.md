# Issues — mavlink-quic-relay-jetson

## Known Gotchas

### msquic Buffer Ownership (CRITICAL)
- Buffers passed to `StreamSend()` are OWNED BY MSQUIC until `SEND_COMPLETE` event fires
- Must use RAII `SendBuffer` struct — do NOT free before `SEND_COMPLETE`
- On connection drop, ALL pending send buffers freed in `SHUTDOWN_COMPLETE` handler

### ROS Publisher Thread Safety
- `ros::Publisher::publish()` is NOT guaranteed thread-safe
- ONLY call publish() from ROS spin thread (via ros::Timer callback)
- Never call from msquic callback threads

### Stream ID Assignment
- msquic assigns stream IDs automatically — track streams by open order, NOT by ID number
- First opened stream → Control, second → Priority, third → Bulk

### AUTH Before MAVLink Streams
- Must wait for AUTH_OK response on control stream before opening MAVLink streams (Priority + Bulk)
- AUTH failure → log ROS_ERROR, 60s backoff, retry

### Ubuntu 18.04 Compatibility
- C++17 is available on GCC 7+ (Ubuntu 18.04 has GCC 7.5)
- Use `std::optional` carefully — available in C++17
- Avoid `std::filesystem` (limited support on 18.04 without linking -lstdc++fs)

### catkin workspace location
- The jetson/ directory IS the catkin workspace src space
- Run `catkin build` from workspace root (one level up from src or configure properly)
- Actually: need to check if there's a catkin workspace setup at /home/kevin/workspace/MavlinkRelay/jetson/
- The package goes directly in /home/kevin/workspace/MavlinkRelay/jetson/mavlink_quic_relay/
