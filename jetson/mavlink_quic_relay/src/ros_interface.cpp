#include "mavlink_quic_relay/ros_interface.h"

#include <cstdint>
#include <stdexcept>

namespace mavlink_quic_relay {

// ---------------------------------------------------------------------------
// BoundedQueue
// ---------------------------------------------------------------------------

BoundedQueue::BoundedQueue(std::size_t max_size)
    : max_size_(max_size)
{
}

void BoundedQueue::push(MavlinkFrame frame)
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (queue_.size() >= max_size_) {
        queue_.pop();
    }
    queue_.push(std::move(frame));
}

std::optional<MavlinkFrame> BoundedQueue::tryPop()
{
    std::lock_guard<std::mutex> lock(mutex_);
    if (queue_.empty()) {
        return std::nullopt;
    }
    MavlinkFrame frame = std::move(queue_.front());
    queue_.pop();
    return frame;
}

std::size_t BoundedQueue::size() const
{
    std::lock_guard<std::mutex> lock(mutex_);
    return queue_.size();
}

void BoundedQueue::clear()
{
    std::lock_guard<std::mutex> lock(mutex_);
    while (!queue_.empty()) {
        queue_.pop();
    }
}

// ---------------------------------------------------------------------------
// RosInterface
// ---------------------------------------------------------------------------

RosInterface::RosInterface(ros::NodeHandle& nh, RosInterfaceConfig config)
    : nh_(nh)
    , config_(std::move(config))
    , outbound_queue_(config_.outbound_queue_max)
    , inbound_queue_(config_.inbound_queue_max)
{
    mavlink_sub_ = nh_.subscribe<mavros_msgs::Mavlink>(
        config_.mavlink_from_topic,
        100,
        &RosInterface::mavlinkFromCallback,
        this);

    mavlink_pub_ = nh_.advertise<mavros_msgs::Mavlink>(
        config_.mavlink_to_topic,
        100);

    drain_timer_ = nh_.createTimer(
        config_.drain_period,
        &RosInterface::drainInboundCallback,
        this);

    node_start_time_ = ros::Time::now();
}

std::optional<MavlinkFrame> RosInterface::popOutbound()
{
    return outbound_queue_.tryPop();
}

void RosInterface::pushInbound(MavlinkFrame frame)
{
    inbound_queue_.push(std::move(frame));
}

void RosInterface::clearOutboundQueue()
{
    outbound_queue_.clear();
}

void RosInterface::mavlinkFromCallback(const mavros_msgs::Mavlink::ConstPtr& msg)
{
    received_any_message_.store(true, std::memory_order_relaxed);

    MavlinkFrame frame;
    frame.msgid     = static_cast<uint32_t>(msg->msgid);
    frame.raw_bytes = toRawBytes(*msg);

    ROS_DEBUG_STREAM("Received MAVLink msgid=" << msg->msgid);

    outbound_queue_.push(std::move(frame));
}

void RosInterface::drainInboundCallback(const ros::TimerEvent& /*event*/)
{
    if (!warn_logged_ && !received_any_message_.load(std::memory_order_relaxed)) {
        const double elapsed = (ros::Time::now() - node_start_time_).toSec();
        if (elapsed > config_.no_message_warn_timeout_s) {
            ROS_WARN("No MAVLink messages received on /mavlink/from -- is the FC node running?");
            warn_logged_ = true;
        }
    }

    constexpr int kMaxDrainPerTick = 10;
    for (int i = 0; i < kMaxDrainPerTick; ++i) {
        auto frame = inbound_queue_.tryPop();
        if (!frame) {
            break;
        }
        mavlink_pub_.publish(fromRawBytes(frame->raw_bytes));
    }
}

// ---------------------------------------------------------------------------
// toRawBytes — mavros_msgs::Mavlink → wire bytes
// ---------------------------------------------------------------------------

std::vector<uint8_t> RosInterface::toRawBytes(const mavros_msgs::Mavlink& msg)
{
    const uint8_t magic = static_cast<uint8_t>(msg.magic);

    if (magic == 0xFE) {
        // MAVLink v1: [magic][len][seq][sysid][compid][msgid(1)][payload][cksum(2)]
        const std::size_t total = 6 + msg.len + 2;
        std::vector<uint8_t> raw;
        raw.reserve(total);

        raw.push_back(magic);
        raw.push_back(static_cast<uint8_t>(msg.len));
        raw.push_back(static_cast<uint8_t>(msg.seq));
        raw.push_back(static_cast<uint8_t>(msg.sysid));
        raw.push_back(static_cast<uint8_t>(msg.compid));
        raw.push_back(static_cast<uint8_t>(msg.msgid & 0xFF));

        // Unpack payload from payload64 (big-endian word packing used by mavros)
        std::size_t bytes_written = 0;
        for (uint64_t word : msg.payload64) {
            for (int shift = 56; shift >= 0 && bytes_written < msg.len; shift -= 8) {
                raw.push_back(static_cast<uint8_t>((word >> shift) & 0xFF));
                ++bytes_written;
            }
        }

        const uint16_t cksum = static_cast<uint16_t>(msg.checksum & 0xFFFF);
        raw.push_back(static_cast<uint8_t>(cksum & 0xFF));
        raw.push_back(static_cast<uint8_t>((cksum >> 8) & 0xFF));

        return raw;
    }

    // MAVLink v2 (0xFD):
    // [magic][len][incompat_flags][compat_flags][seq][sysid][compid]
    // [msgid_low][msgid_mid][msgid_high][payload(len)][cksum(2)]
    const std::size_t total = 10 + msg.len + 2;
    std::vector<uint8_t> raw;
    raw.reserve(total);

    raw.push_back(magic);
    raw.push_back(static_cast<uint8_t>(msg.len));
    raw.push_back(static_cast<uint8_t>(msg.incompat_flags));
    raw.push_back(static_cast<uint8_t>(msg.compat_flags));
    raw.push_back(static_cast<uint8_t>(msg.seq));
    raw.push_back(static_cast<uint8_t>(msg.sysid));
    raw.push_back(static_cast<uint8_t>(msg.compid));

    const uint32_t msgid32 = static_cast<uint32_t>(msg.msgid);
    raw.push_back(static_cast<uint8_t>( msgid32        & 0xFF));
    raw.push_back(static_cast<uint8_t>((msgid32 >>  8) & 0xFF));
    raw.push_back(static_cast<uint8_t>((msgid32 >> 16) & 0xFF));

    // Unpack payload from payload64 (big-endian word packing used by mavros)
    std::size_t bytes_written = 0;
    for (uint64_t word : msg.payload64) {
        for (int shift = 56; shift >= 0 && bytes_written < msg.len; shift -= 8) {
            raw.push_back(static_cast<uint8_t>((word >> shift) & 0xFF));
            ++bytes_written;
        }
    }

    const uint16_t cksum = static_cast<uint16_t>(msg.checksum & 0xFFFF);
    raw.push_back(static_cast<uint8_t>(cksum & 0xFF));
    raw.push_back(static_cast<uint8_t>((cksum >> 8) & 0xFF));

    return raw;
}

// ---------------------------------------------------------------------------
// fromRawBytes — wire bytes → mavros_msgs::Mavlink
// ---------------------------------------------------------------------------

mavros_msgs::Mavlink RosInterface::fromRawBytes(const std::vector<uint8_t>& raw)
{
    mavros_msgs::Mavlink msg;

    if (raw.empty()) {
        return msg;
    }

    const uint8_t magic = raw[0];
    msg.magic = magic;

    if (magic == 0xFE) {
        // MAVLink v1 minimum: 6 header + payload + 2 checksum = at least 8 bytes
        if (raw.size() < 8) {
            ROS_WARN("fromRawBytes: MAVLink v1 frame too short (%zu bytes)", raw.size());
            return msg;
        }

        msg.len     = raw[1];
        msg.seq     = raw[2];
        msg.sysid   = raw[3];
        msg.compid  = raw[4];
        msg.msgid   = raw[5];

        const std::size_t payload_start = 6;
        const std::size_t payload_end   = payload_start + msg.len;

        if (raw.size() < payload_end + 2) {
            ROS_WARN("fromRawBytes: MAVLink v1 frame truncated");
            return msg;
        }

        // Pack payload bytes into payload64 words (big-endian, pad last word)
        const uint8_t* p     = raw.data() + payload_start;
        std::size_t    remaining = msg.len;
        while (remaining > 0) {
            uint64_t word = 0;
            for (int shift = 56; shift >= 0 && remaining > 0; shift -= 8, --remaining) {
                word |= (static_cast<uint64_t>(*p++) << shift);
            }
            msg.payload64.push_back(word);
        }

        const uint8_t ckl = raw[payload_end];
        const uint8_t ckh = raw[payload_end + 1];
        msg.checksum = static_cast<uint64_t>(ckl) | (static_cast<uint64_t>(ckh) << 8);

        return msg;
    }

    // MAVLink v2 minimum: 10 header + payload + 2 checksum = at least 12 bytes
    if (raw.size() < 12) {
        ROS_WARN("fromRawBytes: MAVLink v2 frame too short (%zu bytes)", raw.size());
        return msg;
    }

    msg.len           = raw[1];
    msg.incompat_flags = raw[2];
    msg.compat_flags  = raw[3];
    msg.seq           = raw[4];
    msg.sysid         = raw[5];
    msg.compid        = raw[6];
    msg.msgid = static_cast<uint64_t>(raw[7])
              | (static_cast<uint64_t>(raw[8]) << 8)
              | (static_cast<uint64_t>(raw[9]) << 16);

    const std::size_t payload_start = 10;
    const std::size_t payload_end   = payload_start + msg.len;

    if (raw.size() < payload_end + 2) {
        ROS_WARN("fromRawBytes: MAVLink v2 frame truncated");
        return msg;
    }

    // Pack payload bytes into payload64 words (big-endian, pad last word)
    const uint8_t* p     = raw.data() + payload_start;
    std::size_t    remaining = msg.len;
    while (remaining > 0) {
        uint64_t word = 0;
        for (int shift = 56; shift >= 0 && remaining > 0; shift -= 8, --remaining) {
            word |= (static_cast<uint64_t>(*p++) << shift);
        }
        msg.payload64.push_back(word);
    }

    const uint8_t ckl = raw[payload_end];
    const uint8_t ckh = raw[payload_end + 1];
    msg.checksum = static_cast<uint64_t>(ckl) | (static_cast<uint64_t>(ckh) << 8);

    return msg;
}

}  // namespace mavlink_quic_relay
