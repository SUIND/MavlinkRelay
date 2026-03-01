from __future__ import annotations

# pyright: reportMissingImports=false

import asyncio
import json
from unittest.mock import patch

import pytest

from mavlink_relay_server.stats import StatsCollector


def test_on_connect_increments_total_and_active_vehicle() -> None:
    sc = StatsCollector()
    sc.on_connect("v1", "vehicle")
    summary = sc.get_summary()
    assert summary["total_connections"] == 1
    assert summary["active_vehicle_count"] == 1
    assert summary["active_gcs_count"] == 0


def test_on_connect_increments_total_and_active_gcs() -> None:
    sc = StatsCollector()
    sc.on_connect("g1", "gcs")
    summary = sc.get_summary()
    assert summary["total_connections"] == 1
    assert summary["active_gcs_count"] == 1
    assert summary["active_vehicle_count"] == 0


def test_on_disconnect_decrements_active_count() -> None:
    sc = StatsCollector()
    sc.on_connect("v1", "vehicle")
    assert sc.get_summary()["active_vehicle_count"] == 1
    sc.on_disconnect("v1")
    assert sc.get_summary()["active_vehicle_count"] == 0


def test_on_disconnect_unknown_session_does_not_crash() -> None:
    sc = StatsCollector()
    sc.on_disconnect("nonexistent")


def test_on_frame_relayed_increments_counters() -> None:
    sc = StatsCollector()
    sc.on_connect("v1", "vehicle")
    sc.on_frame_relayed("v1", 256)
    summary = sc.get_summary()
    assert summary["total_frames_relayed"] == 1
    assert summary["total_bytes_relayed"] == 256


def test_on_frame_relayed_unknown_session_does_not_crash() -> None:
    sc = StatsCollector()
    sc.on_frame_relayed("nonexistent", 100)


def test_on_bulk_drop_increments_counter() -> None:
    sc = StatsCollector()
    sc.on_connect("v1", "vehicle")
    sc.on_bulk_drop("v1")
    assert sc.get_summary()["total_bulk_drops"] == 1


def test_on_ping_latency_stores_value() -> None:
    sc = StatsCollector()
    sc.on_connect("v1", "vehicle")
    sc.on_ping_latency("v1", 42.5)
    assert sc._connections["v1"].ping_latency_ms == 42.5


def test_get_summary_contains_required_keys() -> None:
    sc = StatsCollector()
    summary = sc.get_summary()
    required_keys = {
        "uptime_s",
        "total_connections",
        "active_vehicle_count",
        "active_gcs_count",
        "total_frames_relayed",
        "total_bytes_relayed",
        "total_bulk_drops",
        "timestamp",
    }
    assert required_keys.issubset(summary.keys())


def test_log_stats_json_format() -> None:
    sc = StatsCollector(log_format="json")
    with patch("mavlink_relay_server.stats.logger") as mock_logger:
        sc._log_stats()
    assert mock_logger.info.called
    logged_msg = mock_logger.info.call_args.args[1]
    parsed = json.loads(logged_msg)
    assert "uptime_s" in parsed
    assert "total_connections" in parsed


def test_log_stats_text_format() -> None:
    sc = StatsCollector(log_format="text")
    with patch("mavlink_relay_server.stats.logger") as mock_logger:
        sc._log_stats()
    assert mock_logger.info.called
    logged_msg = mock_logger.info.call_args.args[0]
    assert "uptime=" in logged_msg


async def test_start_periodic_logging_can_be_cancelled() -> None:
    sc = StatsCollector(interval_s=0.01)
    task = asyncio.ensure_future(sc.start_periodic_logging())
    await asyncio.sleep(0.05)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
