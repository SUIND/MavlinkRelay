"""Relay statistics and monitoring."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any

logger = logging.getLogger(__name__)


@dataclass
class ConnectionStats:
    """Statistics for a single connection (vehicle or GCS)."""

    session_id: str
    """Unique identifier for this connection."""

    role: str
    """Connection role: 'vehicle' or 'gcs'."""

    connected_at: float
    """Monotonic timestamp when connection was established."""

    disconnected_at: float | None = None
    """Monotonic timestamp when connection was terminated, or None if active."""

    frames_relayed: int = 0
    """Total number of frames relayed through this connection."""

    bytes_relayed: int = 0
    """Total number of bytes relayed through this connection."""

    bulk_drops: int = 0
    """Total number of bulk drops on this connection."""

    ping_latency_ms: float | None = None
    """Last recorded ping latency in milliseconds, or None if not measured."""


@dataclass
class ServerStats:
    """Aggregated statistics for the relay server."""

    start_time: float = field(default_factory=time.monotonic)
    """Monotonic timestamp when the server started."""

    total_connections: int = 0
    """Total number of connections (cumulative)."""

    active_vehicle_count: int = 0
    """Number of currently active vehicle connections."""

    active_gcs_count: int = 0
    """Number of currently active GCS connections."""

    total_frames_relayed: int = 0
    """Total number of frames relayed by the server."""

    total_bytes_relayed: int = 0
    """Total number of bytes relayed by the server."""

    total_bulk_drops: int = 0
    """Total number of bulk drops across all connections."""


class StatsCollector:
    """Collects and logs statistics for the relay server.

    Tracks connection events, frame/byte relay counts, bulk drops, and ping latencies.
    Periodically logs aggregated statistics in JSON or text format.
    """

    def __init__(self, log_format: str = "json", interval_s: float = 60.0) -> None:
        """Initialize the statistics collector.

        Args:
            log_format: Output format for periodic logs: 'json' (default) or 'text'.
            interval_s: Interval in seconds between periodic log entries (default 60).
        """
        self._log_format = log_format
        self._interval_s = interval_s
        self._connections: dict[str, ConnectionStats] = {}
        self._server_stats = ServerStats()

    def on_connect(self, session_id: str, role: str) -> None:
        """Record a connection event.

        Args:
            session_id: Unique identifier for the session.
            role: Connection role ('vehicle' or 'gcs').
        """
        stats = ConnectionStats(
            session_id=session_id,
            role=role,
            connected_at=time.monotonic(),
        )
        self._connections[session_id] = stats
        self._server_stats.total_connections += 1

        # Update active counts
        if role == "vehicle":
            self._server_stats.active_vehicle_count += 1
        elif role == "gcs":
            self._server_stats.active_gcs_count += 1

        # Log connection event
        event_data = {
            "event": "connect",
            "session_id": session_id,
            "role": role,
            "timestamp": time.time(),
        }
        logger.info("Connection established: %s", json.dumps(event_data))

    def on_disconnect(self, session_id: str) -> None:
        """Record a disconnection event.

        Args:
            session_id: Unique identifier for the session.
        """
        if session_id not in self._connections:
            logger.warning("Disconnect event for unknown session: %s", session_id)
            return

        stats = self._connections[session_id]
        stats.disconnected_at = time.monotonic()

        # Update active counts
        if stats.role == "vehicle":
            self._server_stats.active_vehicle_count -= 1
        elif stats.role == "gcs":
            self._server_stats.active_gcs_count -= 1

        # Calculate connection duration
        duration_s = stats.disconnected_at - stats.connected_at

        # Log disconnection event
        event_data = {
            "event": "disconnect",
            "session_id": session_id,
            "role": stats.role,
            "duration_s": duration_s,
            "frames_relayed": stats.frames_relayed,
            "bytes_relayed": stats.bytes_relayed,
            "bulk_drops": stats.bulk_drops,
            "timestamp": time.time(),
        }
        logger.info("Connection terminated: %s", json.dumps(event_data))

    def on_frame_relayed(self, session_id: str, byte_count: int) -> None:
        """Record a frame relay event.

        Args:
            session_id: Unique identifier for the session.
            byte_count: Number of bytes in the frame.
        """
        if session_id not in self._connections:
            logger.warning("Frame relay for unknown session: %s", session_id)
            return

        stats = self._connections[session_id]
        stats.frames_relayed += 1
        stats.bytes_relayed += byte_count
        self._server_stats.total_frames_relayed += 1
        self._server_stats.total_bytes_relayed += byte_count

    def on_bulk_drop(self, session_id: str) -> None:
        """Record a bulk drop event.

        Args:
            session_id: Unique identifier for the session.
        """
        if session_id not in self._connections:
            logger.warning("Bulk drop for unknown session: %s", session_id)
            return

        stats = self._connections[session_id]
        stats.bulk_drops += 1
        self._server_stats.total_bulk_drops += 1

    def on_ping_latency(self, session_id: str, latency_ms: float) -> None:
        """Record a ping latency measurement.

        Args:
            session_id: Unique identifier for the session.
            latency_ms: Latency in milliseconds.
        """
        if session_id not in self._connections:
            logger.warning("Ping latency for unknown session: %s", session_id)
            return

        stats = self._connections[session_id]
        stats.ping_latency_ms = latency_ms

    def get_summary(self) -> dict[str, Any]:
        """Get current server statistics summary.

        Returns:
            Dictionary with current uptime, connection counts, and aggregated metrics.
        """
        uptime_s = time.monotonic() - self._server_stats.start_time
        return {
            "uptime_s": uptime_s,
            "total_connections": self._server_stats.total_connections,
            "active_vehicle_count": self._server_stats.active_vehicle_count,
            "active_gcs_count": self._server_stats.active_gcs_count,
            "total_frames_relayed": self._server_stats.total_frames_relayed,
            "total_bytes_relayed": self._server_stats.total_bytes_relayed,
            "total_bulk_drops": self._server_stats.total_bulk_drops,
            "timestamp": time.time(),
        }

    async def start_periodic_logging(self) -> None:
        """Start the periodic statistics logging loop.

        Logs statistics every `interval_s` seconds in the configured format.
        This coroutine runs indefinitely until cancelled.
        """
        try:
            while True:
                await asyncio.sleep(self._interval_s)
                self._log_stats()
        except asyncio.CancelledError:
            logger.debug("Periodic logging cancelled")
            raise

    def _log_stats(self) -> None:
        """Log current statistics in configured format (JSON or text)."""
        summary = self.get_summary()

        if self._log_format == "json":
            log_entry = json.dumps(summary)
            logger.info("Server stats: %s", log_entry)
        else:
            # Text format
            log_entry = (
                f"Server stats: uptime={summary['uptime_s']:.1f}s, "
                f"total_connections={summary['total_connections']}, "
                f"active_vehicles={summary['active_vehicle_count']}, "
                f"active_gcs={summary['active_gcs_count']}, "
                f"total_frames={summary['total_frames_relayed']}, "
                f"total_bytes={summary['total_bytes_relayed']}, "
                f"bulk_drops={summary['total_bulk_drops']}"
            )
            logger.info(log_entry)
