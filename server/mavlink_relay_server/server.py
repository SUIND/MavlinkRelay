"""Server implementation for MAVLink QUIC relay.

Provides the async entry point that binds a QUIC/UDP socket, loads TLS credentials,
and runs until SIGINT/SIGTERM is received.
"""

from __future__ import annotations

import asyncio
import logging
import signal
from typing import TYPE_CHECKING

from aioquic.asyncio import serve
from aioquic.quic.configuration import QuicConfiguration

if TYPE_CHECKING:
    from mavlink_relay_server.config import ServerConfig

logger = logging.getLogger(__name__)


async def run_server(config: ServerConfig) -> None:
    """Start the QUIC relay server and run until a shutdown signal is received.

    Sets up TLS via ``config.cert_path`` / ``config.key_path``, creates a
    :class:`~mavlink_relay_server.protocol.RelayProtocol` factory bound to a
    shared :class:`~mavlink_relay_server.registry.SessionRegistry`, and listens
    on ``config.host:config.port``.

    Shutdown is triggered by SIGINT or SIGTERM; the server closes cleanly with
    no traceback.

    Args:
        config: Runtime configuration object.  Must expose ``.host``, ``.port``,
                ``.cert_path``, ``.key_path``, and ``.auth_timeout_s``.
    """
    quic_config = QuicConfiguration(
        is_client=False,
        alpn_protocols=["mavlink-quic-v1"],
        max_data=10_485_760,  # 10 MB connection-wide flow control
        max_stream_data=1_048_576,  # 1 MB per-stream flow control
    )
    quic_config.load_cert_chain(config.cert_path, config.key_path)

    # Deferred imports to avoid circular dependency at module level.
    from mavlink_relay_server.registry import SessionRegistry  # noqa: PLC0415
    from mavlink_relay_server.protocol import RelayProtocol  # noqa: PLC0415
    from mavlink_relay_server.config import TokenStore  # noqa: PLC0415

    registry = SessionRegistry()
    token_store = TokenStore(config.tokens)

    def create_protocol(*args: object, **kwargs: object) -> RelayProtocol:
        """Factory that injects shared registry, config, and token store into each connection."""
        return RelayProtocol(
            *args,
            registry=registry,
            server_config=config,
            token_store=token_store,
            **kwargs,
        )

    server = await serve(
        host=config.host,
        port=config.port,
        configuration=quic_config,
        create_protocol=create_protocol,
    )
    logger.info("Listening on %s:%d", config.host, config.port)

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _stop() -> None:
        """Signal handler: request a clean shutdown."""
        logger.info("Shutdown signal received")
        stop_event.set()

    loop.add_signal_handler(signal.SIGINT, _stop)
    loop.add_signal_handler(signal.SIGTERM, _stop)

    await stop_event.wait()
    server.close()
    logger.info("Server stopped")
