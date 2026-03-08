#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <vector>

#ifdef __has_include
#if __has_include(<msquic.h>)
#include <msquic.h>
#define MAVLINK_QUIC_RELAY_HAVE_MSQUIC 1
#endif
#endif

namespace mavlink_quic_relay
{

#ifdef MAVLINK_QUIC_RELAY_HAVE_MSQUIC

/// RAII wrapper for msquic send buffers.
/// msquic owns the buffer memory from StreamSend() until SEND_COMPLETE fires.
/// Wire format: [u16_le 2-byte little-endian length][payload]
struct SendBuffer
{
  QUIC_BUFFER quic_buf;
  std::vector<uint8_t> data;

  /// Construct and encode with [u16_le length][payload] framing.
  explicit SendBuffer(const std::vector<uint8_t>& payload);

  // Non-copyable, movable
  SendBuffer(const SendBuffer&) = delete;
  SendBuffer& operator=(const SendBuffer&) = delete;
  SendBuffer(SendBuffer&&) = default;
  SendBuffer& operator=(SendBuffer&&) = default;
};

/// Configuration for QuicClient.
struct QuicClientConfig
{
  std::string server_host;
  uint16_t server_port{5000};
  std::string auth_token;
  std::string vehicle_id{"BB_000001"};
  std::string ca_cert_path;
  std::string alpn{"mavlink-quic-v1"};
  uint32_t keepalive_interval_ms{15000};
  uint32_t idle_timeout_ms{60000};
};

/// Callback type for received MAVLink frames from the server.
using FrameReceivedCallback = std::function<void(std::vector<uint8_t> frame)>;

/// Callback type for connection state changes.
using ConnectionStateCallback = std::function<void(bool connected)>;

/// msquic QUIC client for mavlink_quic_relay.
/// Manages: Registration → Configuration → Connection → 3 Streams.
/// Thread safety: all msquic callbacks post to internal queue; caller drains via processEvents().
class QuicClient
{
 public:
  explicit QuicClient(QuicClientConfig config);
  ~QuicClient();

  // Non-copyable, non-movable (contains mutexes and msquic handles)
  QuicClient(const QuicClient&) = delete;
  QuicClient& operator=(const QuicClient&) = delete;
  QuicClient(QuicClient&&) = delete;
  QuicClient& operator=(QuicClient&&) = delete;

  /// Set callback for received MAVLink frames (called from processEvents() — ROS thread safe).
  void setFrameReceivedCallback(FrameReceivedCallback cb);

  /// Set callback for connection state changes (called from processEvents()).
  void setConnectionStateCallback(ConnectionStateCallback cb);

  /// Set callback invoked when AUTH_OK is received on the control stream.
  /// Called from processEvents() on the ROS timer thread — safe to call ROS APIs.
  void setAuthOkCallback(std::function<void()> cb);

  /// Set callback invoked when AUTH_FAIL is received on the control stream.
  /// Called from processEvents() on the ROS timer thread — safe to call ROS APIs.
  void setAuthFailCallback(std::function<void()> cb);

  /// Open QUIC connection to server. Returns false on immediate failure.
  [[nodiscard]] bool connect();

  /// Send a frame on the control stream (CBOR-encoded control messages).
  [[nodiscard]] bool sendControlFrame(const std::vector<uint8_t>& payload);

  /// Send a MAVLink frame on the priority stream (Stream 4).
  [[nodiscard]] bool sendPriorityFrame(const std::vector<uint8_t>& payload);

  /// Send a MAVLink frame on the bulk stream (Stream 8).
  [[nodiscard]] bool sendBulkFrame(const std::vector<uint8_t>& payload);

  /// Graceful shutdown: ConnectionShutdown → wait SHUTDOWN_COMPLETE → cleanup.
  void shutdown();

  /// Process pending events (received frames, state changes).
  /// MUST be called from ROS thread only (e.g., from a ros::Timer callback).
  void processEvents();

  /// Returns true if QUIC connection is established and authenticated.
  [[nodiscard]] bool isConnected() const noexcept;

 private:
  // --- msquic API handle (global, reference counted) ---
  const QUIC_API_TABLE* msquic_{nullptr};

  // --- msquic object handles ---
  HQUIC registration_{nullptr};
  HQUIC configuration_{nullptr};
  HQUIC connection_{nullptr};

  // --- Streams (opened in order: control, priority, bulk) ---
  HQUIC stream_control_{nullptr};
  HQUIC stream_priority_{nullptr};
  HQUIC stream_bulk_{nullptr};

  // --- State ---
  QuicClientConfig config_;
  std::atomic<bool> connected_{false};
  std::atomic<bool> shutdown_requested_{false};

  // --- Stream open sequencing ---
  // AUTH must complete before opening MAVLink streams
  std::atomic<bool> auth_ok_{false};

  // --- Thread-safe event queue (msquic threads → ROS thread) ---
  struct InternalEvent
  {
    /// Discriminator for events posted from msquic callbacks to the ROS thread.
    enum class Type
    {
      FRAME_RECEIVED,  ///< A complete MAVLink frame was decoded from a data stream
      STATE_CHANGED,   ///< QUIC connection connected (true) or disconnected (false)
      AUTH_OK,         ///< Server accepted AUTH on the control stream
      AUTH_FAIL,       ///< Server rejected AUTH on the control stream
    };
    Type type;
    std::vector<uint8_t> frame;
    bool connected{false};
  };
  std::queue<InternalEvent> event_queue_;
  std::mutex event_queue_mutex_;

  // --- Callbacks registered by caller ---
  FrameReceivedCallback frame_cb_;
  ConnectionStateCallback state_cb_;
  std::function<void()> auth_ok_cb_;
  std::function<void()> auth_fail_cb_;

  // --- Pending send buffers (must outlive SEND_COMPLETE) ---
  std::mutex pending_sends_mutex_;
  std::queue<std::unique_ptr<SendBuffer>> pending_sends_;

  // --- Shutdown synchronization ---
  std::mutex shutdown_mutex_;
  std::condition_variable shutdown_cv_;
  bool shutdown_complete_{false};

  // --- Per-stream receive state (length-prefix decoder) ---
  /// Per-stream receive state for the `[u16_le length][payload]` frame decoder.
  /// Handles QUIC fragmentation: data may arrive in multiple RECEIVE events.
  struct StreamRecvState
  {
    std::vector<uint8_t> buf;  ///< Accumulation buffer for partial header or payload bytes
    uint32_t expected_len{0};  ///< Payload bytes expected for the current frame
    bool has_header{false};    ///< True once the 2-byte length header has been fully received
  };
  StreamRecvState recv_state_control_;
  StreamRecvState recv_state_priority_;
  StreamRecvState recv_state_bulk_;

  // --- Private methods ---
  bool initMsquic();
  bool openStreams();
  void sendAuth();
  [[nodiscard]] bool sendOnStream(HQUIC stream, const std::vector<uint8_t>& payload);
  void postEvent(InternalEvent event);
  void decodeFrames(StreamRecvState& state, const uint8_t* data, uint64_t length,
                    std::vector<std::vector<uint8_t>>& frames_out);
  void handleControlFrame(const std::vector<uint8_t>& frame);
  void onConnectionEvent(HQUIC connection, QUIC_CONNECTION_EVENT* event);
  void onStreamEvent(HQUIC stream, QUIC_STREAM_EVENT* event, int stream_index);
  void openMavlinkStreams();
  void closeAllHandles();

  /// Context pointer passed to msquic StreamOpen/SetCallbackHandler.
  /// Routes stream events to the correct QuicClient instance and stream index.
  struct StreamContext
  {
    QuicClient* client{nullptr};  ///< Owning QuicClient instance
    int stream_index{0};          ///< 0=control, 1=priority, 2=bulk
  };

  // --- Static msquic callback shims ---
  static QUIC_STATUS QUIC_API connectionCallback(HQUIC connection, void* context, QUIC_CONNECTION_EVENT* event);
  static QUIC_STATUS QUIC_API streamCallback(HQUIC stream, void* context, QUIC_STREAM_EVENT* event);
};

#else  // !MAVLINK_QUIC_RELAY_HAVE_MSQUIC

// ── Stub definitions when msquic is not available at compile time ─────────────
// These allow the project to parse/IDE-check cleanly on dev hosts without msquic.

struct QuicClientConfig
{
  std::string server_host;
  uint16_t server_port{5000};
  std::string auth_token;
  std::string vehicle_id{"BB_000001"};
  std::string ca_cert_path;
  std::string alpn{"mavlink-quic-v1"};
  uint32_t keepalive_interval_ms{15000};
  uint32_t idle_timeout_ms{60000};
};

using FrameReceivedCallback = std::function<void(std::vector<uint8_t> frame)>;
using ConnectionStateCallback = std::function<void(bool connected)>;

class QuicClient
{
 public:
  explicit QuicClient(QuicClientConfig config);
  ~QuicClient();

  QuicClient(const QuicClient&) = delete;
  QuicClient& operator=(const QuicClient&) = delete;
  QuicClient(QuicClient&&) = delete;
  QuicClient& operator=(QuicClient&&) = delete;

  void setFrameReceivedCallback(FrameReceivedCallback cb);
  void setConnectionStateCallback(ConnectionStateCallback cb);
  void setAuthOkCallback(std::function<void()> cb) { auth_ok_cb_ = std::move(cb); }
  void setAuthFailCallback(std::function<void()> cb) { auth_fail_cb_ = std::move(cb); }

  [[nodiscard]] bool connect();
  [[nodiscard]] bool sendControlFrame(const std::vector<uint8_t>& payload);
  [[nodiscard]] bool sendPriorityFrame(const std::vector<uint8_t>& payload);
  [[nodiscard]] bool sendBulkFrame(const std::vector<uint8_t>& payload);
  void shutdown();
  void processEvents();
  [[nodiscard]] bool isConnected() const noexcept;

 private:
  QuicClientConfig config_;
  std::atomic<bool> connected_{false};

  FrameReceivedCallback frame_cb_;
  ConnectionStateCallback state_cb_;
  std::function<void()> auth_ok_cb_;
  std::function<void()> auth_fail_cb_;
};

#endif  // MAVLINK_QUIC_RELAY_HAVE_MSQUIC

}  // namespace mavlink_quic_relay
