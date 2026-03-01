"""Security-focused tests for the MAVLink QUIC relay server.

Covers: re-auth attack prevention, auth-fail CBOR content, reason phrase,
decode_control size limit, FrameDecoder buffer overflow, and TokenStore
constant-time comparison.
"""

from __future__ import annotations

# pyright: reportMissingImports=false

import asyncio
import base64
import struct
from typing import Any
from unittest.mock import MagicMock

import cbor2
import pytest

from mavlink_relay_server.config import TokenConfig, TokenStore
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
    proto._auth_timeout_handle = MagicMock()
    proto._quic = MagicMock()
    return proto


def _make_token_store(
    vehicle_token: bytes = b"\x00" * 16,
    gcs_token: bytes = b"\xbb" * 16,
) -> TokenStore:
    vehicle_b64 = base64.b64encode(vehicle_token).decode("ascii")
    gcs_b64 = base64.b64encode(gcs_token).decode("ascii")
    tokens = [
        TokenConfig(
            token_b64=vehicle_b64, role="vehicle", vehicle_id="BB_000001", gcs_id=None
        ),
        TokenConfig(token_b64=gcs_b64, role="gcs", vehicle_id=None, gcs_id="gcs-alpha"),
    ]
    return TokenStore(tokens)


# ---------------------------------------------------------------------------
# Re-auth attack tests
# ---------------------------------------------------------------------------


async def test_re_auth_attack_ignored() -> None:
    """Second handle_auth call on an already-authed session must return False
    and must NOT send another AUTH_OK (send_control call count stays at 1)."""
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()
    vehicle_token = b"\x00" * 16

    # First auth — succeeds
    ok1 = handle_auth(
        proto, {"type": "AUTH", "token": vehicle_token}, registry, token_store
    )
    assert ok1 is True
    assert proto._authed is True
    assert proto._send_control.call_count == 1

    # Second auth — must be rejected silently
    ok2 = handle_auth(
        proto, {"type": "AUTH", "token": vehicle_token}, registry, token_store
    )
    assert ok2 is False
    # No extra _send_control call
    assert proto._send_control.call_count == 1
    assert proto._authed is True


async def test_re_auth_attack_with_different_token_ignored() -> None:
    """Re-auth with a *different* valid token must also be rejected.
    Role and session_id must remain from the original auth."""
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()
    vehicle_token = b"\x00" * 16
    gcs_token = b"\xbb" * 16

    # First auth as vehicle
    ok1 = handle_auth(
        proto, {"type": "AUTH", "token": vehicle_token}, registry, token_store
    )
    assert ok1 is True
    assert proto._role == "vehicle"
    assert proto._session_id == "BB_000001"

    ok2 = handle_auth(
        proto, {"type": "AUTH", "token": gcs_token}, registry, token_store
    )
    assert ok2 is False
    assert proto._role == "vehicle"
    assert proto._session_id == "BB_000001"


def test_subscribe_before_auth_is_noop() -> None:
    """handle_subscribe on an unauthenticated proto (role=None) must be a no-op."""
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
    """Wrong token must cause _send_control to be called with an AUTH_FAIL CBOR message."""
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
    """After a failed auth, proto._quic.close must eventually be called."""
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()

    handle_auth(proto, {"type": "AUTH", "token": b"\xff" * 16}, registry, token_store)
    # call_soon callbacks run after yielding to the event loop
    await asyncio.sleep(0)
    proto._quic.close.assert_called()


async def test_auth_fail_reason_phrase_is_str() -> None:
    """_send_auth_fail must close with reason_phrase='auth failed' (plain str, no info leak)."""
    registry = SessionRegistry()
    token_store = _make_token_store()
    proto = _make_proto()

    handle_auth(proto, {"type": "AUTH", "token": b"\xff" * 16}, registry, token_store)
    await asyncio.sleep(0)

    proto._quic.close.assert_called()
    call_kwargs = proto._quic.close.call_args.kwargs
    assert call_kwargs.get("reason_phrase") == "auth failed"
    # Must be a plain str (not an f-string result that could leak token data)
    assert isinstance(call_kwargs["reason_phrase"], str)


# ---------------------------------------------------------------------------
# decode_control size limit
# ---------------------------------------------------------------------------


def test_decode_control_oversized_raises() -> None:
    """Payloads larger than 65536 bytes must raise ValueError."""
    oversized = b"\x00" * 65537
    with pytest.raises(ValueError):
        decode_control(oversized)


def test_decode_control_max_size_ok() -> None:
    """Normal CBOR messages well under 65536 bytes must not raise."""
    msg = {"type": "PING", "ts": 0.0}
    payload = cbor2.dumps(msg)
    assert len(payload) < 65536
    result = decode_control(payload)
    assert result == msg


# ---------------------------------------------------------------------------
# FrameDecoder buffer overflow
# ---------------------------------------------------------------------------


def test_frame_decoder_buffer_overflow_raises() -> None:
    """Feeding more than 131072 bytes in one call must raise ValueError."""
    dec = FrameDecoder()
    with pytest.raises(ValueError):
        dec.feed(b"\x00" * 131073)


def test_frame_decoder_buffer_overflow_split_raises() -> None:
    """Cumulative overflow across two feeds must also raise ValueError."""
    import struct as _struct

    dec = FrameDecoder()
    first = _struct.pack("<H", 65535) + b"\xab" * 65533
    assert len(first) == 65535
    dec.feed(first)
    assert len(dec._buffer) == 65535

    with pytest.raises(ValueError):
        dec.feed(b"\xcd" * 65538)


# ---------------------------------------------------------------------------
# TokenStore constant-time validation
# ---------------------------------------------------------------------------


def test_token_store_constant_time_wrong_token() -> None:
    """A wrong token must return None (constant-time comparison rejects it)."""
    token_store = _make_token_store()
    result = token_store.validate(b"\xff" * 16)
    assert result is None


def test_token_store_correct_token_returns_config() -> None:
    """The correct vehicle token (b'\\x00' * 16) must return a TokenConfig with role='vehicle'."""
    token_store = _make_token_store()
    result = token_store.validate(b"\x00" * 16)
    assert result is not None
    assert result.role == "vehicle"
