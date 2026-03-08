#include <gtest/gtest.h>

#include <cstdint>
#include <stdexcept>
#include <vector>

static std::vector<uint8_t> encodeFrame(const std::vector<uint8_t>& payload)
{
  if (payload.empty())
  {
    throw std::invalid_argument("empty payload");
  }
  std::vector<uint8_t> result;
  result.reserve(2 + payload.size());
  const uint16_t len = static_cast<uint16_t>(payload.size());
  result.push_back(static_cast<uint8_t>(len & 0xFF));
  result.push_back(static_cast<uint8_t>((len >> 8) & 0xFF));
  result.insert(result.end(), payload.begin(), payload.end());
  return result;
}

struct FrameDecoder
{
  std::vector<uint8_t> buf;

  std::vector<std::vector<uint8_t>> feed(const uint8_t* data, std::size_t len)
  {
    buf.insert(buf.end(), data, data + len);
    std::vector<std::vector<uint8_t>> frames;
    while (buf.size() >= 2)
    {
      const uint16_t flen = static_cast<uint16_t>(buf[0]) | (static_cast<uint16_t>(buf[1]) << 8);
      if (flen == 0)
      {
        buf.erase(buf.begin(), buf.begin() + 2);
        continue;
      }
      if (buf.size() < static_cast<std::size_t>(2 + flen))
      {
        break;
      }
      frames.emplace_back(buf.begin() + 2, buf.begin() + 2 + flen);
      buf.erase(buf.begin(), buf.begin() + 2 + flen);
    }
    return frames;
  }
};

TEST(MavlinkFramingTest, Encode_SmallPayload)
{
  const std::vector<uint8_t> payload = {0x01, 0x02, 0x03};
  const auto encoded = encodeFrame(payload);
  ASSERT_EQ(encoded.size(), 5u);
  EXPECT_EQ(encoded[0], 0x03);
  EXPECT_EQ(encoded[1], 0x00);
  EXPECT_EQ(encoded[2], 0x01);
  EXPECT_EQ(encoded[3], 0x02);
  EXPECT_EQ(encoded[4], 0x03);
}

TEST(MavlinkFramingTest, Encode_LengthIsLittleEndian)
{
  const std::vector<uint8_t> payload(256, 0xAA);
  const auto encoded = encodeFrame(payload);
  EXPECT_EQ(encoded[0], 0x00);
  EXPECT_EQ(encoded[1], 0x01);
}

TEST(MavlinkFramingTest, Encode_LengthField_255Bytes)
{
  const std::vector<uint8_t> payload(255, 0xBB);
  const auto encoded = encodeFrame(payload);
  ASSERT_EQ(encoded.size(), 257u);
  EXPECT_EQ(encoded[0], 0xFF);
  EXPECT_EQ(encoded[1], 0x00);
}

TEST(MavlinkFramingTest, Encode_MaxFrameSize)
{
  const std::vector<uint8_t> payload(280, 0xFF);
  const auto encoded = encodeFrame(payload);
  EXPECT_EQ(encoded.size(), 282u);
  const uint16_t decoded_len = static_cast<uint16_t>(encoded[0]) | (static_cast<uint16_t>(encoded[1]) << 8);
  EXPECT_EQ(decoded_len, 280u);
}

TEST(MavlinkFramingTest, Encode_SingleByte_Payload)
{
  const std::vector<uint8_t> payload = {0xAB};
  const auto encoded = encodeFrame(payload);
  ASSERT_EQ(encoded.size(), 3u);
  EXPECT_EQ(encoded[0], 0x01);
  EXPECT_EQ(encoded[1], 0x00);
  EXPECT_EQ(encoded[2], 0xAB);
}

TEST(MavlinkFramingTest, Encode_EmptyPayload_Throws) { EXPECT_THROW(encodeFrame({}), std::invalid_argument); }

TEST(MavlinkFramingTest, Decode_SingleFrame)
{
  const std::vector<uint8_t> payload = {0xFD, 0x05, 0x00};
  const auto encoded = encodeFrame(payload);
  FrameDecoder dec;
  const auto frames = dec.feed(encoded.data(), encoded.size());
  ASSERT_EQ(frames.size(), 1u);
  EXPECT_EQ(frames[0], payload);
}

TEST(MavlinkFramingTest, Decode_MultipleFramesInOneBuffer)
{
  const std::vector<uint8_t> p1 = {0x01, 0x02};
  const std::vector<uint8_t> p2 = {0x03, 0x04, 0x05};
  auto combined = encodeFrame(p1);
  const auto enc2 = encodeFrame(p2);
  combined.insert(combined.end(), enc2.begin(), enc2.end());

  FrameDecoder dec;
  const auto frames = dec.feed(combined.data(), combined.size());
  ASSERT_EQ(frames.size(), 2u);
  EXPECT_EQ(frames[0], p1);
  EXPECT_EQ(frames[1], p2);
}

TEST(MavlinkFramingTest, Decode_PartialFrame_HandledCorrectly)
{
  const std::vector<uint8_t> payload = {0xAA, 0xBB, 0xCC, 0xDD};
  const auto encoded = encodeFrame(payload);

  FrameDecoder dec;
  const auto frames1 = dec.feed(encoded.data(), 3);
  EXPECT_TRUE(frames1.empty());
  const auto frames2 = dec.feed(encoded.data() + 3, encoded.size() - 3);
  ASSERT_EQ(frames2.size(), 1u);
  EXPECT_EQ(frames2[0], payload);
}

TEST(MavlinkFramingTest, Decode_PartialHeader_OnlyOneByte)
{
  const std::vector<uint8_t> payload = {0x11, 0x22};
  const auto encoded = encodeFrame(payload);

  FrameDecoder dec;
  const auto frames1 = dec.feed(encoded.data(), 1);
  EXPECT_TRUE(frames1.empty());
  const auto frames2 = dec.feed(encoded.data() + 1, encoded.size() - 1);
  ASSERT_EQ(frames2.size(), 1u);
  EXPECT_EQ(frames2[0], payload);
}

TEST(MavlinkFramingTest, Decode_ByteByByte_ReassemblesCorrectly)
{
  const std::vector<uint8_t> payload = {0x10, 0x20, 0x30, 0x40, 0x50};
  const auto encoded = encodeFrame(payload);

  FrameDecoder dec;
  std::vector<std::vector<uint8_t>> all_frames;
  for (std::size_t i = 0; i < encoded.size(); ++i)
  {
    auto frames = dec.feed(encoded.data() + i, 1);
    all_frames.insert(all_frames.end(), frames.begin(), frames.end());
  }
  ASSERT_EQ(all_frames.size(), 1u);
  EXPECT_EQ(all_frames[0], payload);
}

TEST(MavlinkFramingTest, Decode_TenFramesBackToBack)
{
  std::vector<uint8_t> buf;
  std::vector<std::vector<uint8_t>> payloads;
  for (int i = 1; i <= 10; ++i)
  {
    std::vector<uint8_t> p(static_cast<std::size_t>(i), static_cast<uint8_t>(i));
    payloads.push_back(p);
    const auto enc = encodeFrame(p);
    buf.insert(buf.end(), enc.begin(), enc.end());
  }

  FrameDecoder dec;
  const auto frames = dec.feed(buf.data(), buf.size());
  ASSERT_EQ(frames.size(), 10u);
  for (int i = 0; i < 10; ++i)
  {
    EXPECT_EQ(frames[static_cast<std::size_t>(i)], payloads[static_cast<std::size_t>(i)]);
  }
}

TEST(MavlinkFramingTest, RoundTrip_EncodeDecode)
{
  const std::vector<uint8_t> heartbeat = {0xFD, 0x09, 0x00, 0x00, 0x01, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x00};
  const auto encoded = encodeFrame(heartbeat);
  FrameDecoder dec;
  const auto frames = dec.feed(encoded.data(), encoded.size());
  ASSERT_EQ(frames.size(), 1u);
  EXPECT_EQ(frames[0], heartbeat);
}

TEST(MavlinkFramingTest, RoundTrip_V1Heartbeat)
{
  const std::vector<uint8_t> v1_heartbeat = {0xFE, 0x09, 0x00, 0x01, 0x01, 0x00, 0x00, 0x00,
                                             0x00, 0x00, 0x06, 0x08, 0x00, 0x00, 0x03};
  const auto encoded = encodeFrame(v1_heartbeat);
  FrameDecoder dec;
  const auto frames = dec.feed(encoded.data(), encoded.size());
  ASSERT_EQ(frames.size(), 1u);
  EXPECT_EQ(frames[0], v1_heartbeat);
}

TEST(MavlinkFramingTest, Decode_BufferRetainedBetweenFeeds)
{
  const std::vector<uint8_t> p1 = {0xAA, 0xBB};
  const std::vector<uint8_t> p2 = {0xCC, 0xDD};
  const auto e1 = encodeFrame(p1);
  const auto e2 = encodeFrame(p2);

  FrameDecoder dec;
  const auto f1 = dec.feed(e1.data(), e1.size());
  ASSERT_EQ(f1.size(), 1u);
  EXPECT_EQ(f1[0], p1);

  const auto f2 = dec.feed(e2.data(), e2.size());
  ASSERT_EQ(f2.size(), 1u);
  EXPECT_EQ(f2[0], p2);
}

int main(int argc, char** argv)
{
  ::testing::InitGoogleTest(&argc, argv);
  return RUN_ALL_TESTS();
}
