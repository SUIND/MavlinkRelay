#pragma once

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <random>
#include <thread>

#include "mavlink_quic_relay/quic_client.h"
#include "mavlink_quic_relay/ros_interface.h"

namespace mavlink_quic_relay {

/// Manages QUIC reconnection with exponential backoff.
///
/// State machine:
///   DISCONNECTED → CONNECTING → AUTHENTICATING → CONNECTED → DISCONNECTED
///
/// Backoff schedule: 1s → 2s → 4s → 8s → 16s → 30s (cap), ±10% jitter.
/// Auth failure penalty: 60s flat, resets attempt counter.
class ReconnectManager {
public:
    enum class State { DISCONNECTED, CONNECTING, AUTHENTICATING, CONNECTED };

    explicit ReconnectManager(QuicClient& client, RosInterface& ros_iface);
    ~ReconnectManager();

    // Non-copyable, non-movable
    ReconnectManager(const ReconnectManager&) = delete;
    ReconnectManager& operator=(const ReconnectManager&) = delete;
    ReconnectManager(ReconnectManager&&) = delete;
    ReconnectManager& operator=(ReconnectManager&&) = delete;

    /// Start the reconnect background thread.
    void start();

    /// Stop the reconnect thread (blocks until thread exits).
    void stop();

    /// Call when QUIC connection is established (before AUTH).
    void onConnected();

    /// Call when QUIC connection is lost.
    void onDisconnected();

    /// Call when AUTH_OK is received from server.
    void onAuthOk();

    /// Call when AUTH fails.
    void onAuthFailed();

    /// Returns current state.
    [[nodiscard]] State state() const noexcept;

private:
    QuicClient&   quic_client_;
    RosInterface& ros_iface_;

    std::atomic<State>  state_{State::DISCONNECTED};
    std::atomic<bool>   running_{false};
    std::atomic<bool>   should_reconnect_{false};

    std::thread             reconnect_thread_;
    std::mutex              reconnect_mutex_;
    std::condition_variable reconnect_cv_;

    int  reconnect_attempts_{0};
    bool auth_failure_pending_{false};

    std::default_random_engine rng_;

    void reconnectLoop();

    /// Returns exponentially backed-off delay in milliseconds (capped at 30s).
    static int computeBackoffMs(int attempts);
};

}  // namespace mavlink_quic_relay
