from __future__ import annotations

# pyright: reportMissingImports=false

import asyncio
import struct
from typing import Any
from unittest.mock import MagicMock

import cbor2
import pytest

from mavlink_relay_server.config import TokenStore
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
    proto._auth_timeout_handle = MagicMock()
    proto._quic = MagicMock()
    return proto


def test_encode_control_and_decode_control_roundtrip() -> None:
    msgs: list[dict[str, Any]] = [
        {"type": "AUTH_OK"},
        {"type": "PING", "ts": 123.456},
        {"type": "VEHICLE_OFFLINE", "vehicle_id": "BB_000001"},
    ]

    for msg in msgs:
        framed = encode_control(msg)
        decoded = _decode_framed_control(framed)
        assert decoded == msg

        raw = cbor2.dumps(msg)
        assert decode_control(raw) == msg


@pytest.mark.asyncio
async def test_handle_auth_valid_vehicle_token_sets_state_and_sends_auth_ok(
    registry: SessionRegistry,
    token_store: TokenStore,
    vehicle_token_bytes: bytes,
) -> None:
    proto = _make_proto()
    timeout_handle = proto._auth_timeout_handle

    ok = handle_auth(
        proto,
        {"type": "AUTH", "token": vehicle_token_bytes},
        registry,
        token_store,
    )
    assert ok is True
    assert proto._authed is True
    assert proto._role == "vehicle"
    assert proto._session_id == "BB_000001"
    assert proto._auth_timeout_handle is None
    timeout_handle.cancel.assert_called_once()
    proto._start_keepalive.assert_called_once()
    proto._send_control.assert_called_once()
    proto.transmit.assert_called_once()

    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg == {"type": "AUTH_OK"}

    await asyncio.sleep(0)
    v = registry.get_vehicle("BB_000001")
    assert v is not None
    assert v.protocol is proto
    assert (v.control_stream_id, v.priority_stream_id, v.bulk_stream_id) == (0, 4, 8)


@pytest.mark.asyncio
async def test_handle_auth_valid_gcs_token_sets_state_and_sends_auth_ok(
    registry: SessionRegistry,
    token_store: TokenStore,
    gcs_token_bytes: bytes,
) -> None:
    proto = _make_proto()
    timeout_handle = proto._auth_timeout_handle

    ok = handle_auth(
        proto,
        {"type": "AUTH", "token": gcs_token_bytes},
        registry,
        token_store,
    )
    assert ok is True
    assert proto._authed is True
    assert proto._role == "gcs"
    assert proto._session_id == "gcs-alpha"
    assert proto._auth_timeout_handle is None
    timeout_handle.cancel.assert_called_once()
    proto._start_keepalive.assert_called_once()

    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg == {"type": "AUTH_OK"}

    await asyncio.sleep(0)
    g = registry.get_gcs("gcs-alpha")
    assert g is not None
    assert g.protocol is proto


@pytest.mark.asyncio
async def test_handle_auth_invalid_token_returns_false_and_sends_auth_fail(
    registry: SessionRegistry,
    token_store: TokenStore,
) -> None:
    proto = _make_proto()
    ok = handle_auth(
        proto, {"type": "AUTH", "token": b"\x01" * 16}, registry, token_store
    )
    assert ok is False
    proto._send_control.assert_called_once()

    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg["type"] == "AUTH_FAIL"
    assert msg["reason"] == "invalid token"

    await asyncio.sleep(0)
    proto._quic.close.assert_called()


@pytest.mark.asyncio
async def test_handle_auth_non_bytes_token_returns_false(
    registry: SessionRegistry,
    token_store: TokenStore,
) -> None:
    proto = _make_proto()
    ok = handle_auth(proto, {"type": "AUTH", "token": "nope"}, registry, token_store)
    assert ok is False
    proto._send_control.assert_called_once()
    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg["type"] == "AUTH_FAIL"
    assert msg["reason"] == "token must be bytes"
    await asyncio.sleep(0)
    proto._quic.close.assert_called()


def test_handle_subscribe_non_gcs_role_is_noop(registry: SessionRegistry) -> None:
    proto = _make_proto()
    proto._role = "vehicle"
    handle_subscribe(proto, {"type": "SUBSCRIBE", "vehicle_id": "BB_000001"}, registry)
    proto._send_control.assert_not_called()
    proto.transmit.assert_not_called()


def test_handle_subscribe_gcs_invalid_vehicle_id_field_is_noop(
    registry: SessionRegistry,
) -> None:
    proto = _make_proto()
    proto._role = "gcs"
    proto._session_id = "gcs-alpha"
    handle_subscribe(proto, {"type": "SUBSCRIBE", "vehicle_id": 1}, registry)
    proto._send_control.assert_not_called()
    proto.transmit.assert_not_called()


def test_handle_subscribe_gcs_vehicle_not_found_sends_sub_fail(
    registry: SessionRegistry,
) -> None:
    proto = _make_proto()
    proto._role = "gcs"
    proto._session_id = "gcs-alpha"
    handle_subscribe(proto, {"type": "SUBSCRIBE", "vehicle_id": "BB_000001"}, registry)
    proto._send_control.assert_called_once()
    proto.transmit.assert_called_once()
    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg["type"] == "SUB_FAIL"
    assert msg["vehicle_id"] == "BB_000001"


@pytest.mark.asyncio
async def test_handle_subscribe_gcs_vehicle_found_sends_sub_ok_and_subscribes(
    registry: SessionRegistry,
) -> None:
    proto = _make_proto()
    proto._role = "gcs"
    proto._session_id = "gcs-alpha"

    await registry.register_vehicle(
        "BB_000001", MagicMock(name="vehicle-proto"), (0, 4, 8)
    )
    await registry.register_gcs("gcs-alpha", proto, (0, 4, 8))

    handle_subscribe(proto, {"type": "SUBSCRIBE", "vehicle_id": "BB_000001"}, registry)
    proto._send_control.assert_called_once()
    proto.transmit.assert_called_once()
    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg == {"type": "SUB_OK", "vehicle_id": "BB_000001"}

    await asyncio.sleep(0)
    gcs = registry.get_gcs("gcs-alpha")
    assert gcs is not None
    assert gcs.subscribed_vehicle_id == "BB_000001"


def test_handle_ping_sends_pong_with_same_ts() -> None:
    proto = _make_proto()
    handle_ping(proto, {"type": "PING", "ts": 42.0})
    proto._send_control.assert_called_once()
    proto.transmit.assert_called_once()
    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg == {"type": "PONG", "ts": 42.0}


@pytest.mark.asyncio
async def test_handle_subscribe_already_subscribed_gcs_sends_sub_fail(
    registry: SessionRegistry,
) -> None:
    proto = _make_proto()
    proto._role = "gcs"
    proto._session_id = "gcs-alpha"

    await registry.register_vehicle(
        "BB_000001", MagicMock(name="vehicle-proto"), (0, 4, 8)
    )
    await registry.register_gcs("gcs-alpha", proto, (0, 4, 8))

    handle_subscribe(proto, {"type": "SUBSCRIBE", "vehicle_id": "BB_000001"}, registry)
    await asyncio.sleep(0)
    proto.reset_mock()

    handle_subscribe(proto, {"type": "SUBSCRIBE", "vehicle_id": "BB_000001"}, registry)
    proto._send_control.assert_called_once()
    proto.transmit.assert_called_once()
    msg = _decode_framed_control(proto._send_control.call_args.args[0])
    assert msg["type"] == "SUB_FAIL"
    assert msg["reason"] == "already subscribed"
