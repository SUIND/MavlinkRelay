#!/usr/bin/env python3
"""
send_mavlink_test.py

Send test MAVLink messages (STATUSTEXT with different severities) to a Jetson node
or any MAVLink endpoint. Uses pymavlink.

Example:
  pip install pymavlink
  ./scripts/send_mavlink_test.py --target 192.168.1.10:14550 --count 5 --interval 0.5

The script sends STATUSTEXT messages with different MAV_SEVERITY levels to
exercise priority handling on the receiver.
"""

import argparse
import time
from pymavlink import mavutil


SEVERITY_ORDER = [
    ("EMERGENCY", mavutil.mavlink.MAV_SEVERITY_EMERGENCY),
    ("ALERT", mavutil.mavlink.MAV_SEVERITY_ALERT),
    ("CRITICAL", mavutil.mavlink.MAV_SEVERITY_CRITICAL),
    ("ERROR", mavutil.mavlink.MAV_SEVERITY_ERROR),
    ("WARNING", mavutil.mavlink.MAV_SEVERITY_WARNING),
    ("NOTICE", mavutil.mavlink.MAV_SEVERITY_NOTICE),
    ("INFO", mavutil.mavlink.MAV_SEVERITY_INFO),
    ("DEBUG", mavutil.mavlink.MAV_SEVERITY_DEBUG),
]


def build_connection(
    target: str, source_system: int, source_component: int, wait_ready: bool
):
    # target expected as host:port. Use udpout so we only send.
    if ":" not in target:
        raise SystemExit("target must be HOST:PORT")
    host, port = target.split(":", 1)
    conn_str = f"udpout:{host}:{port}"
    print(f"Connecting -> {conn_str} (src sys={source_system} comp={source_component})")
    master = mavutil.mavlink_connection(
        conn_str, source_system=source_system, source_component=source_component
    )
    if wait_ready:
        # optional wait for a response (non-blocking used here briefly)
        master.wait_heartbeat(timeout=2)
    return master


def send_statustext(master, severity, text, target_system=0, target_component=0):
    # target_system/component left 0 to be broadcast; set if needed
    try:
        master.mav.statustext_send(severity, text.encode("utf-8"))
    except Exception as e:
        print("send failed:", e)


def main():
    p = argparse.ArgumentParser(
        description="Send test MAVLink STATUSTEXT messages with different priorities"
    )
    p.add_argument("--target", "-t", required=True, help="target HOST:PORT (udpout)")
    p.add_argument(
        "--count",
        "-c",
        type=int,
        default=1,
        help="how many rounds of all severities to send",
    )
    p.add_argument(
        "--interval", "-i", type=float, default=1.0, help="seconds between messages"
    )
    p.add_argument("--source-system", type=int, default=250, help="source system id")
    p.add_argument(
        "--source-component", type=int, default=250, help="source component id"
    )
    p.add_argument(
        "--wait",
        action="store_true",
        help="wait for a heartbeat from target before sending",
    )
    args = p.parse_args()

    master = build_connection(
        args.target, args.source_system, args.source_component, args.wait
    )

    try:
        for r in range(args.count):
            for name, sev in SEVERITY_ORDER:
                text = f"TEST [{r + 1}/{args.count}] severity={name}"
                print(f"Sending: {text}")
                send_statustext(master, sev, text)
                time.sleep(args.interval)
        print("Done")
    except KeyboardInterrupt:
        print("\nInterrupted by user")


if __name__ == "__main__":
    main()
