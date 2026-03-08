from __future__ import annotations

# pyright: reportMissingImports=false

import asyncio
import base64
import struct
from typing import Any
from unittest.mock import MagicMock

import cbor2
import pytest

from mavlink_relay_server.config import DatabaseStore, TokenConfig
from mavlink_relay_server.control import decode_control, handle_auth, handle_subscribe
from mavlink_relay_server.framing import FrameDecoder
from mavlink_relay_server.protocol import RelayProtocol
from mavlink_relay_server.registry import SessionRegistry


# ---------------------------------------------------------------------------
# Helpers (mirror of test_control.py patterns)
# ---------------------------------------------------------------------------


def _decode_framed_control(data: bytes) -> dict[str, Any]:
    length = struct.unpack("<H", data[:2])[0]
    payload = data[2:]
    assert len(payload) == length
    return decode_control(payload)


def _make_proto() -> MagicMock:
    proto = MagicMock(spec=RelayProtocol)
    proto._authed = False
    proto._role = None
    proto._session_id = None
    proto._allowed_vehicle_id = None
    proto._auth_timeout_handle = MagicMock()
    proto._quic = MagicMock()
    return proto


def _make_token_store(
    vehicle_token: bytes = b"\x00" * 16,
    gcs_token: bytes = b"\xbb" * 16,
) -> DatabaseStore:
    vehicle_b64 = base64.b64encode(vehicle_token).decode("ascii")
    gcs_b64 = base64.b64encode(gcs_token).decode("ascii")
    tokens = [
        TokenConfig(
            token_b64=vehicle_b64,
            role="vehicle",
            identity="BB_000001",
            allowed_vehicle_id=None,
        ),
        TokenConfig(
            token_b64=gcs_b64,
            role="gcs",
            identity="GCS_000001",
            allowed_vehicle_id="BB_000001",
        ),
    ]
    return DatabaseStore(tokens)


# ---------------------------------------------------------------------------
# Re-auth attack tests
# ---------------------------------------------------------------------------


async def test_re_auth_attack_ignored() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()
    vehicle_token = b"\x00" * 16

    ok1 = handle_auth(
        proto,
        {"type": "AUTH", "token": vehicle_token, "vehicle_id": "BB_000001"},
        registry,
        token_store,
    )
    assert ok1 is True
    assert proto._authed is True
    assert proto._send_control.call_count == 1

    ok2 = handle_auth(
        proto,
        {"type": "AUTH", "token": vehicle_token, "vehicle_id": "BB_000001"},
        registry,
        token_store,
    )
    assert ok2 is False
    assert proto._send_control.call_count == 1
    assert proto._authed is True


async def test_re_auth_attack_with_different_token_ignored() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()
    vehicle_token = b"\x00" * 16
    gcs_token = b"\xbb" * 16

    ok1 = handle_auth(
        proto,
        {"type": "AUTH", "token": vehicle_token, "vehicle_id": "BB_000001"},
        registry,
        token_store,
    )
    assert ok1 is True
    assert proto._role == "vehicle"
    assert proto._session_id == "BB_000001"

    ok2 = handle_auth(
        proto,
        {"type": "AUTH", "token": gcs_token, "vehicle_id": "BB_000001"},
        registry,
        token_store,
    )
    assert ok2 is False
    assert proto._role == "vehicle"
    assert proto._session_id == "BB_000001"


def test_subscribe_before_auth_is_noop() -> None:
    registry = SessionRegistry()
    proto = _make_proto()
    proto._authed = False
    proto._role = None

    handle_subscribe(proto, {"type": "SUBSCRIBE", "vehicle_id": "BB_000001"}, registry)

    proto._send_control.assert_not_called()
    proto.transmit.assert_not_called()


# ---------------------------------------------------------------------------
# AUTH_FAIL content and close behaviour
# ---------------------------------------------------------------------------


async def test_auth_fail_sends_auth_fail_cbor() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()

    ok = handle_auth(
        proto, {"type": "AUTH", "token": b"\xff" * 16}, registry, token_store
    )
    assert ok is False
    proto._send_control.assert_called_once()

    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg["type"] == "AUTH_FAIL"


async def test_auth_fail_schedules_close() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()

    handle_auth(proto, {"type": "AUTH", "token": b"\xff" * 16}, registry, token_store)
    await asyncio.sleep(0)
    proto._quic.close.assert_called()


async def test_auth_fail_reason_phrase_is_str() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()

    handle_auth(proto, {"type": "AUTH", "token": b"\xff" * 16}, registry, token_store)
    await asyncio.sleep(0)

    proto._quic.close.assert_called()
    call_kwargs = proto._quic.close.call_args.kwargs
    assert call_kwargs.get("reason_phrase") == "auth failed"
    assert isinstance(call_kwargs["reason_phrase"], str)


# ---------------------------------------------------------------------------
# decode_control size limit
# ---------------------------------------------------------------------------


def test_decode_control_oversized_raises() -> None:
    oversized = b"\x00" * 65537
    with pytest.raises(ValueError):
        decode_control(oversized)


def test_decode_control_max_size_ok() -> None:
    msg = {"type": "PING", "ts": 0.0}
    payload = cbor2.dumps(msg)
    assert len(payload) < 65536
    result = decode_control(payload)
    assert result == msg


# ---------------------------------------------------------------------------
# FrameDecoder buffer overflow
# ---------------------------------------------------------------------------


def test_frame_decoder_buffer_overflow_raises() -> None:
    dec = FrameDecoder()
    with pytest.raises(ValueError):
        dec.feed(b"\x00" * 131073)


def test_frame_decoder_buffer_overflow_split_raises() -> None:
    import struct as _struct

    dec = FrameDecoder()
    first = _struct.pack("<H", 65535) + b"\xab" * 65533
    assert len(first) == 65535
    dec.feed(first)
    assert len(dec._buffer) == 65535

    with pytest.raises(ValueError):
        dec.feed(b"\xcd" * 65538)


# ---------------------------------------------------------------------------
# DatabaseStore constant-time validation
# ---------------------------------------------------------------------------


def test_token_store_constant_time_wrong_token() -> None:
    token_store = _make_token_store()
    result = token_store.validate(b"\xff" * 16)
    assert result is None


def test_token_store_correct_token_returns_config() -> None:
    token_store = _make_token_store()
    result = token_store.validate(b"\x00" * 16)
    assert result is not None
    assert result.role == "vehicle"


# ---------------------------------------------------------------------------
# ACL tests — GCS subscribe authorisation
# ---------------------------------------------------------------------------


def test_subscribe_acl_rejects_wrong_vehicle() -> None:
    registry = SessionRegistry()
    proto = _make_proto()
    proto._role = "gcs"
    proto._session_id = "GCS_000001"
    proto._allowed_vehicle_id = "BB_000001"

    handle_subscribe(proto, {"type": "SUBSCRIBE", "vehicle_id": "BB_999999"}, registry)

    proto._send_control.assert_called_once()
    proto.transmit.assert_called_once()
    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg["type"] == "SUB_FAIL"
    assert msg["reason"] == "not authorised for this vehicle"
    assert msg["vehicle_id"] == "BB_999999"


@pytest.mark.asyncio
async def test_subscribe_acl_allows_provisioned_vehicle(
    registry: SessionRegistry,
) -> None:
    proto = _make_proto()
    proto._role = "gcs"
    proto._session_id = "GCS_000001"
    proto._allowed_vehicle_id = "BB_000001"

    await registry.register_vehicle(
        "BB_000001", MagicMock(name="vehicle-proto"), (0, 4, 8)
    )
    await registry.register_gcs("GCS_000001", proto, (0, 4, 8))

    handle_subscribe(proto, {"type": "SUBSCRIBE", "vehicle_id": "BB_000001"}, registry)

    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg == {"type": "SUB_OK", "vehicle_id": "BB_000001"}
