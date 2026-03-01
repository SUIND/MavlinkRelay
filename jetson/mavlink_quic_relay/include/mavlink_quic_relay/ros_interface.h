#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <queue>
#include <string>
#include <vector>

#include <ros/ros.h>
#include <mavros_msgs/Mavlink.h>

namespace mavlink_quic_relay {

/// A single MAVLink frame with its msgid, for routing/queuing.
struct MavlinkFrame {
    uint32_t             msgid{0};     ///< MAVLink message ID for priority classification
    std::vector<uint8_t> raw_bytes;    ///< Complete raw MAVLink frame bytes
};

/// Configuration for RosInterface queue sizes and topic names.
struct RosInterfaceConfig {
    std::string mavlink_from_topic{"/mavlink/from"};
    std::string mavlink_to_topic{"/mavlink/to"};
    std::size_t outbound_queue_max{500};    ///< Max frames in outbound queue (FC→server)
    std::size_t inbound_queue_max{500};     ///< Max frames in inbound queue (server→FC)
    ros::Duration drain_period{0.001};      ///< Timer period for inbound queue drain (1ms)
    double no_message_warn_timeout_s{10.0}; ///< Warn if no msgs after this many seconds
};

/// Thread-safe bounded queue for MavlinkFrame objects.
/// Producer: ROS subscriber callback (outbound) or msquic callback via pushInbound (inbound).
/// Consumer: sender thread (outbound) or ROS timer drain callback (inbound).
class BoundedQueue {
public:
    explicit BoundedQueue(std::size_t max_size);

    /// Push a frame. If queue is full, drops the OLDEST entry (pop front, push back).
    /// Thread-safe.
    void push(MavlinkFrame frame);

    /// Try to pop a frame. Returns std::nullopt if empty.
    /// Thread-safe.
    [[nodiscard]] std::optional<MavlinkFrame> tryPop();

    /// Returns current queue size (snapshot — may be stale immediately).
    [[nodiscard]] std::size_t size() const;

    /// Drain all frames (e.g., on reconnect for stale bulk data).
    void clear();

private:
    mutable std::mutex mutex_;
    std::queue<MavlinkFrame> queue_;
    std::size_t max_size_;
};

/// Manages ROS subscriber, publisher, and cross-thread queues.
class RosInterface {
public:
    explicit RosInterface(ros::NodeHandle& nh, RosInterfaceConfig config);
    ~RosInterface() = default;

    // Non-copyable
    RosInterface(const RosInterface&) = delete;
    RosInterface& operator=(const RosInterface&) = delete;

    /// Called by RelayNode sender thread to drain the outbound queue.
    [[nodiscard]] std::optional<MavlinkFrame> popOutbound();

    /// Called by QuicClient receive path (msquic thread) to enqueue inbound frame.
    /// Thread-safe — safe to call from any thread.
    void pushInbound(MavlinkFrame frame);

    /// Clear the bulk outbound queue (called on reconnect to drop stale data).
    void clearOutboundQueue();

private:
    ros::NodeHandle& nh_;
    RosInterfaceConfig config_;

    ros::Subscriber mavlink_sub_;
    ros::Publisher  mavlink_pub_;
    ros::Timer      drain_timer_;

    BoundedQueue outbound_queue_;
    BoundedQueue inbound_queue_;

    std::atomic<bool> received_any_message_{false};
    bool warn_logged_{false};
    ros::Time node_start_time_;

    /// ROS subscriber callback — runs on ROS thread.
    void mavlinkFromCallback(const mavros_msgs::Mavlink::ConstPtr& msg);

    /// ROS timer callback — drains inbound queue and publishes to /mavlink/to.
    /// Runs on ROS spinner thread — safe for ros::Publisher::publish().
    void drainInboundCallback(const ros::TimerEvent& event);

    /// Convert mavros_msgs::Mavlink to raw MAVLink bytes.
    /// MAVLink v2: magic(1) + len(1) + incompat_flags(1) + compat_flags(1) + seq(1) +
    ///             sysid(1) + compid(1) + msgid_low(1) + msgid_mid(1) + msgid_high(1) +
    ///             payload(len bytes) + checksum(2)
    /// MAVLink v1: magic(1) + len(1) + seq(1) + sysid(1) + compid(1) +
    ///             msgid(1) + payload(len bytes) + checksum(2)
    static std::vector<uint8_t> toRawBytes(const mavros_msgs::Mavlink& msg);

    /// Convert raw MAVLink bytes back to mavros_msgs::Mavlink.
    static mavros_msgs::Mavlink fromRawBytes(const std::vector<uint8_t>& raw);
};

}  // namespace mavlink_quic_relay
