#include "mavlink_quic_relay/priority_classifier.h"

namespace mavlink_quic_relay
{

PriorityClassifier::PriorityClassifier()
    : priority_ids_({
          0,    // HEARTBEAT
          4,    // PING
          20,   // PARAM_REQUEST_READ / PARAM_REQUEST_LIST
          22,   // PARAM_VALUE
          23,   // PARAM_SET
          39,   // MISSION_ITEM
          40,   // MISSION_REQUEST
          41,   // MISSION_SET_CURRENT
          44,   // MISSION_COUNT
          45,   // MISSION_CLEAR_ALL
          47,   // MISSION_ACK
          51,   // MISSION_REQUEST_INT
          73,   // MISSION_ITEM_INT
          75,   // COMMAND_INT
          76,   // COMMAND_LONG
          77,   // COMMAND_ACK
          111,  // TIMESYNC
          253,  // STATUSTEXT
      })
{
}

PriorityClassifier::PriorityClassifier(std::unordered_set<uint32_t> priority_ids)
    : priority_ids_(std::move(priority_ids))
{
}

StreamType PriorityClassifier::classify(uint32_t msgid) const noexcept
{
  return priority_ids_.count(msgid) > 0 ? StreamType::PRIORITY : StreamType::BULK;
}

const std::unordered_set<uint32_t>& PriorityClassifier::priorityIds() const noexcept { return priority_ids_; }

}  // namespace mavlink_quic_relay
