from __future__ import annotations

# pyright: reportMissingImports=false

import struct

import pytest

from mavlink_relay_server.framing import FrameDecoder, encode_frame


def test_encode_frame_prefix_and_payload() -> None:
    payload = b"hello"
    framed = encode_frame(payload)
    assert framed == struct.pack("<H", 5) + payload


def test_encode_frame_empty_raises() -> None:
    with pytest.raises(ValueError, match="Payload cannot be empty"):
        encode_frame(b"")


def test_frame_decoder_empty_feed_returns_empty() -> None:
    dec = FrameDecoder()
    assert dec.feed(b"") == []


def test_frame_decoder_partial_header_then_payload() -> None:
    dec = FrameDecoder()
    payload = b"abc"
    framed = encode_frame(payload)

    assert dec.feed(framed[:1]) == []
    assert dec.feed(framed[1:]) == [payload]


def test_frame_decoder_partial_payload_across_feeds() -> None:
    dec = FrameDecoder()
    payload = b"abcdefgh"
    framed = encode_frame(payload)

    assert dec.feed(framed[: 2 + 3]) == []
    assert dec.feed(framed[2 + 3 :]) == [payload]


def test_frame_decoder_multiple_frames_in_one_feed() -> None:
    dec = FrameDecoder()
    f1 = encode_frame(b"one")
    f2 = encode_frame(b"two")
    f3 = encode_frame(b"three")
    assert dec.feed(f1 + f2 + f3) == [b"one", b"two", b"three"]


def test_frame_decoder_multiple_frames_with_leftover_buffer() -> None:
    dec = FrameDecoder()
    f1 = encode_frame(b"123")
    f2 = encode_frame(b"4567")

    blob = f1 + f2
    out1 = dec.feed(blob[:-1])
    assert out1 == [b"123"]
    out2 = dec.feed(blob[-1:])
    assert out2 == [b"4567"]


def test_frame_decoder_zero_length_frame_raises_and_does_not_consume() -> None:
    dec = FrameDecoder()
    bad = struct.pack("<H", 0)
    with pytest.raises(ValueError, match="zero length"):
        dec.feed(bad)
