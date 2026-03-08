#pragma once

#include <cstdint>
#include <unordered_set>

namespace mavlink_quic_relay
{

/// Stream routing type for a MAVLink message.
enum class StreamType : uint8_t
{
  PRIORITY = 0,  ///< Control-critical: commands, params, heartbeat → Stream 4
  BULK = 1,      ///< High-rate telemetry: attitude, IMU, GPS → Stream 8
};

/// Classifies MAVLink messages by msgid into PRIORITY or BULK stream.
/// Pure C++17 utility — no ROS or QUIC dependencies.
class PriorityClassifier
{
 public:
  /// Construct with default MAVLink priority msgid set.
  PriorityClassifier();

  /// Construct with a custom priority msgid set (for testing/overrides).
  explicit PriorityClassifier(std::unordered_set<uint32_t> priority_ids);

  /// Classify a MAVLink message by its msgid.
  /// @param msgid  MAVLink message ID (from mavros_msgs::Mavlink::msgid)
  /// @return StreamType::PRIORITY if msgid is in priority set, else StreamType::BULK
  [[nodiscard]] StreamType classify(uint32_t msgid) const noexcept;

  /// Returns the set of priority msgids (for inspection/logging).
  [[nodiscard]] const std::unordered_set<uint32_t>& priorityIds() const noexcept;

 private:
  std::unordered_set<uint32_t> priority_ids_;
};

}  // namespace mavlink_quic_relay
