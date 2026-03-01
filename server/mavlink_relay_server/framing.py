"""Length-prefix frame encoder/decoder for MAVLink QUIC relay server.

Wire format: [u16_le 2-byte length][raw bytes]

Used on:
- Stream 4 (priority) and Stream 8 (bulk): raw MAVLink frames
- Stream 0 (control): CBOR-encoded control messages

Little-endian u16 matches MAVLink native byte order and C++ msquic client implementations.
Maximum frame size: 65535 bytes.
"""

import struct
from typing import List

_MAX_BUFFER_SIZE: int = 131072  # 128 KiB


def encode_frame(payload: bytes) -> bytes:
    """Encode a frame with length-prefix.

    Args:
        payload: Raw bytes to frame (must be non-empty).

    Returns:
        bytes: Length-prefix (u16_le) + payload.

    Raises:
        ValueError: If payload is empty (length 0).
    """
    if len(payload) == 0:
        raise ValueError("Payload cannot be empty")

    length = len(payload)
    length_prefix = struct.pack("<H", length)
    return length_prefix + payload


class FrameDecoder:
    """Stateful decoder for length-prefixed frames.

    Accumulates incoming bytes and extracts complete frames.
    Handles partial frames across multiple feed() calls.
    """

    def __init__(self) -> None:
        """Initialize the decoder with an empty buffer."""
        self._buffer: bytearray = bytearray()

    def feed(self, data: bytes) -> List[bytes]:
        """Feed data into the decoder and extract complete frames.

        Args:
            data: New bytes to add to the buffer.

        Returns:
            list[bytes]: All complete frames extracted from the buffer.
                        Empty list if no complete frames are available.

        Raises:
            ValueError: If a frame has zero length (invalid).
            ValueError: If the buffer would exceed _MAX_BUFFER_SIZE bytes.
        """
        if len(self._buffer) + len(data) > _MAX_BUFFER_SIZE:
            raise ValueError(
                f"FrameDecoder buffer overflow: {len(self._buffer) + len(data)} bytes"
            )
        self._buffer.extend(data)
        frames: List[bytes] = []

        while True:
            # Need at least 2 bytes for the length prefix
            if len(self._buffer) < 2:
                break

            # Read the length prefix (u16_le)
            length = struct.unpack_from("<H", self._buffer, 0)[0]

            # Check if it's an invalid empty frame
            if length == 0:
                raise ValueError("Invalid frame with zero length")

            # Check if we have the complete frame (2 byte header + payload)
            if len(self._buffer) < 2 + length:
                break

            # Extract the payload
            payload = bytes(self._buffer[2 : 2 + length])
            frames.append(payload)

            # Remove the processed frame from the buffer
            del self._buffer[: 2 + length]

        return frames
