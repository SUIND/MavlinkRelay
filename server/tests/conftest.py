from __future__ import annotations

# pyright: reportMissingImports=false

import base64
from pathlib import Path

import pytest

from mavlink_relay_server.config import DatabaseStore, ServerConfig, TokenConfig
from mavlink_relay_server.registry import SessionRegistry


@pytest.fixture
def vehicle_token_bytes() -> bytes:
    return b"\x00" * 16


@pytest.fixture
def gcs_token_bytes() -> bytes:
    return b"\xbb" * 16


@pytest.fixture
def tls_paths(tmp_path: Path) -> tuple[str, str]:
    cert = tmp_path / "server.crt"
    key = tmp_path / "server.key"
    cert.write_text("DUMMY CERT\n")
    key.write_text("DUMMY KEY\n")
    return (str(cert), str(key))


@pytest.fixture
def server_config(tls_paths: tuple[str, str]) -> ServerConfig:
    cert_path, key_path = tls_paths
    return ServerConfig(
        host="127.0.0.1",
        port=14550,
        cert_path=cert_path,
        key_path=key_path,
        auth_timeout_s=10.0,
        keepalive_interval_s=15.0,
        keepalive_timeout_s=45.0,
        bulk_queue_max=100,
    )


@pytest.fixture
def vehicle_token_config(vehicle_token_bytes: bytes) -> TokenConfig:
    return TokenConfig(
        token_b64=base64.b64encode(vehicle_token_bytes).decode("ascii"),
        role="vehicle",
        identity="BB_000001",
        allowed_vehicle_id=None,
    )


@pytest.fixture
def gcs_token_config(gcs_token_bytes: bytes) -> TokenConfig:
    return TokenConfig(
        token_b64=base64.b64encode(gcs_token_bytes).decode("ascii"),
        role="gcs",
        identity="GCS_000001",
        allowed_vehicle_id="BB_000001",
    )


@pytest.fixture
def token_store(
    vehicle_token_config: TokenConfig,
    gcs_token_config: TokenConfig,
) -> DatabaseStore:
    return DatabaseStore([vehicle_token_config, gcs_token_config])


@pytest.fixture
def registry() -> SessionRegistry:
    return SessionRegistry()
