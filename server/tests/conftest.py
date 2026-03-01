from __future__ import annotations

# pyright: reportMissingImports=false

import base64
from pathlib import Path

import pytest

from mavlink_relay_server.config import ServerConfig, TokenConfig, TokenStore
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
def example_config_file(
    tmp_path: Path,
    tls_paths: tuple[str, str],
    vehicle_token_bytes: bytes,
    gcs_token_bytes: bytes,
) -> str:
    cert_path, key_path = tls_paths

    vehicle_b64 = base64.b64encode(vehicle_token_bytes).decode("ascii")
    gcs_b64 = base64.b64encode(gcs_token_bytes).decode("ascii")

    config_text = (
        "server:\n"
        '  host: "0.0.0.0"\n'
        "  port: 14550\n"
        "tls:\n"
        f'  cert: "{cert_path}"\n'
        f'  key: "{key_path}"\n'
        "relay:\n"
        "  bulk_queue_max: 100\n"
        "keepalive:\n"
        "  interval_s: 15.0\n"
        "  timeout_s: 45.0\n"
        "auth:\n"
        "  tokens:\n"
        f'    - token: "{vehicle_b64}"\n'
        "      role: vehicle\n"
        '      vehicle_id: "BB_000001"\n'
        f'    - token: "{gcs_b64}"\n'
        "      role: gcs\n"
        '      gcs_id: "gcs-alpha"\n'
    )

    p = tmp_path / "config.example.yaml"
    p.write_text(config_text)
    return str(p)


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
def token_store(vehicle_token_bytes: bytes, gcs_token_bytes: bytes) -> TokenStore:
    vehicle_b64 = base64.b64encode(vehicle_token_bytes).decode("ascii")
    gcs_b64 = base64.b64encode(gcs_token_bytes).decode("ascii")

    tokens = [
        TokenConfig(
            token_b64=vehicle_b64,
            role="vehicle",
            vehicle_id="BB_000001",
            gcs_id=None,
        ),
        TokenConfig(
            token_b64=gcs_b64,
            role="gcs",
            vehicle_id=None,
            gcs_id="gcs-alpha",
        ),
    ]
    return TokenStore(tokens)


@pytest.fixture
def registry() -> SessionRegistry:
    return SessionRegistry()
