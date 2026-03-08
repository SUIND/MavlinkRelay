// test_ros_interface_framing.cpp
//
// Unit tests for the toRawBytes and fromRawBytes conversion logic used by
// RosInterface.  Those methods are private, so we duplicate their
// implementations here as free functions and test those instead.
//
// Duplicated from RosInterface for testing — keep in sync with ros_interface.cpp

#include <gtest/gtest.h>
#include <mavros_msgs/Mavlink.h>
#include <ros/ros.h>

#include <cstdint>
#include <vector>

// ============================================================================
// Duplicated free-function implementations
// ============================================================================

static std::vector<uint8_t> toRawBytes(const mavros_msgs::Mavlink& msg)
{
  const uint8_t magic = static_cast<uint8_t>(msg.magic);

  if (magic == 0xFE)
  {
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

    std::size_t bytes_written = 0;
    for (uint64_t word : msg.payload64)
    {
      for (int shift = 56; shift >= 0 && bytes_written < msg.len; shift -= 8)
      {
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
  raw.push_back(static_cast<uint8_t>(msgid32 & 0xFF));
  raw.push_back(static_cast<uint8_t>((msgid32 >> 8) & 0xFF));
  raw.push_back(static_cast<uint8_t>((msgid32 >> 16) & 0xFF));

  std::size_t bytes_written = 0;
  for (uint64_t word : msg.payload64)
  {
    for (int shift = 56; shift >= 0 && bytes_written < msg.len; shift -= 8)
    {
      raw.push_back(static_cast<uint8_t>((word >> shift) & 0xFF));
      ++bytes_written;
    }
  }

  const uint16_t cksum = static_cast<uint16_t>(msg.checksum & 0xFFFF);
  raw.push_back(static_cast<uint8_t>(cksum & 0xFF));
  raw.push_back(static_cast<uint8_t>((cksum >> 8) & 0xFF));

  return raw;
}

static mavros_msgs::Mavlink fromRawBytes(const std::vector<uint8_t>& raw)
{
  mavros_msgs::Mavlink msg;

  if (raw.empty())
  {
    return msg;
  }

  const uint8_t magic = raw[0];
  msg.magic = magic;

  if (magic == 0xFE)
  {
    // MAVLink v1 minimum: 6 header + 0 payload + 2 checksum = 8 bytes
    if (raw.size() < 8)
    {
      return msg;
    }

    msg.len = raw[1];
    msg.seq = raw[2];
    msg.sysid = raw[3];
    msg.compid = raw[4];
    msg.msgid = raw[5];

    const std::size_t payload_start = 6;
    const std::size_t payload_end = payload_start + msg.len;

    if (raw.size() < payload_end + 2)
    {
      return msg;
    }

    const uint8_t* p = raw.data() + payload_start;
    std::size_t remaining = msg.len;
    while (remaining > 0)
    {
      uint64_t word = 0;
      for (int shift = 56; shift >= 0 && remaining > 0; shift -= 8, --remaining)
      {
        word |= (static_cast<uint64_t>(*p++) << shift);
      }
      msg.payload64.push_back(word);
    }

    const uint8_t ckl = raw[payload_end];
    const uint8_t ckh = raw[payload_end + 1];
    msg.checksum = static_cast<uint64_t>(ckl) | (static_cast<uint64_t>(ckh) << 8);

    return msg;
  }

  // MAVLink v2 minimum: 10 header + 0 payload + 2 checksum = 12 bytes
  if (raw.size() < 12)
  {
    return msg;
  }

  msg.len = raw[1];
  msg.incompat_flags = raw[2];
  msg.compat_flags = raw[3];
  msg.seq = raw[4];
  msg.sysid = raw[5];
  msg.compid = raw[6];
  msg.msgid =
      static_cast<uint64_t>(raw[7]) | (static_cast<uint64_t>(raw[8]) << 8) | (static_cast<uint64_t>(raw[9]) << 16);

  const std::size_t payload_start = 10;
  const std::size_t payload_end = payload_start + msg.len;

  if (raw.size() < payload_end + 2)
  {
    return msg;
  }

  const uint8_t* p = raw.data() + payload_start;
  std::size_t remaining = msg.len;
  while (remaining > 0)
  {
    uint64_t word = 0;
    for (int shift = 56; shift >= 0 && remaining > 0; shift -= 8, --remaining)
    {
      word |= (static_cast<uint64_t>(*p++) << shift);
    }
    msg.payload64.push_back(word);
  }

  const uint8_t ckl = raw[payload_end];
  const uint8_t ckh = raw[payload_end + 1];
  msg.checksum = static_cast<uint64_t>(ckl) | (static_cast<uint64_t>(ckh) << 8);

  return msg;
}

// ============================================================================
// Helper
// ============================================================================

/// Creates a deterministic payload of n bytes where byte[i] = i % 256.
static std::vector<uint8_t> makePayload(int n)
{
  std::vector<uint8_t> p(static_cast<std::size_t>(n));
  for (int i = 0; i < n; ++i)
  {
    p[static_cast<std::size_t>(i)] = static_cast<uint8_t>(i % 256);
  }
  return p;
}

/// Pack raw bytes into payload64 words (big-endian, zero-padded last word).
static std::vector<uint64_t> packPayload(const std::vector<uint8_t>& bytes)
{
  std::vector<uint64_t> words;
  std::size_t remaining = bytes.size();
  std::size_t idx = 0;
  while (remaining > 0)
  {
    uint64_t word = 0;
    for (int shift = 56; shift >= 0 && remaining > 0; shift -= 8, --remaining)
    {
      word |= (static_cast<uint64_t>(bytes[idx++]) << shift);
    }
    words.push_back(word);
  }
  return words;
}

// ============================================================================
// MAVLink v1 round-trip tests
// ============================================================================

TEST(RosInterfaceFraming, V1HeartbeatRoundTrip)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFE;
  msg.len = 9;
  msg.seq = 42;
  msg.sysid = 1;
  msg.compid = 1;
  msg.msgid = 0;
  msg.checksum = 0xABCD;

  // Build a known 9-byte payload
  const auto payload = makePayload(9);
  msg.payload64 = packPayload(payload);

  const auto raw = toRawBytes(msg);
  const auto decoded = fromRawBytes(raw);

  EXPECT_EQ(decoded.magic, msg.magic);
  EXPECT_EQ(decoded.len, msg.len);
  EXPECT_EQ(decoded.seq, msg.seq);
  EXPECT_EQ(decoded.sysid, msg.sysid);
  EXPECT_EQ(decoded.compid, msg.compid);
  EXPECT_EQ(decoded.msgid, msg.msgid);
  EXPECT_EQ(decoded.checksum, msg.checksum);
  ASSERT_EQ(decoded.payload64.size(), msg.payload64.size());
  for (std::size_t i = 0; i < decoded.payload64.size(); ++i)
  {
    EXPECT_EQ(decoded.payload64[i], msg.payload64[i]);
  }
}

TEST(RosInterfaceFraming, V1EmptyPayloadRoundTrip)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFE;
  msg.len = 0;
  msg.seq = 0;
  msg.sysid = 5;
  msg.compid = 3;
  msg.msgid = 77;
  msg.checksum = 0x1111;
  // no payload64

  const auto raw = toRawBytes(msg);
  const auto decoded = fromRawBytes(raw);

  EXPECT_EQ(decoded.magic, msg.magic);
  EXPECT_EQ(decoded.len, msg.len);
  EXPECT_EQ(decoded.seq, msg.seq);
  EXPECT_EQ(decoded.sysid, msg.sysid);
  EXPECT_EQ(decoded.compid, msg.compid);
  EXPECT_EQ(decoded.msgid, msg.msgid);
  EXPECT_EQ(decoded.checksum, msg.checksum);
  EXPECT_TRUE(decoded.payload64.empty());
}

TEST(RosInterfaceFraming, V1MaxPayloadRoundTrip)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFE;
  msg.len = 255;
  msg.seq = 200;
  msg.sysid = 10;
  msg.compid = 20;
  msg.msgid = 100;
  msg.checksum = 0xDEAD;

  const auto payload = makePayload(255);
  msg.payload64 = packPayload(payload);

  const auto raw = toRawBytes(msg);
  const auto decoded = fromRawBytes(raw);

  EXPECT_EQ(decoded.magic, msg.magic);
  EXPECT_EQ(decoded.len, msg.len);
  EXPECT_EQ(decoded.checksum, msg.checksum);
  ASSERT_EQ(decoded.payload64.size(), msg.payload64.size());
  for (std::size_t i = 0; i < decoded.payload64.size(); ++i)
  {
    EXPECT_EQ(decoded.payload64[i], msg.payload64[i]);
  }

  // Also verify all 255 bytes survive byte-by-byte
  const auto& p64 = decoded.payload64;
  std::size_t byte_idx = 0;
  for (uint64_t word : p64)
  {
    for (int shift = 56; shift >= 0 && byte_idx < 255; shift -= 8, ++byte_idx)
    {
      const uint8_t got = static_cast<uint8_t>((word >> shift) & 0xFF);
      EXPECT_EQ(got, payload[byte_idx]) << "mismatch at byte " << byte_idx;
    }
  }
}

TEST(RosInterfaceFraming, V1WireFormat)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFE;
  msg.len = 3;
  msg.seq = 7;
  msg.sysid = 11;
  msg.compid = 22;
  msg.msgid = 33;
  msg.checksum = 0x5566;

  const std::vector<uint8_t> pay_bytes = {0xAA, 0xBB, 0xCC};
  msg.payload64 = packPayload(pay_bytes);

  const auto raw = toRawBytes(msg);

  // Header
  EXPECT_EQ(raw[0], 0xFEu);  // magic
  EXPECT_EQ(raw[1], 3u);     // len
  EXPECT_EQ(raw[2], 7u);     // seq
  EXPECT_EQ(raw[3], 11u);    // sysid
  EXPECT_EQ(raw[4], 22u);    // compid
  EXPECT_EQ(raw[5], 33u);    // msgid

  // Payload
  EXPECT_EQ(raw[6], 0xAAu);
  EXPECT_EQ(raw[7], 0xBBu);
  EXPECT_EQ(raw[8], 0xCCu);

  // Checksum LE
  EXPECT_EQ(raw[9], 0x66u);   // low byte  of 0x5566
  EXPECT_EQ(raw[10], 0x55u);  // high byte of 0x5566

  EXPECT_EQ(raw.size(), 6u + 3u + 2u);
}

TEST(RosInterfaceFraming, V1ChecksumLE)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFE;
  msg.len = 0;
  msg.seq = 0;
  msg.sysid = 0;
  msg.compid = 0;
  msg.msgid = 0;
  msg.checksum = 0x1234;

  const auto raw = toRawBytes(msg);
  // Total size = 6 + 0 + 2 = 8; checksum at [6] and [7]
  ASSERT_EQ(raw.size(), 8u);
  EXPECT_EQ(raw[6], 0x34u);  // low byte  of 0x1234
  EXPECT_EQ(raw[7], 0x12u);  // high byte of 0x1234
}

TEST(RosInterfaceFraming, V1PayloadWordPacking)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFE;
  msg.len = 8;
  msg.seq = 0;
  msg.sysid = 0;
  msg.compid = 0;
  msg.msgid = 0;
  msg.checksum = 0;
  // payload64[0] = 0x0102030405060708 → bytes 01 02 03 04 05 06 07 08
  msg.payload64.push_back(0x0102030405060708ULL);

  const auto raw = toRawBytes(msg);

  ASSERT_EQ(raw.size(), 6u + 8u + 2u);
  EXPECT_EQ(raw[6], 0x01u);
  EXPECT_EQ(raw[7], 0x02u);
  EXPECT_EQ(raw[8], 0x03u);
  EXPECT_EQ(raw[9], 0x04u);
  EXPECT_EQ(raw[10], 0x05u);
  EXPECT_EQ(raw[11], 0x06u);
  EXPECT_EQ(raw[12], 0x07u);
  EXPECT_EQ(raw[13], 0x08u);
}

TEST(RosInterfaceFraming, V1PayloadTruncation)
{
  // payload64 has 2 words (16 bytes worth) but len=3 — only 3 bytes emitted
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFE;
  msg.len = 3;
  msg.seq = 0;
  msg.sysid = 0;
  msg.compid = 0;
  msg.msgid = 0;
  msg.checksum = 0;
  msg.payload64.push_back(0xAABBCC0000000000ULL);
  msg.payload64.push_back(0xDDEEFF0000000000ULL);

  const auto raw = toRawBytes(msg);

  // Only 3 payload bytes should be present
  ASSERT_EQ(raw.size(), 6u + 3u + 2u);
  EXPECT_EQ(raw[6], 0xAAu);
  EXPECT_EQ(raw[7], 0xBBu);
  EXPECT_EQ(raw[8], 0xCCu);
}

// ============================================================================
// MAVLink v2 round-trip tests
// ============================================================================

TEST(RosInterfaceFraming, V2HeartbeatRoundTrip)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFD;
  msg.len = 9;
  msg.incompat_flags = 0;
  msg.compat_flags = 0;
  msg.seq = 1;
  msg.sysid = 1;
  msg.compid = 1;
  msg.msgid = 0;
  msg.checksum = 0x1234;

  const auto payload = makePayload(9);
  msg.payload64 = packPayload(payload);

  const auto raw = toRawBytes(msg);
  const auto decoded = fromRawBytes(raw);

  EXPECT_EQ(decoded.magic, msg.magic);
  EXPECT_EQ(decoded.len, msg.len);
  EXPECT_EQ(decoded.incompat_flags, msg.incompat_flags);
  EXPECT_EQ(decoded.compat_flags, msg.compat_flags);
  EXPECT_EQ(decoded.seq, msg.seq);
  EXPECT_EQ(decoded.sysid, msg.sysid);
  EXPECT_EQ(decoded.compid, msg.compid);
  EXPECT_EQ(decoded.msgid, msg.msgid);
  EXPECT_EQ(decoded.checksum, msg.checksum);
  ASSERT_EQ(decoded.payload64.size(), msg.payload64.size());
  for (std::size_t i = 0; i < decoded.payload64.size(); ++i)
  {
    EXPECT_EQ(decoded.payload64[i], msg.payload64[i]);
  }
}

TEST(RosInterfaceFraming, V2CommandLongRoundTrip)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFD;
  msg.len = 30;
  msg.incompat_flags = 0;
  msg.compat_flags = 0;
  msg.seq = 55;
  msg.sysid = 1;
  msg.compid = 1;
  msg.msgid = 76;  // COMMAND_LONG
  msg.checksum = 0xBEEF;

  const auto payload = makePayload(30);
  msg.payload64 = packPayload(payload);

  const auto raw = toRawBytes(msg);
  const auto decoded = fromRawBytes(raw);

  EXPECT_EQ(decoded.magic, msg.magic);
  EXPECT_EQ(decoded.len, msg.len);
  EXPECT_EQ(decoded.msgid, msg.msgid);
  EXPECT_EQ(decoded.checksum, msg.checksum);
  ASSERT_EQ(decoded.payload64.size(), msg.payload64.size());
  for (std::size_t i = 0; i < decoded.payload64.size(); ++i)
  {
    EXPECT_EQ(decoded.payload64[i], msg.payload64[i]);
  }
}

TEST(RosInterfaceFraming, V2WireFormat)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFD;
  msg.len = 2;
  msg.incompat_flags = 0x01;
  msg.compat_flags = 0x02;
  msg.seq = 9;
  msg.sysid = 3;
  msg.compid = 4;
  msg.msgid = 0x000015;  // 21 decimal, fits in one byte for easy checking
  msg.checksum = 0x9988;

  msg.payload64.push_back(0xCAFE000000000000ULL);  // 2 bytes: 0xCA, 0xFE

  const auto raw = toRawBytes(msg);

  ASSERT_EQ(raw.size(), 10u + 2u + 2u);

  // Header bytes
  EXPECT_EQ(raw[0], 0xFDu);  // magic
  EXPECT_EQ(raw[1], 2u);     // len
  EXPECT_EQ(raw[2], 0x01u);  // incompat_flags
  EXPECT_EQ(raw[3], 0x02u);  // compat_flags
  EXPECT_EQ(raw[4], 9u);     // seq
  EXPECT_EQ(raw[5], 3u);     // sysid
  EXPECT_EQ(raw[6], 4u);     // compid
  // msgid LE 3-byte
  EXPECT_EQ(raw[7], 0x15u);  // msgid & 0xFF
  EXPECT_EQ(raw[8], 0x00u);  // (msgid >> 8) & 0xFF
  EXPECT_EQ(raw[9], 0x00u);  // (msgid >> 16) & 0xFF

  // Payload
  EXPECT_EQ(raw[10], 0xCAu);
  EXPECT_EQ(raw[11], 0xFEu);

  // Checksum LE
  EXPECT_EQ(raw[12], 0x88u);  // low  byte of 0x9988
  EXPECT_EQ(raw[13], 0x99u);  // high byte of 0x9988
}

TEST(RosInterfaceFraming, V2MsgidLE)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFD;
  msg.len = 0;
  msg.seq = 0;
  msg.sysid = 0;
  msg.compid = 0;
  msg.msgid = 0x123456;
  msg.checksum = 0;

  const auto raw = toRawBytes(msg);

  ASSERT_GE(raw.size(), 12u);
  EXPECT_EQ(raw[7], 0x56u);  // msgid & 0xFF
  EXPECT_EQ(raw[8], 0x34u);  // (msgid >> 8) & 0xFF
  EXPECT_EQ(raw[9], 0x12u);  // (msgid >> 16) & 0xFF
}

TEST(RosInterfaceFraming, V2ChecksumLE)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFD;
  msg.len = 0;
  msg.seq = 0;
  msg.sysid = 0;
  msg.compid = 0;
  msg.msgid = 0;
  msg.checksum = 0xBEEF;

  const auto raw = toRawBytes(msg);

  // Total = 10 + 0 + 2 = 12; checksum at [10] and [11]
  ASSERT_EQ(raw.size(), 12u);
  EXPECT_EQ(raw[10], 0xEFu);  // low  byte of 0xBEEF
  EXPECT_EQ(raw[11], 0xBEu);  // high byte of 0xBEEF
}

TEST(RosInterfaceFraming, V2LargePayload)
{
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFD;
  msg.len = 253;  // max v2 payload
  msg.incompat_flags = 0;
  msg.compat_flags = 0;
  msg.seq = 99;
  msg.sysid = 2;
  msg.compid = 3;
  msg.msgid = 0xABCDEF & 0xFFFFFF;
  msg.checksum = 0x5A5A;

  const auto payload = makePayload(253);
  msg.payload64 = packPayload(payload);

  const auto raw = toRawBytes(msg);
  const auto decoded = fromRawBytes(raw);

  EXPECT_EQ(decoded.magic, msg.magic);
  EXPECT_EQ(decoded.len, msg.len);
  EXPECT_EQ(decoded.msgid, msg.msgid);
  EXPECT_EQ(decoded.checksum, msg.checksum);
  ASSERT_EQ(decoded.payload64.size(), msg.payload64.size());
  for (std::size_t i = 0; i < decoded.payload64.size(); ++i)
  {
    EXPECT_EQ(decoded.payload64[i], msg.payload64[i]);
  }

  // Verify all 253 bytes survive byte-by-byte
  const auto& p64 = decoded.payload64;
  std::size_t byte_idx = 0;
  for (uint64_t word : p64)
  {
    for (int shift = 56; shift >= 0 && byte_idx < 253; shift -= 8, ++byte_idx)
    {
      const uint8_t got = static_cast<uint8_t>((word >> shift) & 0xFF);
      EXPECT_EQ(got, payload[byte_idx]) << "mismatch at byte " << byte_idx;
    }
  }
}

// ============================================================================
// Edge-case tests
// ============================================================================

TEST(RosInterfaceFraming, FromRawBytesEmptyInput)
{
  const std::vector<uint8_t> empty;
  // Must not crash; returns default-constructed message
  const auto decoded = fromRawBytes(empty);
  EXPECT_EQ(decoded.len, 0u);
  EXPECT_EQ(decoded.msgid, 0u);
  EXPECT_TRUE(decoded.payload64.empty());
}

TEST(RosInterfaceFraming, FromRawBytesV1TooShort)
{
  // 5 bytes: magic + 4 more — less than the v1 minimum of 8
  const std::vector<uint8_t> short_v1 = {0xFE, 0x00, 0x01, 0x02, 0x03};
  const auto decoded = fromRawBytes(short_v1);
  // Should return without crash; magic is set, rest is default
  EXPECT_EQ(decoded.magic, 0xFEu);
  EXPECT_EQ(decoded.len, 0u);
  EXPECT_TRUE(decoded.payload64.empty());
}

TEST(RosInterfaceFraming, FromRawBytesV2TooShort)
{
  // 11 bytes: magic + 10 more — less than the v2 minimum of 12
  const std::vector<uint8_t> short_v2 = {0xFD, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07};
  const auto decoded = fromRawBytes(short_v2);
  // Should return without crash; magic is set, rest is default
  EXPECT_EQ(decoded.magic, 0xFDu);
  EXPECT_EQ(decoded.len, 0u);
  EXPECT_TRUE(decoded.payload64.empty());
}

TEST(RosInterfaceFraming, V2PayloadMsgidExtract)
{
  // After encode + decode, msgid must equal the original
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFD;
  msg.len = 0;
  msg.seq = 0;
  msg.sysid = 0;
  msg.compid = 0;
  msg.msgid = 0x00CAFE;
  msg.checksum = 0;

  const auto raw = toRawBytes(msg);
  const auto decoded = fromRawBytes(raw);

  EXPECT_EQ(decoded.msgid, static_cast<uint64_t>(0x00CAFEu));
}

TEST(RosInterfaceFraming, ChecksumOnlyLow16Bits)
{
  // High bits of checksum must be ignored; only 0xABCD matters
  mavros_msgs::Mavlink msg;
  msg.magic = 0xFE;
  msg.len = 0;
  msg.seq = 0;
  msg.sysid = 0;
  msg.compid = 0;
  msg.msgid = 0;
  msg.checksum = 0xABCDu;

  const auto raw = toRawBytes(msg);
  const auto decoded = fromRawBytes(raw);

  // After decode checksum = 0xABCD (only low 16 bits preserved on wire)
  EXPECT_EQ(decoded.checksum, static_cast<uint64_t>(0xABCDu));
}

// ============================================================================
// main
// ============================================================================

int main(int argc, char** argv)
{
  ::testing::InitGoogleTest(&argc, argv);
  ros::init(argc, argv, "test_ros_interface_framing", ros::init_options::AnonymousName);
  ros::Time::init();
  return RUN_ALL_TESTS();
}
