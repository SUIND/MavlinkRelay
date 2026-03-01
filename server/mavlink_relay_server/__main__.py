"""Main entry point for MAVLink QUIC Relay Server."""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys

from mavlink_relay_server.config import ServerConfig, load_config


def _build_config(args: argparse.Namespace) -> ServerConfig:
    """Construct a :class:`~mavlink_relay_server.config.ServerConfig` from CLI args.

    Exits with a helpful error if required TLS paths are missing.

    Args:
        args: Parsed :class:`argparse.Namespace` from the CLI parser.

    Returns:
        A :class:`~mavlink_relay_server.config.ServerConfig` populated from CLI flags.
    """
    # If a config file is provided, load from YAML and allow CLI overrides.
    if args.config:
        cli_overrides: dict[str, object] = {"host": args.host, "port": args.port}
        if args.cert:
            cli_overrides["cert"] = args.cert
        if args.key:
            cli_overrides["key"] = args.key
        if args.log_level:
            cli_overrides["log_level"] = args.log_level
        return load_config(args.config, cli_overrides)

    # No config file: cert and key are required via CLI
    if not args.cert:
        sys.exit("error: --cert is required (path to TLS certificate)")
    if not args.key:
        sys.exit("error: --key is required (path to TLS private key)")

    return ServerConfig(
        host=args.host,
        port=args.port,
        cert_path=args.cert,
        key_path=args.key,
        auth_timeout_s=args.auth_timeout,
    )


def main() -> None:
    """Parse CLI arguments and launch the async relay server.

    Handles :exc:`KeyboardInterrupt` (CTRL-C) silently so that the process
    exits cleanly when the user interrupts before the event loop installs its
    own signal handlers.
    """
    parser = argparse.ArgumentParser(
        prog="mavlink-relay-server", description="MAVLink QUIC Relay Server"
    )
    parser.add_argument("--config", help="Path to YAML configuration file")
    parser.add_argument("--cert", help="Path to TLS certificate (required)")
    parser.add_argument("--key", help="Path to TLS private key (required)")
    parser.add_argument(
        "--host", default="0.0.0.0", help="Server host (default: 0.0.0.0)"
    )
    parser.add_argument(
        "--port", type=int, default=14550, help="Server port (default: 14550)"
    )
    parser.add_argument(
        "--auth-timeout",
        type=float,
        default=30.0,
        metavar="SECONDS",
        help="Seconds before unauthenticated connections are closed (default: 30)",
    )
    parser.add_argument(
        "--log-level", default="INFO", help="Logging level (default: INFO)"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Load config, print summary, and exit",
    )

    args = parser.parse_args()

    # Configure logging
    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    )

    logger = logging.getLogger(__name__)
    logger.info("Starting MAVLink QUIC Relay Server...")

    from mavlink_relay_server.server import run_server  # noqa: PLC0415

    config = _build_config(args)

    if args.dry_run:
        print(
            f"Config OK: host={config.host} port={config.port} "
            f"tokens={len(config.tokens)}"
        )
        sys.exit(0)

    try:
        asyncio.run(run_server(config))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
