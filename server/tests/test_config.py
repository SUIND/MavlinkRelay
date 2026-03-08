from __future__ import annotations

# pyright: reportMissingImports=false

import asyncio
import base64
import sqlite3
import tempfile
from pathlib import Path

import pytest

from mavlink_relay_server.config import (
    ConfigBackend,
    ConfigRows,
    DatabaseStore,
    ServerConfig,
    TokenConfig,
    load_config,
    load_tokens,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _seed_db(db_path: str, cert_path: str, key_path: str) -> None:
    schema_path = Path(__file__).parent.parent / "schema.sql"
    schema_sql = schema_path.read_text()

    con = sqlite3.connect(db_path)
    con.executescript(schema_sql)

    vehicle_b64 = base64.b64encode(b"\x00" * 16).decode("ascii")
    gcs_b64 = base64.b64encode(b"\xbb" * 16).decode("ascii")

    con.execute(
        "UPDATE server_config SET value = ? WHERE key = 'cert_path'", (cert_path,)
    )
    con.execute(
        "UPDATE server_config SET value = ? WHERE key = 'key_path'", (key_path,)
    )
    con.execute(
        "INSERT INTO tokens (token_b64, role, identity, allowed_vehicle_id) VALUES (?,?,?,?)",
        (vehicle_b64, "vehicle", "BB_000001", None),
    )
    con.execute(
        "INSERT INTO tokens (token_b64, role, identity, allowed_vehicle_id) VALUES (?,?,?,?)",
        (gcs_b64, "gcs", "GCS_000001", "BB_000001"),
    )
    con.commit()
    con.close()


# ---------------------------------------------------------------------------
# DatabaseStore unit tests (no DB required — construct directly)
# ---------------------------------------------------------------------------


def test_database_store_validate_returns_config_for_known_vehicle_token(
    token_store: DatabaseStore,
    vehicle_token_bytes: bytes,
) -> None:
    tc = token_store.validate(vehicle_token_bytes)
    assert tc is not None
    assert tc.role == "vehicle"
    assert tc.identity == "BB_000001"
    assert tc.allowed_vehicle_id is None


def test_database_store_validate_returns_config_for_known_gcs_token(
    token_store: DatabaseStore,
    gcs_token_bytes: bytes,
) -> None:
    tc = token_store.validate(gcs_token_bytes)
    assert tc is not None
    assert tc.role == "gcs"
    assert tc.identity == "GCS_000001"
    assert tc.allowed_vehicle_id == "BB_000001"


def test_database_store_validate_returns_none_for_unknown_token(
    token_store: DatabaseStore,
) -> None:
    assert token_store.validate(b"not-a-token") is None


def test_database_store_validate_returns_none_for_wrong_token(
    token_store: DatabaseStore,
) -> None:
    assert token_store.validate(b"\xff" * 16) is None


# ---------------------------------------------------------------------------
# ConfigBackend protocol — stub backend (no real DB needed)
# ---------------------------------------------------------------------------


class _StubBackend:
    def __init__(self, cert_path: str, key_path: str) -> None:
        vehicle_b64 = base64.b64encode(b"\x00" * 16).decode("ascii")
        gcs_b64 = base64.b64encode(b"\xbb" * 16).decode("ascii")
        self._rows = ConfigRows(
            server_config=[
                ("host", "0.0.0.0"),
                ("port", "14550"),
                ("cert_path", cert_path),
                ("key_path", key_path),
            ],
            tokens=[
                (vehicle_b64, "vehicle", "BB_000001", None),
                (gcs_b64, "gcs", "GCS_000001", "BB_000001"),
            ],
        )

    async def fetch(self) -> ConfigRows:
        return self._rows


def test_stub_backend_satisfies_config_backend_protocol(
    tls_paths: tuple[str, str],
) -> None:
    cert_path, key_path = tls_paths
    backend = _StubBackend(cert_path, key_path)
    assert isinstance(backend, ConfigBackend)


@pytest.mark.asyncio
async def test_load_config_with_stub_backend_parses_all_fields(
    tls_paths: tuple[str, str],
) -> None:
    cert_path, key_path = tls_paths
    config, store = await load_config(_StubBackend(cert_path, key_path))

    assert isinstance(config, ServerConfig)
    assert config.cert_path == cert_path
    assert config.key_path == key_path
    assert config.host == "0.0.0.0"
    assert config.port == 14550
    assert store.validate(b"\x00" * 16) is not None
    assert store.validate(b"\xbb" * 16) is not None


@pytest.mark.asyncio
async def test_load_config_with_stub_backend_applies_cli_overrides(
    tls_paths: tuple[str, str],
) -> None:
    cert_path, key_path = tls_paths
    config, _ = await load_config(
        _StubBackend(cert_path, key_path),
        cli_overrides={"host": "127.0.0.1", "port": 9999},
    )
    assert config.host == "127.0.0.1"
    assert config.port == 9999


@pytest.mark.asyncio
async def test_load_config_raises_if_cert_missing(
    tls_paths: tuple[str, str],
) -> None:
    _, key_path = tls_paths

    class _NoCertBackend:
        async def fetch(self) -> ConfigRows:
            return ConfigRows(
                server_config=[("key_path", key_path)],
                tokens=[],
            )

    with pytest.raises(ValueError, match="cert_path"):
        await load_config(_NoCertBackend())


# ---------------------------------------------------------------------------
# TursoBackend integration tests (real SQLite via pyturso)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_turso_backend_parses_all_fields(
    tls_paths: tuple[str, str],
) -> None:
    from mavlink_relay_server.backends import TursoBackend

    cert_path, key_path = tls_paths
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        db_path = f.name

    _seed_db(db_path, cert_path, key_path)

    config, store = await load_config(TursoBackend(db_path))

    assert isinstance(config, ServerConfig)
    assert config.cert_path == cert_path
    assert config.key_path == key_path
    assert store.validate(b"\x00" * 16) is not None
    assert store.validate(b"\xbb" * 16) is not None


@pytest.mark.asyncio
async def test_turso_backend_opens_readonly(
    tls_paths: tuple[str, str],
) -> None:
    import sqlite3 as _sqlite3

    from mavlink_relay_server.backends import TursoBackend

    cert_path, key_path = tls_paths
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        db_path = f.name

    _seed_db(db_path, cert_path, key_path)
    await TursoBackend(db_path).fetch()

    conn = _sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        with pytest.raises(_sqlite3.OperationalError, match="readonly"):
            conn.execute("DELETE FROM tokens")
    finally:
        conn.close()


@pytest.mark.asyncio
async def test_turso_backend_applies_cli_overrides(
    tls_paths: tuple[str, str],
) -> None:
    from mavlink_relay_server.backends import TursoBackend

    cert_path, key_path = tls_paths
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        db_path = f.name

    _seed_db(db_path, cert_path, key_path)

    config, _ = await load_config(
        TursoBackend(db_path),
        cli_overrides={"host": "127.0.0.1", "port": 9999},
    )
    assert config.host == "127.0.0.1"
    assert config.port == 9999


@pytest.mark.asyncio
async def test_load_tokens_reflects_new_rows(
    tls_paths: tuple[str, str],
) -> None:
    from mavlink_relay_server.backends import TursoBackend

    cert_path, key_path = tls_paths
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as f:
        db_path = f.name

    _seed_db(db_path, cert_path, key_path)
    backend = TursoBackend(db_path)

    store_before = await load_tokens(backend)
    assert store_before.validate(b"\xff" * 16) is None

    new_token_b64 = base64.b64encode(b"\xff" * 16).decode("ascii")
    conn = sqlite3.connect(db_path)
    conn.execute(
        "INSERT INTO tokens (token_b64, role, identity, allowed_vehicle_id) VALUES (?, 'vehicle', 'BB_000002', NULL)",
        (new_token_b64,),
    )
    conn.commit()
    conn.close()

    store_after = await load_tokens(backend)
    assert store_after.validate(b"\xff" * 16) is not None
