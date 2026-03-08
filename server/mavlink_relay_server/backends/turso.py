from __future__ import annotations

import sqlite3

from mavlink_relay_server.config import ConfigRows


class TursoBackend:
    def __init__(self, db_path: str) -> None:
        self._db_path = db_path

    async def fetch(self) -> ConfigRows:
        uri = f"file:{self._db_path}?mode=ro"
        conn = sqlite3.connect(uri, uri=True)
        try:
            server_config: list[tuple[str, str]] = conn.execute(
                "SELECT key, value FROM server_config"
            ).fetchall()
            tokens: list[tuple[str, str, str, str | None]] = conn.execute(
                "SELECT token_b64, role, identity, allowed_vehicle_id FROM tokens"
            ).fetchall()
        finally:
            conn.close()

        return ConfigRows(server_config=server_config, tokens=tokens)
