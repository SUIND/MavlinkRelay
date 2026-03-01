"""Configuration management for MAVLink QUIC relay."""

from __future__ import annotations

import base64
import hmac
import logging
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)


@dataclass
class TokenConfig:
    """A single auth token entry from configuration."""

    token_b64: str  # base64-encoded 16-byte token
    role: str  # "vehicle" or "gcs"
    vehicle_id: str | None  # required when role == "vehicle", format: "BB_000001"
    gcs_id: str | None  # required when role == "gcs"


@dataclass
class ServerConfig:
    """Full server configuration loaded from YAML + CLI overrides."""

    host: str = "0.0.0.0"
    port: int = 14550
    cert_path: str = ""
    key_path: str = ""
    bulk_queue_max: int = 100
    priority_queue_max: int = 500
    keepalive_interval_s: float = 15.0
    keepalive_timeout_s: float = 45.0
    auth_timeout_s: float = 10.0
    log_level: str = "INFO"
    log_format: str = "json"
    tokens: list[TokenConfig] = field(default_factory=list)


class TokenStore:
    """Lookup table for validating auth tokens."""

    def __init__(self, tokens: list[TokenConfig]) -> None:
        """Initialize token store from list of TokenConfig entries.

        Args:
            tokens: List of TokenConfig instances.
        """
        self._lookup: dict[bytes, TokenConfig] = {}
        for tc in tokens:
            token_bytes = base64.b64decode(tc.token_b64)
            self._lookup[token_bytes] = tc

    def validate(self, token_bytes: bytes) -> TokenConfig | None:
        """Return TokenConfig if token is valid, None otherwise.

        Args:
            token_bytes: Raw bytes of the token to validate.

        Returns:
            TokenConfig if found, None otherwise.
        """
        for stored_token, config in self._lookup.items():
            if hmac.compare_digest(stored_token, token_bytes):
                return config
        return None


def load_config(path: str, cli_overrides: dict[str, Any]) -> ServerConfig:
    """Load ServerConfig from YAML file with optional CLI overrides.

    Args:
        path: Path to the YAML config file.
        cli_overrides: Dict of CLI argument overrides.
            Keys: "host", "port", "cert", "key", "log_level".

    Returns:
        Validated ServerConfig instance.

    Raises:
        FileNotFoundError: If config file does not exist.
        ValueError: If required fields are missing or invalid.
    """
    # Load YAML
    config_path = Path(path)
    if not config_path.exists():
        raise FileNotFoundError(f"Config file not found: {path}")

    with open(config_path) as f:
        yaml_data = yaml.safe_load(f)

    if yaml_data is None:
        yaml_data = {}

    # Extract nested config with defaults
    server_section = yaml_data.get("server", {})
    host = server_section.get("host", "0.0.0.0")
    port = server_section.get("port", 14550)

    tls_section = yaml_data.get("tls", {})
    cert_path = tls_section.get("cert", "")
    key_path = tls_section.get("key", "")

    relay_section = yaml_data.get("relay", {})
    bulk_queue_max = relay_section.get("bulk_queue_max", 100)
    priority_queue_max = relay_section.get("priority_queue_max", 500)

    keepalive_section = yaml_data.get("keepalive", {})
    keepalive_interval_s = keepalive_section.get("interval_s", 15.0)
    keepalive_timeout_s = keepalive_section.get("timeout_s", 45.0)

    log_level = yaml_data.get("log_level", "INFO")
    log_format = yaml_data.get("log_format", "json")

    # Apply CLI overrides
    if "host" in cli_overrides and cli_overrides["host"] is not None:
        host = cli_overrides["host"]
    if "port" in cli_overrides:
        port = cli_overrides["port"]
    if "cert" in cli_overrides:
        cert_path = cli_overrides["cert"]
    if "key" in cli_overrides:
        key_path = cli_overrides["key"]
    if "log_level" in cli_overrides:
        log_level = cli_overrides["log_level"]

    # Validate cert and key paths are non-empty
    if not cert_path:
        raise ValueError("cert_path must not be empty")
    if not key_path:
        raise ValueError("key_path must not be empty")

    # Parse and validate tokens
    tokens: list[TokenConfig] = []
    auth_section = yaml_data.get("auth", {})
    token_list = auth_section.get("tokens", [])

    for idx, token_entry in enumerate(token_list):
        if not isinstance(token_entry, dict):
            raise ValueError(f"Token entry {idx} is not a dict")

        # Map YAML key "token" to "token_b64"
        token_b64 = token_entry.get("token")
        if not token_b64:
            raise ValueError(f"Token entry {idx} missing 'token' field")

        role = token_entry.get("role")
        if not role:
            raise ValueError(f"Token entry {idx} missing 'role' field")

        vehicle_id = token_entry.get("vehicle_id")
        gcs_id = token_entry.get("gcs_id")

        # Validate role-specific fields
        if role == "vehicle":
            if vehicle_id is None:
                raise ValueError(
                    f"Token entry {idx} with role='vehicle' must have 'vehicle_id'"
                )
        elif role == "gcs":
            if gcs_id is None:
                raise ValueError(
                    f"Token entry {idx} with role='gcs' must have 'gcs_id'"
                )
        else:
            raise ValueError(f"Token entry {idx} has invalid role '{role}'")

        tokens.append(
            TokenConfig(
                token_b64=token_b64,
                role=role,
                vehicle_id=vehicle_id,
                gcs_id=gcs_id,
            )
        )

    # Create and return ServerConfig
    return ServerConfig(
        host=host,
        port=port,
        cert_path=cert_path,
        key_path=key_path,
        bulk_queue_max=bulk_queue_max,
        priority_queue_max=priority_queue_max,
        keepalive_interval_s=keepalive_interval_s,
        keepalive_timeout_s=keepalive_timeout_s,
        log_level=log_level,
        log_format=log_format,
        tokens=tokens,
    )
