"""Main entry point for MAVLink QUIC Relay Server."""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys


def main() -> None:
    """Parse CLI arguments and launch the async relay server.

    Handles :exc:`KeyboardInterrupt` (CTRL-C) silently so that the process
    exits cleanly when the user interrupts before the event loop installs its
    own signal handlers.
    """
    parser = argparse.ArgumentParser(
        prog="mavlink-relay-server", description="MAVLink QUIC Relay Server"
    )
    parser.add_argument(
        "--db",
        required=True,
        metavar="PATH",
        help="Path to the SQLite relay database (created by manage.py init-db)",
    )
    parser.add_argument(
        "--cert",
        metavar="PATH",
        help="Path to TLS certificate (overrides DB server_config.cert_path)",
    )
    parser.add_argument(
        "--key",
        metavar="PATH",
        help="Path to TLS private key (overrides DB server_config.key_path)",
    )
    parser.add_argument(
        "--host",
        default=None,
        help="Server host (overrides DB server_config.host)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=None,
        help="Server port (overrides DB server_config.port)",
    )
    parser.add_argument(
        "--auth-timeout",
        type=float,
        default=None,
        metavar="SECONDS",
        help="Auth timeout in seconds (overrides DB server_config.auth_timeout_s)",
    )
    parser.add_argument(
        "--log-level",
        default=None,
        help="Logging level (overrides DB server_config.log_level)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Load config and token store, print summary, then exit",
    )

    args = parser.parse_args()

    # Build CLI overrides dict — only include keys the user actually specified.
    cli_overrides: dict[str, object] = {}
    if args.host is not None:
        cli_overrides["host"] = args.host
    if args.port is not None:
        cli_overrides["port"] = args.port
    if args.cert:
        cli_overrides["cert"] = args.cert
    if args.key:
        cli_overrides["key"] = args.key
    if args.log_level:
        cli_overrides["log_level"] = args.log_level
    if args.auth_timeout is not None:
        cli_overrides["auth_timeout"] = args.auth_timeout

    async def _run() -> None:
        from mavlink_relay_server.backends import TursoBackend  # noqa: PLC0415
        from mavlink_relay_server.config import load_config  # noqa: PLC0415
        from mavlink_relay_server.server import run_server  # noqa: PLC0415

        backend = TursoBackend(args.db)

        try:
            config, db_store = await load_config(backend, cli_overrides)
        except FileNotFoundError as exc:
            sys.exit(f"error: database not found — {exc}")
        except ValueError as exc:
            sys.exit(f"error: invalid configuration — {exc}")

        # Configure logging (use level from config, which already merged overrides).
        logging.basicConfig(
            level=getattr(logging, config.log_level.upper(), logging.INFO),
            format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        )
        logger = logging.getLogger(__name__)
        logger.info("Starting MAVLink QUIC Relay Server…")

        if args.dry_run:
            token_count = len(db_store._lookup)
            print(
                f"Config OK: host={config.host} port={config.port} tokens={token_count}"
            )
            return

        await run_server(config, backend)

    try:
        asyncio.run(_run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
