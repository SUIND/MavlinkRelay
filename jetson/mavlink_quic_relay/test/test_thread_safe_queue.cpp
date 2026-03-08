#include <gtest/gtest.h>
#include <ros/time.h>

#include <set>
#include <thread>
#include <vector>

#include "mavlink_quic_relay/ros_interface.h"

using mavlink_quic_relay::BoundedQueue;
using mavlink_quic_relay::MavlinkFrame;

static MavlinkFrame makeFrame(uint32_t msgid)
{
  return MavlinkFrame{msgid, {0xFD, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01}};
}

TEST(BoundedQueueTest, EmptyQueueReturnsNullopt)
{
  BoundedQueue q(10);
  EXPECT_FALSE(q.tryPop().has_value());
}

TEST(BoundedQueueTest, PushAndPop_SingleElement)
{
  BoundedQueue q(10);
  q.push(makeFrame(42));
  auto f = q.tryPop();
  ASSERT_TRUE(f.has_value());
  EXPECT_EQ(f->msgid, 42u);
  EXPECT_FALSE(q.tryPop().has_value());
}

TEST(BoundedQueueTest, FIFO_OrderPreserved)
{
  BoundedQueue q(10);
  for (uint32_t i = 0; i < 5; ++i)
  {
    q.push(makeFrame(i));
  }
  for (uint32_t i = 0; i < 5; ++i)
  {
    auto f = q.tryPop();
    ASSERT_TRUE(f.has_value());
    EXPECT_EQ(f->msgid, i);
  }
}

TEST(BoundedQueueTest, DropOldest_WhenFull)
{
  BoundedQueue q(3);
  q.push(makeFrame(10));
  q.push(makeFrame(20));
  q.push(makeFrame(30));
  q.push(makeFrame(40));
  EXPECT_EQ(q.size(), 3u);
  EXPECT_EQ(q.tryPop()->msgid, 20u);
  EXPECT_EQ(q.tryPop()->msgid, 30u);
  EXPECT_EQ(q.tryPop()->msgid, 40u);
}

TEST(BoundedQueueTest, DropOldest_MultipleOverflows)
{
  BoundedQueue q(2);
  q.push(makeFrame(1));
  q.push(makeFrame(2));
  q.push(makeFrame(3));
  q.push(makeFrame(4));
  EXPECT_EQ(q.size(), 2u);
  EXPECT_EQ(q.tryPop()->msgid, 3u);
  EXPECT_EQ(q.tryPop()->msgid, 4u);
}

TEST(BoundedQueueTest, Clear_EmptiesQueue)
{
  BoundedQueue q(10);
  q.push(makeFrame(1));
  q.push(makeFrame(2));
  q.clear();
  EXPECT_EQ(q.size(), 0u);
  EXPECT_FALSE(q.tryPop().has_value());
}

TEST(BoundedQueueTest, Clear_ThenPush_Works)
{
  BoundedQueue q(5);
  for (uint32_t i = 0; i < 5; ++i)
  {
    q.push(makeFrame(i));
  }
  q.clear();
  q.push(makeFrame(99));
  auto f = q.tryPop();
  ASSERT_TRUE(f.has_value());
  EXPECT_EQ(f->msgid, 99u);
}

TEST(BoundedQueueTest, Size_ReflectsPushes)
{
  BoundedQueue q(10);
  EXPECT_EQ(q.size(), 0u);
  q.push(makeFrame(1));
  EXPECT_EQ(q.size(), 1u);
  q.push(makeFrame(2));
  EXPECT_EQ(q.size(), 2u);
}

TEST(BoundedQueueTest, Size_ReflectsPops)
{
  BoundedQueue q(10);
  q.push(makeFrame(1));
  q.push(makeFrame(2));
  (void)q.tryPop();
  EXPECT_EQ(q.size(), 1u);
  (void)q.tryPop();
  EXPECT_EQ(q.size(), 0u);
}

TEST(BoundedQueueTest, SizeOne_DropOldestOnOverflow)
{
  BoundedQueue q(1);
  q.push(makeFrame(100));
  q.push(makeFrame(200));
  EXPECT_EQ(q.size(), 1u);
  EXPECT_EQ(q.tryPop()->msgid, 200u);
}

TEST(BoundedQueueTest, RawBytes_PreservedThroughPushPop)
{
  BoundedQueue q(5);
  std::vector<uint8_t> payload = {0xFD, 0x09, 0x00, 0x01, 0x02};
  MavlinkFrame frame{76, payload};
  q.push(frame);
  auto out = q.tryPop();
  ASSERT_TRUE(out.has_value());
  EXPECT_EQ(out->msgid, 76u);
  EXPECT_EQ(out->raw_bytes, payload);
}

TEST(BoundedQueueTest, MultiThreaded_ConcurrentPushPop_NoDataLoss)
{
  const int kFrames = 1000;
  const std::size_t kQueueSize = 2000;
  BoundedQueue q(kQueueSize);

  std::thread producer(
      [&]()
      {
        for (int i = 0; i < kFrames; ++i)
        {
          q.push(makeFrame(static_cast<uint32_t>(i)));
        }
      });

  std::vector<uint32_t> received;
  received.reserve(kFrames);
  std::thread consumer(
      [&]()
      {
        int count = 0;
        while (count < kFrames)
        {
          auto f = q.tryPop();
          if (f)
          {
            received.push_back(f->msgid);
            ++count;
          }
          else
          {
            std::this_thread::yield();
          }
        }
      });

  producer.join();
  consumer.join();

  EXPECT_EQ(received.size(), static_cast<std::size_t>(kFrames));
  std::set<uint32_t> unique(received.begin(), received.end());
  EXPECT_EQ(unique.size(), static_cast<std::size_t>(kFrames));
}

TEST(BoundedQueueTest, MultiThreaded_MultiplePushers_NoCrash)
{
  const int kFramesPerThread = 200;
  const int kThreads = 4;
  const std::size_t kQueueSize = 5000;
  BoundedQueue q(kQueueSize);

  std::vector<std::thread> pushers;
  for (int t = 0; t < kThreads; ++t)
  {
    pushers.emplace_back(
        [&, t]()
        {
          for (int i = 0; i < kFramesPerThread; ++i)
          {
            q.push(makeFrame(static_cast<uint32_t>(t * 10000 + i)));
          }
        });
  }

  for (auto& th : pushers)
  {
    th.join();
  }

  const std::size_t expected = static_cast<std::size_t>(kThreads * kFramesPerThread);
  EXPECT_EQ(q.size(), expected);
}

int main(int argc, char** argv)
{
  ros::Time::init();
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
