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
from mavlink_relay_server.control import (
    decode_control,
    encode_control,
    handle_auth,
    handle_ping,
    handle_subscribe,
)
from mavlink_relay_server.protocol import RelayProtocol
from mavlink_relay_server.registry import SessionRegistry


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


def test_encode_decode_all_control_message_types() -> None:
    messages: list[dict[str, Any]] = [
        {"type": "AUTH_OK"},
        {"type": "AUTH_FAIL", "reason": "invalid token"},
        {"type": "SUB_OK", "vehicle_id": "BB_000001"},
        {
            "type": "SUB_FAIL",
            "vehicle_id": "BB_000001",
            "reason": "vehicle not connected",
        },
        {"type": "VEHICLE_OFFLINE", "vehicle_id": "BB_000001"},
        {"type": "PING", "ts": 12345.678},
        {"type": "PONG", "ts": 12345.678},
    ]
    for msg in messages:
        framed = encode_control(msg)
        decoded = _decode_framed_control(framed)
        assert decoded == msg, f"Roundtrip failed for {msg}"


async def test_handle_auth_vehicle_registers_in_registry() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()

    ok = handle_auth(
        proto,
        {"type": "AUTH", "token": b"\x00" * 16, "vehicle_id": "BB_000001"},
        registry,
        token_store,
    )
    assert ok is True
    await asyncio.sleep(0)
    v = registry.get_vehicle("BB_000001")
    assert v is not None
    assert v.protocol is proto


async def test_handle_auth_gcs_registers_in_registry() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()

    ok = handle_auth(
        proto,
        {"type": "AUTH", "token": b"\xbb" * 16, "vehicle_id": "BB_000001"},
        registry,
        token_store,
    )
    assert ok is True
    await asyncio.sleep(0)
    g = registry.get_gcs("GCS_000001")
    assert g is not None
    assert g.protocol is proto


async def test_full_auth_and_subscribe_flow() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    v_proto = _make_proto()
    g_proto = _make_proto()

    handle_auth(
        v_proto,
        {"type": "AUTH", "token": b"\x00" * 16, "vehicle_id": "BB_000001"},
        registry,
        token_store,
    )
    await asyncio.sleep(0)

    handle_auth(
        g_proto,
        {"type": "AUTH", "token": b"\xbb" * 16, "vehicle_id": "BB_000001"},
        registry,
        token_store,
    )
    await asyncio.sleep(0)

    handle_subscribe(
        g_proto, {"type": "SUBSCRIBE", "vehicle_id": "BB_000001"}, registry
    )
    await asyncio.sleep(0)

    gcs_session = registry.get_gcs("GCS_000001")
    assert gcs_session is not None
    assert gcs_session.subscribed_vehicle_id == "BB_000001"


async def test_handle_auth_missing_token_field_returns_false() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()

    ok = handle_auth(proto, {"type": "AUTH"}, registry, token_store)
    assert ok is False


async def test_handle_auth_none_token_returns_false() -> None:
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()

    ok = handle_auth(proto, {"type": "AUTH", "token": None}, registry, token_store)
    assert ok is False


def test_decode_control_valid_cbor() -> None:
    for msg in [
        {"type": "AUTH_OK"},
        {"type": "PING", "ts": 0.5},
        {"type": "VEHICLE_OFFLINE", "vehicle_id": 99},
    ]:
        payload = cbor2.dumps(msg)
        assert decode_control(payload) == msg


def test_decode_control_invalid_cbor_raises() -> None:
    with pytest.raises(cbor2.CBORDecodeError):
        decode_control(b"\x1e")


def test_handle_ping_no_ts_uses_zero() -> None:
    proto = _make_proto()
    handle_ping(proto, {"type": "PING"})
    proto._send_control.assert_called_once()
    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg == {"type": "PONG", "ts": 0.0}


def test_bulk_queue_drop_oldest_logic() -> None:
    q: asyncio.Queue[int] = asyncio.Queue(maxsize=3)
    q.put_nowait(1)
    q.put_nowait(2)
    q.put_nowait(3)
    assert q.full()

    dropped = q.get_nowait()
    assert dropped == 1
    q.put_nowait(4)

    items = [q.get_nowait(), q.get_nowait(), q.get_nowait()]
    assert items == [2, 3, 4]
