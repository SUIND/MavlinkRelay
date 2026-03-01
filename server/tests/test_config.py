from __future__ import annotations

# pyright: reportMissingImports=false

from pathlib import Path

import pytest

from mavlink_relay_server.config import ServerConfig, TokenStore, load_config


def test_load_config_parses_all_fields(
    tmp_path: Path, tls_paths: tuple[str, str]
) -> None:
    cert_path, key_path = tls_paths
    cfg_path = tmp_path / "config.yaml"
    cfg_path.write_text(
        "server:\n"
        '  host: "0.0.0.0"\n'
        "  port: 14550\n"
        "tls:\n"
        f"  cert: '{cert_path}'\n"
        f"  key: '{key_path}'\n"
        "relay:\n"
        "  bulk_queue_max: 100\n"
        "  priority_queue_max: 500\n"
        "keepalive:\n"
        "  interval_s: 15.0\n"
        "  timeout_s: 45.0\n"
        "log_level: INFO\n"
        "log_format: json\n"
        "auth:\n"
        "  tokens:\n"
        "    - token: 'AAAAAAAAAAAAAAAAAAAAAA=='\n"
        "      role: vehicle\n"
        "      vehicle_id: 1\n"
        "    - token: 'u7u7u7u7u7u7u7u7u7u7uw=='\n"
        "      role: gcs\n"
        "      gcs_id: gcs-alpha\n"
    )

    cfg = load_config(str(cfg_path), cli_overrides={})
    assert isinstance(cfg, ServerConfig)
    assert cfg.host == "0.0.0.0"
    assert cfg.port == 14550
    assert cfg.cert_path == cert_path
    assert cfg.key_path == key_path
    assert cfg.bulk_queue_max == 100
    assert cfg.priority_queue_max == 500
    assert cfg.keepalive_interval_s == 15.0
    assert cfg.keepalive_timeout_s == 45.0
    assert cfg.log_level == "INFO"
    assert cfg.log_format == "json"
    assert len(cfg.tokens) == 2
    assert cfg.tokens[0].role == "vehicle"
    assert cfg.tokens[0].vehicle_id == 1
    assert cfg.tokens[1].role == "gcs"
    assert cfg.tokens[1].gcs_id == "gcs-alpha"


def test_load_config_applies_cli_overrides_for_host_and_port(
    tmp_path: Path,
    tls_paths: tuple[str, str],
) -> None:
    cert_path, key_path = tls_paths
    cfg_path = tmp_path / "config.yaml"
    cfg_path.write_text(
        "server:\n"
        "  host: 0.0.0.0\n"
        "  port: 14550\n"
        "tls:\n"
        f"  cert: '{cert_path}'\n"
        f"  key: '{key_path}'\n"
    )
    cfg = load_config(
        str(cfg_path),
        cli_overrides={"host": "127.0.0.1", "port": 9999},
    )
    assert cfg.host == "127.0.0.1"
    assert cfg.port == 9999


def test_load_config_missing_file_raises(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        load_config(str(tmp_path / "missing.yaml"), cli_overrides={})


def test_load_config_raises_value_error_if_token_missing_role(
    tmp_path: Path,
    tls_paths: tuple[str, str],
) -> None:
    cert_path, key_path = tls_paths
    cfg_path = tmp_path / "config.yaml"
    cfg_path.write_text(
        "tls:\n"
        f"  cert: '{cert_path}'\n"
        f"  key: '{key_path}'\n"
        "auth:\n"
        "  tokens:\n"
        "    - token: 'AAAAAAAAAAAAAAAAAAAAAA=='\n"
        "      vehicle_id: 1\n"
    )
    with pytest.raises(ValueError, match="missing 'role' field"):
        load_config(str(cfg_path), cli_overrides={})


def test_token_store_validate_returns_config_for_known_token(
    token_store: TokenStore,
    vehicle_token_bytes: bytes,
) -> None:
    tc = token_store.validate(vehicle_token_bytes)
    assert tc is not None
    assert tc.role == "vehicle"
    assert tc.vehicle_id == "BB_000001"


def test_token_store_validate_returns_none_for_unknown_token(
    token_store: TokenStore,
) -> None:
    assert token_store.validate(b"not-a-token") is None
