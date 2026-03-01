#!/usr/bin/env python3
"""
test_relay_roundtrip.py — rostest end-to-end integration test for mavlink_quic_relay.

Test pipeline:
  test_relay_roundtrip.test launches:
    1. mock_quic_server.py  — aioquic server on port 15551 (AUTH + MAVLink echo)
    2. mavlink_quic_relay_node — relay node connecting to the mock server

This script:
  1. Subscribes to /mavlink/to (inbound from server)
  2. Publishes MAVLink v2 frames on /mavlink/from (outbound to server)
  3. Waits up to 10 s for the echo to appear on /mavlink/to
  4. Asserts correct msgid in the echoed frame

Test cases:
  test_heartbeat_round_trip    — HEARTBEAT (msgid=0, priority stream)
  test_command_long_round_trip — COMMAND_LONG (msgid=76, priority stream)
  test_node_advertises_mavlink_to_topic — topic presence check

Prerequisites:
  pip install aioquic cryptography
  catkin run_tests mavlink_quic_relay
"""

import threading
import sys
import unittest
import rospy
import rostest
import mavros_msgs.msg


class RelayRoundtripTest(unittest.TestCase):
    _received_msgs = []
    _sub = None

    @classmethod
    def setUpClass(cls):
        rospy.init_node("test_relay_roundtrip", anonymous=True)
        cls._received_msgs = []
        cls._sub = rospy.Subscriber(
            "/mavlink/to",
            mavros_msgs.msg.Mavlink,
            lambda msg: cls._received_msgs.append(msg),
        )
        # Wait for relay node to advertise /mavlink/to (up to 5s)
        deadline = rospy.Time.now() + rospy.Duration(5.0)
        while rospy.Time.now() < deadline:
            topics = dict(rospy.get_published_topics())
            if "/mavlink/to" in topics:
                break
            rospy.sleep(0.1)
        # Extra wait for QUIC auth to complete
        rospy.sleep(3.0)

    def setUp(self):
        # Clear messages before each test
        self.__class__._received_msgs = []

    def _wait_for_msg(self, expected_msgid, timeout_s=10.0):
        """Poll received_msgs until a message with expected_msgid appears or timeout."""
        deadline = rospy.Time.now() + rospy.Duration(timeout_s)
        while rospy.Time.now() < deadline:
            for m in list(self._received_msgs):
                if m.msgid == expected_msgid:
                    return m
            rospy.sleep(0.05)
        return None

    def _pub_and_wait(self, msg, expected_msgid):
        pub = rospy.Publisher("/mavlink/from", mavros_msgs.msg.Mavlink, queue_size=10)
        rospy.sleep(0.2)  # give publisher time to connect
        pub.publish(msg)
        result = self._wait_for_msg(expected_msgid)
        return result

    def test_heartbeat_round_trip(self):
        """Test 1: Publish MAVLink v2 HEARTBEAT (msgid=0), verify echo on /mavlink/to."""
        msg = mavros_msgs.msg.Mavlink()
        msg.magic = 0xFD  # MAVLink v2
        msg.len = 9  # HEARTBEAT payload is 9 bytes
        msg.incompat_flags = 0
        msg.compat_flags = 0
        msg.seq = 1
        msg.sysid = 1
        msg.compid = 1
        msg.msgid = 0  # HEARTBEAT
        # Payload: 9 bytes packed into 2 uint64 words (BE packing)
        # word 0: 0x0102030405060708
        # word 1: 0x0900000000000000
        msg.payload64 = [0x0102030405060708, 0x0900000000000000]
        msg.checksum = 0x1234

        result = self._pub_and_wait(msg, expected_msgid=0)
        self.assertIsNotNone(
            result,
            "No message with msgid=0 (HEARTBEAT) received on /mavlink/to within timeout",
        )
        self.assertEqual(
            result.msgid, 0, "Echoed message msgid should be 0 (HEARTBEAT)"
        )

    def test_command_long_round_trip(self):
        """Test 2: Publish MAVLink v2 COMMAND_LONG (msgid=76), verify echo on /mavlink/to."""
        msg = mavros_msgs.msg.Mavlink()
        msg.magic = 0xFD
        msg.len = 30
        msg.incompat_flags = 0
        msg.compat_flags = 0
        msg.seq = 2
        msg.sysid = 1
        msg.compid = 1
        msg.msgid = 76  # COMMAND_LONG
        # 30 bytes = 3 full words + 6 bytes of a 4th word
        msg.payload64 = [
            0x0102030405060708,
            0x090A0B0C0D0E0F10,
            0x1112131415161718,
            0x191A1B1C1D1E0000,
        ]
        msg.checksum = 0x5678

        result = self._pub_and_wait(msg, expected_msgid=76)
        self.assertIsNotNone(
            result,
            "No message with msgid=76 (COMMAND_LONG) received on /mavlink/to within timeout",
        )
        self.assertEqual(
            result.msgid, 76, "Echoed message msgid should be 76 (COMMAND_LONG)"
        )

    def test_node_advertises_mavlink_to_topic(self):
        """Test 3: Node advertises /mavlink/to topic."""
        published_topics = dict(rospy.get_published_topics())
        self.assertIn(
            "/mavlink/to",
            published_topics,
            "/mavlink/to not advertised by relay node",
        )


if __name__ == "__main__":
    rostest.rosrun(
        "mavlink_quic_relay",
        "test_relay_roundtrip",
        RelayRoundtripTest,
        sys.argv,
    )
