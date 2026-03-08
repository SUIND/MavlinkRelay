"""QUIC protocol implementation for MAVLink relay.

Each incoming QUIC connection is handled by one :class:`RelayProtocol` instance.
The class dispatches aioquic events to purpose-built handler methods and manages
the per-connection auth timeout.

Stream routing convention (QUIC client-initiated bidirectional streams):
    - Stream 0  → control channel (CBOR messages)
    - Stream 4  → MAVLink priority channel
    - Stream 8  → MAVLink bulk channel
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import TYPE_CHECKING, Any

import cbor2  # type: ignore[reportMissingImports]

from aioquic.asyncio.protocol import QuicConnectionProtocol  # type: ignore[reportMissingImports]
from aioquic.quic.events import (  # type: ignore[reportMissingImports]
    ConnectionTerminated,
    HandshakeCompleted,
    QuicEvent,
    StreamDataReceived,
)

from mavlink_relay_server.control import (
    decode_control,
    encode_control,
    handle_auth,
    handle_ping,
    handle_subscribe,
)
from mavlink_relay_server.framing import FrameDecoder, encode_frame

if TYPE_CHECKING:
    from mavlink_relay_server.config import ServerConfig, TokenStore
    from mavlink_relay_server.registry import SessionRegistry

logger = logging.getLogger(__name__)

_AUTH_TIMEOUT_ERROR_CODE: int = 0x01
_BULK_STREAM_ID: int = 8


class RelayProtocol(QuicConnectionProtocol):
    """QUIC connection handler for the MAVLink relay server.

    One instance is created per accepted connection.  It manages the auth
    timeout, dispatches incoming QUIC events, accumulates per-stream
    frame data via :class:`~mavlink_relay_server.framing.FrameDecoder`,
    and relays authenticated MAVLink frames between vehicles and GCS clients.

    Args:
        *args: Positional arguments forwarded to
            :class:`~aioquic.asyncio.protocol.QuicConnectionProtocol`.
        registry: Shared :class:`~mavlink_relay_server.registry.SessionRegistry`
            used to register/deregister connected clients.
        server_config: Server-wide configuration (used for auth timeout, etc.).
        token_store: Token validation store for AUTH message handling.
        **kwargs: Keyword arguments forwarded to the base class.
    """

    def __init__(
        self,
        *args: object,
        registry: SessionRegistry,
        server_config: ServerConfig,
        token_store: TokenStore,
        **kwargs: object,
    ) -> None:
        """Initialise connection state and store injected dependencies."""
        super().__init__(*args, **kwargs)  # type: ignore[arg-type]

        self._registry: SessionRegistry = registry
        self._config: ServerConfig = server_config
        self._token_store: TokenStore = token_store

        self._authed: bool = False
        self._role: str | None = None
        self._session_id: str | None = None
        self._stream_buffers: dict[int, FrameDecoder] = {}
        self._auth_timeout_handle: asyncio.TimerHandle | None = None

        self._bulk_out_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=0)
        self._bulk_drop_count: int = 0
        self._bulk_sender_task: asyncio.Task[None] | None = None

        self._keepalive_task: asyncio.Task[None] | None = None
        self._last_pong_monotonic: float = 0.0
        self._connected: bool = True

        # Set of stream IDs that have been activated (i.e. the peer has sent
        # at least one STREAM frame on them, so aioquic has created the stream
        # object and the server is allowed to write back on them).
        self._active_streams: set[int] = set()
        # Frames buffered while waiting for a peer-initiated stream to become
        # active.  Keyed by stream ID; each value is a list of raw payloads.
        self._pending_vehicle_frames: dict[int, list[bytes]] = {}

    # ------------------------------------------------------------------
    # aioquic event dispatch
    # ------------------------------------------------------------------

    def quic_event_received(self, event: QuicEvent) -> None:
        """Dispatch a raw aioquic event to the appropriate handler.

        This method is called by the aioquic transport on the event loop
        thread and **must not block**.  Heavy work should be offloaded via
        :func:`asyncio.ensure_future` or similar.

        Args:
            event: The incoming QUIC event object.
        """
        if isinstance(event, HandshakeCompleted):
            self._on_handshake_completed(event)
        elif isinstance(event, StreamDataReceived):
            self._on_stream_data_received(event)
        elif isinstance(event, ConnectionTerminated):
            self._on_connection_terminated(event)

    # ------------------------------------------------------------------
    # Event handlers (private)
    # ------------------------------------------------------------------

    def _on_handshake_completed(self, event: HandshakeCompleted) -> None:
        """Handle TLS handshake completion.

        Logs the peer address, schedules an auth timeout, and initialises the
        per-connection bulk outbound queue and its background drain task.

        Args:
            event: The :class:`~aioquic.quic.events.HandshakeCompleted` event.
        """
        peer = (
            self._quic._network_paths[0].addr
            if self._quic._network_paths
            else "unknown"
        )
        logger.info("Connection from %s (alpn=%s)", peer, event.alpn_protocol)

        loop = asyncio.get_event_loop()
        self._auth_timeout_handle = loop.call_later(
            self._config.auth_timeout_s,
            self._auth_timeout,
        )

        self._bulk_out_queue = asyncio.Queue(maxsize=self._config.bulk_queue_max)
        self._bulk_sender_task = asyncio.ensure_future(self._bulk_sender())

    def _on_stream_data_received(self, event: StreamDataReceived) -> None:
        """Route incoming stream data to the correct channel handler.

        Args:
            event: The :class:`~aioquic.quic.events.StreamDataReceived` event.
        """
        sid = event.stream_id
        if sid == 0:
            self._handle_control_data(event.data)
        elif sid in (4, 8):
            self._handle_mavlink_data(sid, event.data)
        else:
            logger.debug(
                "Data on unrecognised stream %d (%d bytes)", sid, len(event.data)
            )

    def _on_connection_terminated(self, event: ConnectionTerminated) -> None:
        """Handle connection teardown.

        Cancels the pending auth timeout (if any) and the bulk sender task,
        then logs the termination.

        Args:
            event: The :class:`~aioquic.quic.events.ConnectionTerminated` event.
        """
        self._connected = False
        logger.info(
            "Connection terminated (error_code=0x%x, reason=%r)",
            event.error_code,
            event.reason_phrase,
        )
        if self._auth_timeout_handle is not None:
            self._auth_timeout_handle.cancel()
            self._auth_timeout_handle = None
        if self._keepalive_task is not None:
            self._keepalive_task.cancel()
        if self._bulk_sender_task is not None:
            self._bulk_sender_task.cancel()

        asyncio.ensure_future(self._cleanup_on_disconnect())

    async def _cleanup_on_disconnect(self) -> None:
        """Async cleanup: unregister from registry, notify subscribers."""
        keepalive_task = self._keepalive_task
        bulk_sender_task = self._bulk_sender_task

        if keepalive_task is not None:
            keepalive_task.cancel()
        if bulk_sender_task is not None:
            bulk_sender_task.cancel()

        if keepalive_task is not None:
            try:
                await keepalive_task
            except asyncio.CancelledError:
                pass
            except Exception as exc:
                logger.exception("Keepalive task shutdown error: %s", exc)
        if bulk_sender_task is not None:
            try:
                await bulk_sender_task
            except asyncio.CancelledError:
                pass
            except Exception as exc:
                logger.exception("Bulk sender task shutdown error: %s", exc)

        self._keepalive_task = None
        self._bulk_sender_task = None

        try:
            if self._role == "vehicle" and self._session_id is not None:
                vehicle_id = self._session_id

                notified_gcs_ids = await self._registry.unregister_vehicle(vehicle_id)

                offline_msg = encode_control(
                    {
                        "type": "VEHICLE_OFFLINE",
                        "vehicle_id": vehicle_id,
                    }
                )
                for gcs_id in notified_gcs_ids:
                    gcs_session = self._registry.get_gcs(gcs_id)
                    if gcs_session is not None:
                        if not gcs_session.protocol._connected:
                            continue
                        gcs_session.protocol._send_control(offline_msg)
                        gcs_session.protocol.transmit()

                logger.info(
                    "Vehicle %s disconnected, notified %d GCS clients",
                    vehicle_id,
                    len(notified_gcs_ids),
                )

            elif self._role == "gcs" and self._session_id is not None:
                await self._registry.unregister_gcs(self._session_id, protocol=self)
                logger.info("GCS %r disconnected", self._session_id)
        except Exception as exc:
            logger.exception("Cleanup on disconnect error: %s", exc)

    def _start_keepalive(self) -> None:
        """Start the keepalive loop task. Called after successful AUTH."""
        if self._keepalive_task is not None and not self._keepalive_task.done():
            return
        self._last_pong_monotonic = time.monotonic()
        self._keepalive_task = asyncio.ensure_future(self._keepalive_loop())

    async def _keepalive_loop(self) -> None:
        """Periodically send PING and check for PONG timeout."""
        try:
            while self._connected:
                await asyncio.sleep(self._config.keepalive_interval_s)
                if not self._connected:
                    break

                elapsed = time.monotonic() - self._last_pong_monotonic
                ping_msg: dict[str, Any] = {"type": "PING", "ts": time.time()}
                self._send_control(encode_control(ping_msg))
                self.transmit()
                logger.info("Sent PING to %s (elapsed since last PONG: %.1fs)", self._session_id, elapsed)
                if elapsed > self._config.keepalive_timeout_s:
                    logger.warning(
                        "Keepalive timeout for %s (%.1fs since last PONG)",
                        self._session_id,
                        elapsed,
                    )
                    self._quic.close(
                        error_code=0x02,
                        reason_phrase="keepalive timeout",
                    )
                    self.transmit()
                    break
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            logger.exception("Keepalive loop error: %s", exc)

    # ------------------------------------------------------------------
    # Auth timeout
    # ------------------------------------------------------------------

    def _auth_timeout(self) -> None:
        """Called by the event loop if the client has not authenticated in time.

        Closes the QUIC connection with a protocol-defined error code and
        triggers transmission of the CONNECTION_CLOSE frame.
        """
        if not self._authed:
            logger.warning(
                "Auth timeout — closing connection (session_id=%s)", self._session_id
            )
            self._quic.close(
                error_code=_AUTH_TIMEOUT_ERROR_CODE,
                reason_phrase="auth timeout",
            )
            self.transmit()

    # ------------------------------------------------------------------
    # Stream handlers
    # ------------------------------------------------------------------

    def _handle_control_data(self, data: bytes) -> None:
        """Handle raw bytes received on the control stream (stream 0).

        Feeds data through the per-stream :class:`FrameDecoder`, then
        CBOR-decodes each complete frame and dispatches to the appropriate
        control message handler.

        Args:
            data: Raw bytes from the control stream, possibly a partial frame.
        """
        logger.info(
            "Control stream data from %s: %d bytes, hex=%s",
            self._session_id,
            len(data),
            data[:32].hex(),
        )
        decoder = self._get_or_create_decoder(0)
        try:
            frames = decoder.feed(data)
        except ValueError as exc:
            logger.warning("Invalid control frame: %s", exc)
            return

        for frame_bytes in frames:
            try:
                msg: dict[str, Any] = decode_control(frame_bytes)
            except cbor2.CBORDecodeError as exc:
                logger.warning("CBOR decode error on control stream: %s", exc)
                continue
            msg_type = msg.get("type", "")
            logger.info("Control message from %s: type=%r", self._session_id, msg_type)
            match msg_type:
                case "AUTH":
                    handle_auth(self, msg, self._registry, self._token_store)
                case "SUBSCRIBE":
                    handle_subscribe(self, msg, self._registry)
                case "PING":
                    handle_ping(self, msg)
                case "PONG":
                    self._on_pong(msg)
                case _:
                    logger.debug("Unknown control message type: %r", msg_type)

    def _handle_mavlink_data(self, stream_id: int, data: bytes) -> None:
        """Handle raw bytes received on a MAVLink data stream (stream 4 or 8).

        Drops data if not yet authenticated.  Otherwise, decodes complete
        frames and schedules asynchronous relay to subscribed peers.

        Also marks the stream as *active* on first receipt so that the server
        is allowed to write back on this peer-initiated bidirectional stream
        (aioquic only permits sends on a peer-initiated stream once it has
        seen at least one STREAM frame from the peer).  Any GCS→vehicle frames
        that were buffered while waiting for stream activation are flushed.

        Args:
            stream_id: The QUIC stream ID (4 = priority, 8 = bulk).
            data: Raw bytes from the stream, possibly a partial frame.
        """
        if not self._authed:
            logger.debug("Dropping MAVLink data — not authenticated")
            return

        # Activate stream on first receipt and flush any buffered frames.
        if stream_id not in self._active_streams:
            self._active_streams.add(stream_id)
            pending = self._pending_vehicle_frames.pop(stream_id, [])
            if pending:
                logger.info(
                    "Stream %d activated for %s — flushing %d buffered GCS→vehicle frame(s)",
                    stream_id,
                    self._session_id,
                    len(pending),
                )
                asyncio.ensure_future(self._flush_pending_vehicle_frames(stream_id, pending))

        decoder = self._get_or_create_decoder(stream_id)
        try:
            frames = decoder.feed(data)
        except ValueError as exc:
            logger.warning("Invalid MAVLink frame on stream %d: %s", stream_id, exc)
            return
        if not frames:
            return

        asyncio.ensure_future(self._relay_frames(stream_id, frames))

    # ------------------------------------------------------------------
    # Relay logic
    # ------------------------------------------------------------------

    async def _relay_frames(self, stream_id: int, frames: list[bytes]) -> None:
        """Relay a batch of decoded MAVLink frames to subscribed peers.

        For vehicle connections, forwards to all subscribed GCS sessions.
        For GCS connections, forwards to the subscribed vehicle (if any).

        Args:
            stream_id: The QUIC stream ID the frames arrived on (4 or 8).
            frames: List of complete MAVLink frame payloads (no length prefix).
        """
        is_bulk = stream_id == _BULK_STREAM_ID

        if self._role == "vehicle":
            vehicle_id = self._session_id
            subscribers = self._registry.get_subscribers(vehicle_id)  # type: ignore[arg-type]
            for gcs_session in subscribers:
                # Use the server-initiated outbound stream IDs stored on the
                # GCS session, not the vehicle's inbound stream IDs — QUIC
                # stream IDs are per-connection and directional.
                out_stream_id = (
                    gcs_session.bulk_stream_id
                    if is_bulk
                    else gcs_session.priority_stream_id
                )
                for frame in frames:
                    await self._enqueue_or_relay(
                        gcs_session.protocol, out_stream_id, frame, is_bulk=is_bulk
                    )
            for gcs_session in subscribers:
                if not is_bulk:
                    gcs_session.protocol.transmit()

        elif self._role == "gcs":
            vehicle_session = self._registry.get_vehicle_for_gcs(self._session_id)  # type: ignore[arg-type]
            if vehicle_session is None:
                return
            vehicle_proto = vehicle_session.protocol
            async with vehicle_session.write_lock:
                if stream_id not in vehicle_proto._active_streams:
                    # The vehicle hasn't sent any data on this stream yet, so
                    # aioquic doesn't have a stream object for it and will raise
                    # "Cannot send data on unknown peer-initiated stream".
                    # Buffer the frames; they will be flushed when the vehicle
                    # activates the stream by sending its first MAVLink frame.
                    pending = vehicle_proto._pending_vehicle_frames.setdefault(stream_id, [])
                    pending.extend(frames)
                    logger.debug(
                        "GCS '%s' → vehicle '%s': stream %d not yet active, buffered %d frame(s) (%d total pending)",
                        self._session_id,
                        vehicle_session.vehicle_id,
                        stream_id,
                        len(frames),
                        len(pending),
                    )
                    return
                for frame in frames:
                    try:
                        vehicle_proto._send_frame(stream_id, frame)
                    except ValueError as exc:
                        logger.warning(
                            "GCS '%s' → vehicle '%s': cannot send on stream %d: %s",
                            self._session_id,
                            vehicle_session.vehicle_id,
                            stream_id,
                            exc,
                        )
                        return
                vehicle_proto.transmit()

    async def _flush_pending_vehicle_frames(self, stream_id: int, frames: list[bytes]) -> None:
        """Send buffered GCS→vehicle frames after a vehicle stream becomes active.

        Called when *stream_id* receives its first data from the vehicle,
        indicating aioquic now has a stream object and permits server-side
        sends on it.

        Args:
            stream_id: The now-active QUIC stream ID.
            frames: Buffered frame payloads to send, in arrival order.
        """
        try:
            self._quic.send_stream_data  # ensure we still have a connection
            for frame in frames:
                try:
                    self._send_frame(stream_id, frame)
                except ValueError as exc:
                    logger.warning(
                        "Flush buffered frame on stream %d for %s failed: %s",
                        stream_id,
                        self._session_id,
                        exc,
                    )
                    return
            self.transmit()
        except Exception as exc:
            logger.exception("_flush_pending_vehicle_frames error: %s", exc)

    async def _enqueue_or_relay(
        self,
        target: RelayProtocol,
        stream_id: int,
        frame: bytes,
        *,
        is_bulk: bool,
    ) -> None:
        """Send a single MAVLink frame to a target connection.

        Priority frames are sent directly; bulk frames go through the target's
        outbound queue with drop-oldest backpressure.

        Args:
            target: The destination :class:`RelayProtocol` connection.
            stream_id: The QUIC stream ID to send on.
            frame: Complete MAVLink frame payload (no length prefix).
            is_bulk: True if this is a bulk-stream frame (stream 8).
        """
        if not is_bulk:
            try:
                target._send_frame(stream_id, frame)
            except ValueError as exc:
                logger.warning(
                    "Cannot relay priority frame to '%s' on stream %d: %s",
                    target._session_id,
                    stream_id,
                    exc,
                )
        else:
            if target._bulk_out_queue.full():
                try:
                    target._bulk_out_queue.get_nowait()
                    target._bulk_drop_count += 1
                    logger.warning(
                        "Bulk queue full for session %s — dropped oldest frame "
                        "(total drops: %d)",
                        target._session_id,
                        target._bulk_drop_count,
                    )
                except asyncio.QueueEmpty:
                    pass
            target._bulk_out_queue.put_nowait(frame)

    async def _bulk_sender(self) -> None:
        """Background task that drains the bulk outbound queue and sends frames.

        Runs for the lifetime of the connection; cancelled on disconnect.
        """
        try:
            while True:
                frame = await self._bulk_out_queue.get()
                self._send_frame(_BULK_STREAM_ID, frame)
                self.transmit()
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            logger.exception("bulk_sender error: %s", exc)

    # ------------------------------------------------------------------
    # PONG handler (stub for Task 7 keepalive)
    # ------------------------------------------------------------------

    def _on_pong(self, msg: dict[str, Any]) -> None:
        """Record PONG receipt and compute latency."""
        self._last_pong_monotonic = time.monotonic()
        ts = msg.get("ts", 0.0)
        latency_ms = 0.0
        if ts:
            try:
                latency_ms = (time.time() - float(ts)) * 1000
            except (TypeError, ValueError):
                pass
        logger.info("PONG from %s, latency=%.1f ms", self._session_id, latency_ms)

    # ------------------------------------------------------------------
    # Send helpers
    # ------------------------------------------------------------------

    def _send_frame(self, stream_id: int, payload: bytes) -> None:
        """Write a length-prefixed MAVLink frame to a QUIC stream.

        Callers are responsible for calling :meth:`transmit` after batching
        all frames to avoid per-frame round trips.

        Args:
            stream_id: The QUIC stream to write on.
            payload: Raw MAVLink frame bytes (no length prefix; one will be added).
        """
        self._quic.send_stream_data(stream_id, encode_frame(payload))

    def _send_control(self, data: bytes) -> None:
        """Write pre-encoded control data to stream 0.

        The *data* argument must already be length-prefixed (i.e. produced by
        :func:`~mavlink_relay_server.control.encode_control`).  Callers must
        call :meth:`transmit` after this method to flush the data.

        Args:
            data: Pre-encoded (length-prefixed CBOR) control message bytes.
        """
        self._quic.send_stream_data(0, data)

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _get_or_create_decoder(self, stream_id: int) -> FrameDecoder:
        """Return (or lazily create) the :class:`FrameDecoder` for *stream_id*.

        Args:
            stream_id: QUIC stream identifier.

        Returns:
            The :class:`~mavlink_relay_server.framing.FrameDecoder` bound to
            this stream.
        """
        if stream_id not in self._stream_buffers:
            self._stream_buffers[stream_id] = FrameDecoder()
        return self._stream_buffers[stream_id]
