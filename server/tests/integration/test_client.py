#!/usr/bin/env python3
"""Integration test client for MAVLink QUIC relay server.

Tests the full relay flow:
1. Vehicle connects, authenticates, and sends MAVLink frames.
2. GCS connects, authenticates, subscribes to the vehicle, and receives frames.

Exit 0 on success, non-zero on failure.
"""

import asyncio
import os
import ssl
import struct
import sys
from typing import cast
import cbor2
from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import HandshakeCompleted, StreamDataReceived, QuicEvent

RELAY_HOST = os.environ.get("RELAY_HOST", "relay")
RELAY_PORT = int(os.environ.get("RELAY_PORT", "14550"))

VEHICLE_TOKEN = b"\x00" * 16  # base64: AAAAAAAAAAAAAAAAAAAAAA==
GCS_TOKEN = b"\xbb" * 16  # base64: u7u7u7u7u7u7u7u7u7u7uw==
VEHICLE_ID = "BB_000001"

# Fixed QUIC stream IDs
# Client-initiated bidirectional: 0 (control), 4 (priority out), 8 (bulk out)
# Server-initiated bidirectional: 1 (priority in from server), 5 (bulk in from server)
CONTROL_STREAM_ID = 0
PRIORITY_STREAM_ID = 4        # used by vehicle to send MAVLink frames
SERVER_PRIORITY_STREAM_ID = 1  # used by server to push frames to GCS


def encode_frame(payload: bytes) -> bytes:
    """Wrap payload with a u16-le length prefix."""
    return struct.pack("<H", len(payload)) + payload


def make_cbor_frame(msg: dict) -> bytes:
    """CBOR-encode msg and wrap with length-prefix framing."""
    payload = cbor2.dumps(msg)
    return encode_frame(payload)


class VehicleClient(QuicConnectionProtocol):
    """QUIC client that authenticates as a vehicle and sends MAVLink frames."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.authed = asyncio.Event()
        self._control_buf = b""

    def quic_event_received(self, event: QuicEvent):
        if isinstance(event, HandshakeCompleted):
            asyncio.ensure_future(self._on_handshake())
        elif isinstance(event, StreamDataReceived):
            if event.stream_id == CONTROL_STREAM_ID:
                self._feed_control(event.data)

    def _feed_control(self, data: bytes):
        """Incrementally parse length-prefixed CBOR frames from control stream."""
        self._control_buf += data
        while len(self._control_buf) >= 2:
            length = struct.unpack("<H", self._control_buf[:2])[0]
            if len(self._control_buf) < 2 + length:
                break
            payload = self._control_buf[2 : 2 + length]
            self._control_buf = self._control_buf[2 + length :]
            try:
                msg = cbor2.loads(payload)
                msg_type = msg.get("type")
                if msg_type == "AUTH_OK":
                    print("[vehicle] AUTH_OK received")
                    self.authed.set()
                elif msg_type == "AUTH_FAIL":
                    print(f"[vehicle] AUTH_FAIL: {msg.get('reason')}")
            except Exception as exc:
                print(f"[vehicle] Failed to parse control message: {exc}")

    async def _on_handshake(self):
        """Send AUTH immediately after handshake completes."""
        auth_msg = make_cbor_frame({"type": "AUTH", "token": VEHICLE_TOKEN})
        self._quic.send_stream_data(CONTROL_STREAM_ID, auth_msg)
        self.transmit()
        print("[vehicle] AUTH sent")

    async def send_frames(self, label: str, count: int = 3):
        """Wait for auth then send `count` MAVLink test frames on the priority stream."""
        await asyncio.wait_for(self.authed.wait(), timeout=10.0)
        for i in range(count):
            frame_data = f"{label}_{i}".encode()
            self._quic.send_stream_data(PRIORITY_STREAM_ID, encode_frame(frame_data))
        self.transmit()
        print(f"[vehicle] Sent {count} frames (label={label!r})")


class GCSClient(QuicConnectionProtocol):
    """QUIC client that authenticates as GCS, subscribes to a vehicle, and receives frames."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.authed = asyncio.Event()
        self.sub_ok = asyncio.Event()
        self.frames_received: list[bytes] = []
        self._control_buf = b""
        self._mavlink_buf = b""

    def quic_event_received(self, event: QuicEvent):
        if isinstance(event, HandshakeCompleted):
            asyncio.ensure_future(self._on_handshake())
        elif isinstance(event, StreamDataReceived):
            if event.stream_id == CONTROL_STREAM_ID:
                self._feed_control(event.data)
            elif event.stream_id == SERVER_PRIORITY_STREAM_ID:
                self._feed_mavlink(event.data)

    def _feed_control(self, data: bytes):
        """Incrementally parse length-prefixed CBOR frames from control stream."""
        self._control_buf += data
        while len(self._control_buf) >= 2:
            length = struct.unpack("<H", self._control_buf[:2])[0]
            if len(self._control_buf) < 2 + length:
                break
            payload = self._control_buf[2 : 2 + length]
            self._control_buf = self._control_buf[2 + length :]
            try:
                msg = cbor2.loads(payload)
                msg_type = msg.get("type")
                if msg_type == "AUTH_OK":
                    print("[gcs] AUTH_OK received")
                    self.authed.set()
                elif msg_type == "AUTH_FAIL":
                    print(f"[gcs] AUTH_FAIL: {msg.get('reason')}")
                elif msg_type == "SUB_OK":
                    print(f"[gcs] SUB_OK for vehicle {msg.get('vehicle_id')}")
                    self.sub_ok.set()
                elif msg_type == "SUB_FAIL":
                    print(f"[gcs] SUB_FAIL: {msg.get('reason')}")
            except Exception as exc:
                print(f"[gcs] Failed to parse control message: {exc}")

    def _feed_mavlink(self, data: bytes):
        """Incrementally parse length-prefixed MAVLink frames from priority stream."""
        self._mavlink_buf += data
        while len(self._mavlink_buf) >= 2:
            length = struct.unpack("<H", self._mavlink_buf[:2])[0]
            if len(self._mavlink_buf) < 2 + length:
                break
            frame = self._mavlink_buf[2 : 2 + length]
            self._mavlink_buf = self._mavlink_buf[2 + length :]
            self.frames_received.append(frame)
            print(f"[gcs] Received frame #{len(self.frames_received)}: {frame!r}")

    async def _on_handshake(self):
        """Send AUTH immediately after handshake completes."""
        auth_msg = make_cbor_frame({"type": "AUTH", "token": GCS_TOKEN})
        self._quic.send_stream_data(CONTROL_STREAM_ID, auth_msg)
        self.transmit()
        print("[gcs] AUTH sent")

    async def subscribe_and_wait(self, vehicle_id: int, timeout: float = 10.0):
        """Wait for auth, send SUBSCRIBE, wait for SUB_OK."""
        await asyncio.wait_for(self.authed.wait(), timeout=timeout)
        sub_msg = make_cbor_frame({"type": "SUBSCRIBE", "vehicle_id": vehicle_id})
        self._quic.send_stream_data(CONTROL_STREAM_ID, sub_msg)
        self.transmit()
        print(f"[gcs] SUBSCRIBE sent for vehicle {vehicle_id}")
        await asyncio.wait_for(self.sub_ok.wait(), timeout=timeout)


def make_quic_config() -> QuicConfiguration:
    """Build a QuicConfiguration that skips TLS certificate verification."""
    config = QuicConfiguration(
        alpn_protocols=["mavlink-quic-v1"],
        is_client=True,
        verify_mode=ssl.CERT_NONE,
    )
    return config


async def run_test() -> bool:
    """Execute the end-to-end relay test.

    Returns True on success, False on failure.
    """
    print(f"Connecting to relay at {RELAY_HOST}:{RELAY_PORT}")

    # ------------------------------------------------------------------
    # Step 1: Vehicle connects and authenticates
    # ------------------------------------------------------------------
    async with connect(
        RELAY_HOST,
        RELAY_PORT,
        configuration=make_quic_config(),
        create_protocol=VehicleClient,
    ) as _vehicle_proto:
        vehicle = cast(VehicleClient, _vehicle_proto)
        await vehicle.wait_connected()
        print("[vehicle] QUIC handshake complete")

        # Wait for AUTH_OK before proceeding
        await asyncio.wait_for(vehicle.authed.wait(), timeout=10.0)

        # ------------------------------------------------------------------
        # Step 2: GCS connects, authenticates, and subscribes
        # ------------------------------------------------------------------
        async with connect(
            RELAY_HOST,
            RELAY_PORT,
            configuration=make_quic_config(),
            create_protocol=GCSClient,
        ) as _gcs_proto:
            gcs = cast(GCSClient, _gcs_proto)
            await gcs.wait_connected()
            print("[gcs] QUIC handshake complete")

            await gcs.subscribe_and_wait(VEHICLE_ID)

            # Brief pause to ensure the subscription is fully registered
            await asyncio.sleep(0.2)

            # ------------------------------------------------------------------
            # Step 3: Vehicle sends 3 frames that should be relayed to GCS
            # ------------------------------------------------------------------
            await vehicle.send_frames("MAVLINK_RELAY_FRAME", count=3)

            # ------------------------------------------------------------------
            # Step 4: Wait for GCS to receive all 3 frames (up to 5 seconds)
            # ------------------------------------------------------------------
            deadline = asyncio.get_event_loop().time() + 5.0
            while len(gcs.frames_received) < 3:
                if asyncio.get_event_loop().time() >= deadline:
                    break
                await asyncio.sleep(0.1)

            received = len(gcs.frames_received)
            if received >= 3:
                print(f"TEST PASSED: GCS received {received} frames")
                return True
            else:
                print(f"TEST FAILED: GCS received only {received}/3 expected frames")
                return False


if __name__ == "__main__":
    try:
        success = asyncio.run(run_test())
    except Exception as exc:
        print(f"TEST ERROR: {exc}", file=sys.stderr)
        import traceback

        traceback.print_exc()
        sys.exit(2)
    sys.exit(0 if success else 1)
