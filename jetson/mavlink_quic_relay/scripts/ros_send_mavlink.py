#!/usr/bin/env python3
"""
ros_send_mavlink.py

Publish MAVLink STATUSTEXT messages to a mavros_msgs/Mavlink topic so the Jetson
node (ros_interface.cpp) receives them. Intended to be run with rosrun:

  rosrun mavlink_quic_relay ros_send_mavlink.py --topic /mavlink/from

Dependencies: rospy, mavros_msgs
"""

import argparse
import sys
import time
import rospy
from mavros_msgs.msg import Mavlink


def pack_payload64(payload_bytes: bytes):
    words = []
    i = 0
    n = len(payload_bytes)
    while i < n:
        chunk = payload_bytes[i : i + 8]
        # place chunk into high-order bytes of 8-byte word (big-endian)
        word = int.from_bytes(chunk, byteorder="big") << (8 * (8 - len(chunk)))
        words.append(word)
        i += 8
    return words


def make_statustext_msg(seq, sysid, compid, severity, text, v2=True):
    # STATUSTEXT payload: uint8 severity + char[50] text (total 51 bytes)
    payload = bytearray()
    payload.append(severity & 0xFF)
    txt = text.encode("utf-8")[:50]
    payload.extend(txt)
    if len(payload) < 51:
        payload.extend(b"\0" * (51 - len(payload)))

    msg = Mavlink()
    if v2:
        msg.magic = 0xFD
        msg.incompat_flags = 0
        msg.compat_flags = 0
    else:
        msg.magic = 0xFE

    msg.len = len(payload)
    msg.seq = seq & 0xFF
    msg.sysid = sysid & 0xFF
    msg.compid = compid & 0xFF
    msg.msgid = 253  # STATUSTEXT
    msg.payload64 = pack_payload64(bytes(payload))
    msg.checksum = 0
    return msg


def main():
    parser = argparse.ArgumentParser(
        description="Publish STATUSTEXT mavlink messages to a mavros topic"
    )
    parser.add_argument(
        "--topic",
        default="/mavlink/from",
        help="ROS topic to publish mavlink messages to",
    )
    parser.add_argument("--rate", type=float, default=1.0, help="messages per second")
    parser.add_argument(
        "--count", type=int, default=0, help="how many rounds to send (0 = forever)"
    )
    parser.add_argument("--sysid", type=int, default=250, help="source system id")
    parser.add_argument("--compid", type=int, default=250, help="source component id")
    parser.add_argument(
        "--v2",
        action="store_true",
        default=True,
        help="use MAVLink v2 framing (default)",
    )
    args = parser.parse_args(rospy.myargv(argv=sys.argv)[1:])

    rospy.init_node("ros_send_mavlink", anonymous=True)

    # Force wall clock time regardless of /use_sim_time on the param server.
    # Without this, rospy.Rate.sleep() blocks forever when use_sim_time=true
    # and no /clock is being published (e.g. after a rosbag session).
    rospy.set_param("/use_sim_time", False)

    pub = rospy.Publisher(args.topic, Mavlink, queue_size=10)

    # Allow the subscriber (relay node) time to connect before sending.
    # Without this wall-clock sleep the first batch of messages is silently
    # dropped because the TCP connection to the subscriber is not yet ready.
    time.sleep(1.0)

    seq = 0
    severities = [0, 1, 2, 3, 4, 5, 6, 7]
    sleep_s = 1.0 / max(args.rate, 1e-6)
    round_sent = 0
    try:
        while not rospy.is_shutdown():
            for s in severities:
                seq += 1
                round_sent += 1
                text = f"TEST severity={s} round={round_sent}"
                msg = make_statustext_msg(
                    seq, args.sysid, args.compid, s, text, v2=args.v2
                )
                pub.publish(msg)
                rospy.loginfo(f"Published STATUSTEXT severity={s} seq={seq}")
                time.sleep(sleep_s)
            if args.count > 0:
                if round_sent >= args.count * len(severities):
                    rospy.loginfo("Finished requested count")
                    return
    except rospy.ROSInterruptException:
        pass


if __name__ == "__main__":
    main()
