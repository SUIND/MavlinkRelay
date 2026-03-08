#include <gtest/gtest.h>

#include <limits>
#include <unordered_set>

#include "mavlink_quic_relay/priority_classifier.h"

using mavlink_quic_relay::PriorityClassifier;
using mavlink_quic_relay::StreamType;

class PriorityClassifierTest : public ::testing::Test
{
 protected:
  PriorityClassifier classifier;
};

// ---------------------------------------------------------------------------
// All 18 priority msgids — each must return PRIORITY
// ---------------------------------------------------------------------------

TEST_F(PriorityClassifierTest, Heartbeat_IsPriority) { EXPECT_EQ(classifier.classify(0), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, Ping_IsPriority) { EXPECT_EQ(classifier.classify(4), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, ParamRequestList_IsPriority)
{
  EXPECT_EQ(classifier.classify(20), StreamType::PRIORITY);
}

TEST_F(PriorityClassifierTest, ParamValue_IsPriority) { EXPECT_EQ(classifier.classify(22), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, ParamSet_IsPriority) { EXPECT_EQ(classifier.classify(23), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, MissionItem_IsPriority) { EXPECT_EQ(classifier.classify(39), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, MissionRequest_IsPriority) { EXPECT_EQ(classifier.classify(40), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, MissionSetCurrent_IsPriority)
{
  EXPECT_EQ(classifier.classify(41), StreamType::PRIORITY);
}

TEST_F(PriorityClassifierTest, MissionCount_IsPriority) { EXPECT_EQ(classifier.classify(44), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, MissionClearAll_IsPriority) { EXPECT_EQ(classifier.classify(45), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, MissionAck_IsPriority) { EXPECT_EQ(classifier.classify(47), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, MissionRequestInt_IsPriority)
{
  EXPECT_EQ(classifier.classify(51), StreamType::PRIORITY);
}

TEST_F(PriorityClassifierTest, MissionItemInt_IsPriority) { EXPECT_EQ(classifier.classify(73), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, CommandInt_IsPriority) { EXPECT_EQ(classifier.classify(75), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, CommandLong_IsPriority) { EXPECT_EQ(classifier.classify(76), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, CommandAck_IsPriority) { EXPECT_EQ(classifier.classify(77), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, Timesync_IsPriority) { EXPECT_EQ(classifier.classify(111), StreamType::PRIORITY); }

TEST_F(PriorityClassifierTest, StatusText_IsPriority) { EXPECT_EQ(classifier.classify(253), StreamType::PRIORITY); }

// ---------------------------------------------------------------------------
// Bulk msgids — common high-rate telemetry
// ---------------------------------------------------------------------------

TEST_F(PriorityClassifierTest, Attitude_IsBulk) { EXPECT_EQ(classifier.classify(30), StreamType::BULK); }

TEST_F(PriorityClassifierTest, GpsRawInt_IsBulk) { EXPECT_EQ(classifier.classify(24), StreamType::BULK); }

TEST_F(PriorityClassifierTest, RawImu_IsBulk) { EXPECT_EQ(classifier.classify(27), StreamType::BULK); }

TEST_F(PriorityClassifierTest, LocalPositionNed_IsBulk) { EXPECT_EQ(classifier.classify(32), StreamType::BULK); }

TEST_F(PriorityClassifierTest, GlobalPositionInt_IsBulk) { EXPECT_EQ(classifier.classify(33), StreamType::BULK); }

// ---------------------------------------------------------------------------
// Edge cases — unknown / boundary msgids
// ---------------------------------------------------------------------------

TEST_F(PriorityClassifierTest, Unknown_IsBulk) { EXPECT_EQ(classifier.classify(9999), StreamType::BULK); }

TEST_F(PriorityClassifierTest, MaxUint32_IsBulk)
{
  EXPECT_EQ(classifier.classify(std::numeric_limits<uint32_t>::max()), StreamType::BULK);
}

// Msgid 1 is just above 0 (HEARTBEAT) — must not be misclassified as priority
TEST_F(PriorityClassifierTest, MsgId1_IsBulk) { EXPECT_EQ(classifier.classify(1), StreamType::BULK); }

// Msgid 254 is just above 253 (STATUSTEXT) — must not be misclassified
TEST_F(PriorityClassifierTest, MsgId254_IsBulk) { EXPECT_EQ(classifier.classify(254), StreamType::BULK); }

// Msgid 112 is just above 111 (TIMESYNC)
TEST_F(PriorityClassifierTest, MsgId112_IsBulk) { EXPECT_EQ(classifier.classify(112), StreamType::BULK); }

// ---------------------------------------------------------------------------
// priorityIds() inspection
// ---------------------------------------------------------------------------

TEST_F(PriorityClassifierTest, PriorityIds_HasCorrectCount) { EXPECT_EQ(classifier.priorityIds().size(), 18u); }

TEST_F(PriorityClassifierTest, PriorityIds_ContainsHeartbeat)
{
  const auto& ids = classifier.priorityIds();
  EXPECT_NE(ids.find(0), ids.end());
}

TEST_F(PriorityClassifierTest, PriorityIds_ContainsStatusText)
{
  const auto& ids = classifier.priorityIds();
  EXPECT_NE(ids.find(253), ids.end());
}

TEST_F(PriorityClassifierTest, PriorityIds_DoesNotContainBulkMsgId)
{
  const auto& ids = classifier.priorityIds();
  EXPECT_EQ(ids.find(30), ids.end());  // ATTITUDE is not priority
}

// ---------------------------------------------------------------------------
// Custom set constructor
// ---------------------------------------------------------------------------

TEST(PriorityClassifierCustom, CustomSet_OnlyContainsSpecified)
{
  PriorityClassifier c(std::unordered_set<uint32_t>{42, 100});
  EXPECT_EQ(c.classify(42), StreamType::PRIORITY);
  EXPECT_EQ(c.classify(100), StreamType::PRIORITY);
  EXPECT_EQ(c.classify(0), StreamType::BULK);   // HEARTBEAT not in custom set
  EXPECT_EQ(c.classify(76), StreamType::BULK);  // COMMAND_LONG not in custom set
}

TEST(PriorityClassifierCustom, CustomSet_PriorityIds_ReturnsCustomSet)
{
  PriorityClassifier c(std::unordered_set<uint32_t>{42, 100});
  EXPECT_EQ(c.priorityIds().size(), 2u);
  EXPECT_NE(c.priorityIds().find(42), c.priorityIds().end());
  EXPECT_NE(c.priorityIds().find(100), c.priorityIds().end());
}

TEST(PriorityClassifierCustom, EmptyCustomSet_AllBulk)
{
  PriorityClassifier c(std::unordered_set<uint32_t>{});
  EXPECT_EQ(c.classify(0), StreamType::BULK);
  EXPECT_EQ(c.classify(253), StreamType::BULK);
  EXPECT_EQ(c.priorityIds().size(), 0u);
}

TEST(PriorityClassifierCustom, SingleElementSet_Works)
{
  PriorityClassifier c(std::unordered_set<uint32_t>{76});
  EXPECT_EQ(c.classify(76), StreamType::PRIORITY);
  EXPECT_EQ(c.classify(77), StreamType::BULK);
}

// ---------------------------------------------------------------------------
// Classify returns correct enum values (value-based check, not just identity)
// ---------------------------------------------------------------------------

TEST_F(PriorityClassifierTest, StreamType_Priority_ValueIs0)
{
  EXPECT_EQ(static_cast<uint8_t>(StreamType::PRIORITY), 0u);
}

TEST_F(PriorityClassifierTest, StreamType_Bulk_ValueIs1) { EXPECT_EQ(static_cast<uint8_t>(StreamType::BULK), 1u); }

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

int main(int argc, char** argv)
{
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
