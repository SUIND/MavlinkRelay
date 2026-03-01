"""CBOR control message encoding/decoding and handler functions.

Handles the control stream (stream 0) message lifecycle:
- Encoding/decoding CBOR messages with length-prefix framing
- AUTH: validate token, register session in registry, send AUTH_OK/AUTH_FAIL
- SUBSCRIBE (GCS only): subscribe GCS to a vehicle, send SUB_OK/SUB_FAIL
- PING: respond immediately with PONG containing the same timestamp
"""

from __future__ import annotations

import asyncio
import logging
from typing import TYPE_CHECKING, Any

import cbor2  # type: ignore[reportMissingImports]

from mavlink_relay_server.framing import encode_frame

if TYPE_CHECKING:
    from mavlink_relay_server.config import TokenStore
    from mavlink_relay_server.protocol import RelayProtocol
    from mavlink_relay_server.registry import SessionRegistry

logger = logging.getLogger(__name__)

# Fixed QUIC stream IDs used by clients (client-initiated, 4n format).
_CONTROL_STREAM_ID: int = 0
_PRIORITY_STREAM_ID: int = 4
_BULK_STREAM_ID: int = 8

# Server-initiated bidirectional stream IDs used when the server pushes frames
# *to* a GCS client.  QUIC (RFC 9000) assigns server-initiated bidi streams
# the IDs 1, 5, 9, … (4n+1), so these are the server-side counterparts of
# the client's priority (4) and bulk (8) channels.
_SERVER_PRIORITY_STREAM_ID: int = 1
_SERVER_BULK_STREAM_ID: int = 5

_MAX_CONTROL_PAYLOAD: int = 65536  # 64 KiB


def encode_control(msg: dict[str, Any]) -> bytes:
    """CBOR-encode a control message and wrap with length-prefix framing.

    Args:
        msg: Dict to encode as CBOR.

    Returns:
        Length-prefixed CBOR bytes suitable for sending on stream 0.
    """
    return encode_frame(cbor2.dumps(msg))


def decode_control(data: bytes) -> dict[str, Any]:
    """CBOR-decode a control message payload (without length prefix).

    Args:
        data: Raw CBOR bytes (the frame payload, without the 2-byte length header).

    Returns:
        Decoded dict from CBOR.

    Raises:
        ValueError: If the payload exceeds _MAX_CONTROL_PAYLOAD bytes.
        cbor2.CBORDecodeError: If the data is not valid CBOR.
    """
    if len(data) > _MAX_CONTROL_PAYLOAD:
        raise ValueError(f"Control payload too large: {len(data)} bytes")
    return cbor2.loads(data)  # type: ignore[return-value]


def handle_auth(
    protocol: RelayProtocol,
    msg: dict[str, Any],
    registry: SessionRegistry,
    token_store: TokenStore,
) -> bool:
    """Validate token, register session, send AUTH_OK or AUTH_FAIL.

    Validates the token from the control message against the token store.
    On failure, sends AUTH_FAIL and schedules a connection close.
    On success, registers the session in the registry and sends AUTH_OK.

    Args:
        protocol: The :class:`~mavlink_relay_server.protocol.RelayProtocol`
            instance representing this connection.
        msg: The decoded AUTH control message dict.  Must contain ``"token"``
            (bytes).
        registry: Shared session registry.
        token_store: Token validation store.

    Returns:
        True on successful authentication, False on failure.
    """
    # Guard: prevent re-authentication
    if protocol._authed:
        logger.warning(
            "Re-auth attempt from already-authenticated session %s — ignored",
            protocol._session_id,
        )
        return False

    token_bytes = msg.get("token")
    if not isinstance(token_bytes, bytes):
        _send_auth_fail(protocol, "token must be bytes")
        return False

    token_config = token_store.validate(token_bytes)
    if token_config is None:
        logger.warning("AUTH failed: invalid token from peer")
        _send_auth_fail(protocol, "invalid token")
        return False

    role = token_config.role
    if role == "vehicle":
        vehicle_id = token_config.vehicle_id
        if vehicle_id is None:
            logger.error("TokenConfig for vehicle missing vehicle_id")
            _send_auth_fail(protocol, "server configuration error")
            return False
        asyncio.ensure_future(
            registry.register_vehicle(
                vehicle_id,
                protocol,
                (_CONTROL_STREAM_ID, _PRIORITY_STREAM_ID, _BULK_STREAM_ID),
            )
        )
        protocol._session_id = vehicle_id
        logger.info("Vehicle '%s' authenticated", vehicle_id)

    elif role == "gcs":
        gcs_id = token_config.gcs_id
        if gcs_id is None:
            logger.error("TokenConfig for GCS missing gcs_id")
            _send_auth_fail(protocol, "server configuration error")
            return False
        asyncio.ensure_future(
            registry.register_gcs(
                gcs_id,
                protocol,
                (_CONTROL_STREAM_ID, _SERVER_PRIORITY_STREAM_ID, _SERVER_BULK_STREAM_ID),
            )
        )
        protocol._session_id = gcs_id
        logger.info("GCS '%s' authenticated", gcs_id)

    else:
        logger.error("TokenConfig has unknown role '%s'", role)
        _send_auth_fail(protocol, "unknown role")
        return False

    # Cancel the pending auth timeout — client has authenticated successfully.
    if protocol._auth_timeout_handle is not None:
        protocol._auth_timeout_handle.cancel()
        protocol._auth_timeout_handle = None

    protocol._authed = True
    protocol._role = role

    protocol._start_keepalive()

    auth_ok: dict[str, Any] = {"type": "AUTH_OK"}
    protocol._send_control(encode_control(auth_ok))
    protocol.transmit()
    return True


def handle_subscribe(
    protocol: RelayProtocol,
    msg: dict[str, Any],
    registry: SessionRegistry,
) -> None:
    """Subscribe a GCS session to a vehicle.

    Only valid for connections that have authenticated as GCS role.
    Sends SUB_OK on success or SUB_FAIL if the vehicle is not found or GCS is already subscribed.

    Args:
        protocol: The :class:`~mavlink_relay_server.protocol.RelayProtocol`
            instance representing this connection.
        msg: The decoded SUBSCRIBE control message dict.  Must contain
            ``"vehicle_id"`` (str).
        registry: Shared session registry.
    """
    if protocol._role != "gcs":
        logger.debug(
            "SUBSCRIBE ignored: not a GCS connection (role=%s)", protocol._role
        )
        return

    vehicle_id = msg.get("vehicle_id")
    if not isinstance(vehicle_id, str):
        logger.warning("SUBSCRIBE missing or invalid vehicle_id field")
        return

    vehicle_session = registry.get_vehicle(vehicle_id)
    if vehicle_session is None:
        logger.info(
            "GCS '%s' tried to subscribe to unknown vehicle %s",
            protocol._session_id,
            vehicle_id,
        )
        sub_fail: dict[str, Any] = {
            "type": "SUB_FAIL",
            "vehicle_id": vehicle_id,
            "reason": "vehicle not connected",
        }
        protocol._send_control(encode_control(sub_fail))
        protocol.transmit()
        return

    gcs_id = protocol._session_id
    if gcs_id is None:
        logger.error("GCS session_id is None during SUBSCRIBE — should not happen")
        return

    gcs_session = registry.get_gcs(gcs_id)
    if gcs_session is not None and gcs_session.subscribed_vehicle_id is not None:
        already_sub_fail: dict[str, Any] = {
            "type": "SUB_FAIL",
            "vehicle_id": vehicle_id,
            "reason": "already subscribed",
        }
        protocol._send_control(encode_control(already_sub_fail))
        protocol.transmit()
        logger.info(
            "GCS '%s' already subscribed to vehicle '%s'; rejected subscribe to '%s'",
            gcs_id,
            gcs_session.subscribed_vehicle_id,
            vehicle_id,
        )
        return

    asyncio.ensure_future(registry.subscribe(gcs_id, vehicle_id))

    sub_ok: dict[str, Any] = {"type": "SUB_OK", "vehicle_id": vehicle_id}
    protocol._send_control(encode_control(sub_ok))
    protocol.transmit()
    logger.info("GCS '%s' subscribed to vehicle %s (SUB_OK sent)", gcs_id, vehicle_id)


def handle_ping(protocol: RelayProtocol, msg: dict[str, Any]) -> None:
    """Respond to a PING control message with an immediate PONG.

    Echoes the ``ts`` field from the PING back in the PONG so the client
    can compute round-trip time.

    Args:
        protocol: The :class:`~mavlink_relay_server.protocol.RelayProtocol`
            instance representing this connection.
        msg: The decoded PING control message dict.  May contain ``"ts"``
            (float timestamp).
    """
    pong: dict[str, Any] = {"type": "PONG", "ts": msg.get("ts", 0.0)}
    protocol._send_control(encode_control(pong))
    protocol.transmit()


# ------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------


def _send_auth_fail(protocol: RelayProtocol, reason: str) -> None:
    """Send an AUTH_FAIL message and schedule a connection close.

    Args:
        protocol: The connection to send the failure on.
        reason: Human-readable failure reason string.
    """
    auth_fail: dict[str, Any] = {"type": "AUTH_FAIL", "reason": reason}
    protocol._send_control(encode_control(auth_fail))
    protocol.transmit()
    # Schedule close after flushing — give the client a chance to read the message.
    loop = asyncio.get_event_loop()
    loop.call_soon(
        lambda: (
            protocol._quic.close(
                error_code=0x02,
                reason_phrase="auth failed",
            ),
            protocol.transmit(),
        )
    )
