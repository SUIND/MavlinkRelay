from __future__ import annotations

import hmac
import logging
from dataclasses import dataclass
from typing import Any, Protocol, runtime_checkable

logger = logging.getLogger(__name__)


@dataclass
class TokenConfig:
    token_b64: str
    role: str
    identity: str
    allowed_vehicle_id: str | None


@dataclass
class ServerConfig:
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


@dataclass
class ConfigRows:
    server_config: list[tuple[str, str]]
    tokens: list[tuple[str, str, str, str | None]]


@runtime_checkable
class ConfigBackend(Protocol):
    async def fetch(self) -> ConfigRows: ...


class DatabaseStore:
    def __init__(self, tokens: list[TokenConfig]) -> None:
        import base64 as _b64

        self._lookup: dict[bytes, TokenConfig] = {}
        for tc in tokens:
            token_bytes = _b64.b64decode(tc.token_b64)
            self._lookup[token_bytes] = tc

    def validate(self, token_bytes: bytes) -> TokenConfig | None:
        result: TokenConfig | None = None
        for stored, config in self._lookup.items():
            if hmac.compare_digest(stored, token_bytes):
                result = config
        return result


async def load_tokens(backend: ConfigBackend) -> DatabaseStore:
    rows = await backend.fetch()
    tokens: list[TokenConfig] = [
        TokenConfig(
            token_b64=token_b64,
            role=role,
            identity=identity,
            allowed_vehicle_id=allowed_vehicle_id,
        )
        for token_b64, role, identity, allowed_vehicle_id in rows.tokens
    ]
    logger.debug("Reloaded %d token(s) from backend", len(tokens))
    return DatabaseStore(tokens)


async def load_config(
    backend: ConfigBackend,
    cli_overrides: dict[str, Any] | None = None,
) -> tuple[ServerConfig, DatabaseStore]:
    if cli_overrides is None:
        cli_overrides = {}

    rows = await backend.fetch()

    cfg_map: dict[str, str] = {k: v for k, v in rows.server_config}

    def _get(key: str, default: str) -> str:
        return cfg_map.get(key, default)

    host = _get("host", "0.0.0.0")
    port = int(_get("port", "14550"))
    cert_path = _get("cert_path", "")
    key_path = _get("key_path", "")
    bulk_queue_max = int(_get("bulk_queue_max", "100"))
    priority_queue_max = int(_get("priority_queue_max", "500"))
    keepalive_interval_s = float(_get("keepalive_interval_s", "15.0"))
    keepalive_timeout_s = float(_get("keepalive_timeout_s", "45.0"))
    auth_timeout_s = float(_get("auth_timeout_s", "10.0"))
    log_level = _get("log_level", "INFO")
    log_format = _get("log_format", "json")

    if cli_overrides.get("host") is not None:
        host = cli_overrides["host"]
    if cli_overrides.get("port") is not None:
        port = int(cli_overrides["port"])
    if cli_overrides.get("cert"):
        cert_path = cli_overrides["cert"]
    if cli_overrides.get("key"):
        key_path = cli_overrides["key"]
    if cli_overrides.get("log_level"):
        log_level = cli_overrides["log_level"]
    if cli_overrides.get("auth_timeout") is not None:
        auth_timeout_s = float(cli_overrides["auth_timeout"])

    if not cert_path:
        raise ValueError("cert_path must not be empty (set via DB or --cert)")
    if not key_path:
        raise ValueError("key_path must not be empty (set via DB or --key)")

    config = ServerConfig(
        host=host,
        port=port,
        cert_path=cert_path,
        key_path=key_path,
        bulk_queue_max=bulk_queue_max,
        priority_queue_max=priority_queue_max,
        keepalive_interval_s=keepalive_interval_s,
        keepalive_timeout_s=keepalive_timeout_s,
        auth_timeout_s=auth_timeout_s,
        log_level=log_level,
        log_format=log_format,
    )

    tokens: list[TokenConfig] = [
        TokenConfig(
            token_b64=token_b64,
            role=role,
            identity=identity,
            allowed_vehicle_id=allowed_vehicle_id,
        )
        for token_b64, role, identity, allowed_vehicle_id in rows.tokens
    ]

    logger.info("Loaded %d token(s) from backend", len(tokens))
    store = DatabaseStore(tokens)

    return config, store
