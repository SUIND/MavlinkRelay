#pragma once

#include <atomic>
#include <memory>
#include <thread>

#include <ros/ros.h>

#include "mavlink_quic_relay/quic_client.h"
#include "mavlink_quic_relay/ros_interface.h"
#include "mavlink_quic_relay/priority_classifier.h"
#include "mavlink_quic_relay/reconnect_manager.h"

namespace mavlink_quic_relay {

/// Full configuration for RelayNode — loaded from ROS params.
struct RelayNodeConfig {
    QuicClientConfig    quic;                          ///< QUIC client connection settings
    RosInterfaceConfig  ros;                           ///< ROS topic and queue configuration
    std::size_t         priority_queue_size{100};      ///< Max frames in priority outbound queue (drop-oldest on overflow)
    std::size_t         bulk_queue_size{500};           ///< Max frames in bulk outbound queue (drop-oldest on overflow); sets ros.outbound_queue_max
};

/// Orchestrates QuicClient, RosInterface, and PriorityClassifier.
/// Manages the sender thread and coordinates bidirectional MAVLink relay.
class RelayNode {
public:
    explicit RelayNode(ros::NodeHandle& nh, RelayNodeConfig config);
    ~RelayNode();

    // Non-copyable, non-movable
    RelayNode(const RelayNode&) = delete;
    RelayNode& operator=(const RelayNode&) = delete;
    RelayNode(RelayNode&&) = delete;
    RelayNode& operator=(RelayNode&&) = delete;

    /// Start QUIC connection and sender thread.
    void start();

    /// Stop sender thread, shut down QUIC, join all threads.
    void stop();

private:
    RelayNodeConfig config_;

    std::unique_ptr<QuicClient>         quic_client_;
    std::unique_ptr<RosInterface>       ros_interface_;
    std::unique_ptr<PriorityClassifier> classifier_;
    std::unique_ptr<ReconnectManager>   reconnect_manager_;

    std::thread       sender_thread_;
    std::atomic<bool> running_{false};

    // Timer to process QUIC events on ROS thread
    ros::Timer quic_event_timer_;
    ros::NodeHandle& nh_;

    /// Sender thread loop: drains outbound queue, classifies, sends via QUIC.
    void senderLoop();

    /// ROS timer callback (1 ms period): drains the msquic event queue via processEvents().
    /// This is the ONLY place msquic events are dispatched to ROS — do not call
    /// processEvents() from any other thread.
    void quicEventCallback(const ros::TimerEvent& event);

    /// Called when QUIC connection state changes (connected=true) or drops (connected=false).
    /// Dispatched from the ROS timer thread via processEvents().
    void onConnectionStateChanged(bool connected);

    /// Called when a complete MAVLink frame is received from the server.
    /// Dispatched from the ROS timer thread via processEvents(). Pushes to the inbound queue.
    void onFrameReceived(std::vector<uint8_t> frame);

    /// Called when the server returns AUTH_OK on the control stream.
    /// Transitions ReconnectManager to CONNECTED state.
    void onAuthOk();

    /// Called when the server returns AUTH_FAIL on the control stream.
    /// Transitions ReconnectManager to DISCONNECTED and schedules 60s backoff.
    void onAuthFailed();
};

/// Load all RelayNode config from ROS param server.
RelayNodeConfig loadRelayNodeConfig(ros::NodeHandle& nh);

}  // namespace mavlink_quic_relay
