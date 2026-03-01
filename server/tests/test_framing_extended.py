from __future__ import annotations

# pyright: reportMissingImports=false

import struct

import pytest

from mavlink_relay_server.framing import FrameDecoder, _MAX_BUFFER_SIZE, encode_frame


def test_encode_frame_max_size() -> None:
    payload = b"\xab" * 65535
    framed = encode_frame(payload)
    assert len(framed) == 65537
    assert framed[:2] == b"\xff\xff"
    assert framed[2:] == payload


def test_encode_frame_single_byte() -> None:
    framed = encode_frame(b"\xab")
    assert framed == b"\x01\x00\xab"


def test_frame_decoder_max_size_frame() -> None:
    payload = b"\xcd" * 65535
    framed = encode_frame(payload)
    dec = FrameDecoder()
    frames = dec.feed(framed)
    assert frames == [payload]


def test_frame_decoder_single_byte_feeds() -> None:
    payload = b"abc"
    framed = encode_frame(payload)
    assert len(framed) == 5

    dec = FrameDecoder()
    result: list[bytes] = []
    for i in range(len(framed)):
        result.extend(dec.feed(framed[i : i + 1]))
    assert result == [payload]


def test_frame_decoder_stress_many_frames() -> None:
    payloads = [bytes(range(i % 256)) * ((i % 10) + 1) for i in range(1, 101)]
    payloads = [p if p else b"\x00" for p in payloads]
    concatenated = b"".join(encode_frame(p) for p in payloads)

    dec = FrameDecoder()
    extracted: list[bytes] = []
    chunk_size = 17
    for offset in range(0, len(concatenated), chunk_size):
        chunk = concatenated[offset : offset + chunk_size]
        extracted.extend(dec.feed(chunk))

    assert extracted == payloads


def test_frame_decoder_exactly_at_limit_then_one_more_raises() -> None:
    import struct as _struct

    dec = FrameDecoder()
    chunk = _struct.pack("<H", 65535) + b"\xab" * 65533
    assert len(chunk) == 65535
    dec.feed(chunk)
    assert len(dec._buffer) == 65535

    with pytest.raises(ValueError):
        dec.feed(b"\xcd" * (_MAX_BUFFER_SIZE - 65535 + 1))


def test_frame_decoder_fresh_instance_works_after_error() -> None:
    dec_bad = FrameDecoder()
    with pytest.raises(ValueError):
        dec_bad.feed(b"\x00" * (_MAX_BUFFER_SIZE + 1))

    dec_good = FrameDecoder()
    payload = b"hello"
    frames = dec_good.feed(encode_frame(payload))
    assert frames == [payload]


def test_encode_frame_large_sizes_roundtrip() -> None:
    for size in [1, 256, 1000, 32768, 65535]:
        payload = bytes([size % 256]) * size
        framed = encode_frame(payload)
        length_field = struct.unpack("<H", framed[:2])[0]
        assert length_field == size

        dec = FrameDecoder()
        frames = dec.feed(framed)
        assert frames == [payload]
