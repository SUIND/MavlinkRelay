#!/usr/bin/env python3
"""MAVLink Relay Server — database management CLI.

Usage
-----
Initialize a new database::

    python manage.py init-db relay.db

Add a matched vehicle / GCS pair (auto-generates tokens)::

    python manage.py add-pair relay.db --number 000001
    # Creates BB_000001  and  GCS_000001, prints both tokens.

Add a pair with an explicit number offset (GCS_000002 → BB_000001)::

    python manage.py add-pair relay.db --vehicle BB_000001 --gcs GCS_000002

Show all tokens::

    python manage.py list relay.db

Set a server_config key (e.g. cert path)::

    python manage.py set-config relay.db cert_path /etc/certs/server.pem
"""

from __future__ import annotations

import argparse
import base64
import os
import secrets
import sqlite3
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_SCHEMA_FILE = Path(__file__).parent / "schema.sql"


def _connect(db_path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def _generate_token_b64() -> str:
    """Return a URL-safe base64-encoded 16-byte random token."""
    return base64.b64encode(secrets.token_bytes(16)).decode("ascii")


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_init_db(args: argparse.Namespace) -> None:
    """Create schema in a new (or existing) database."""
    db_path = args.db
    schema = _SCHEMA_FILE.read_text()
    conn = _connect(db_path)
    conn.executescript(schema)
    conn.commit()
    conn.close()
    print(f"Database initialised: {db_path}")


def cmd_add_pair(args: argparse.Namespace) -> None:
    """Insert a matched vehicle + GCS token pair.

    Identity format:
        vehicle  → BB_######
        gcs      → GCS_######

    If --number is given, both are derived from it.
    Otherwise --vehicle and --gcs must both be supplied.
    """
    db_path = args.db

    if args.number:
        num = args.number.zfill(6)
        vehicle_id = f"BB_{num}"
        gcs_id = f"GCS_{num}"
    elif args.vehicle and args.gcs:
        vehicle_id = args.vehicle
        gcs_id = args.gcs
    else:
        sys.exit(
            "error: supply either --number N or both --vehicle BB_###### --gcs GCS_######"
        )

    vehicle_token = _generate_token_b64()
    gcs_token = _generate_token_b64()

    conn = _connect(db_path)
    try:
        conn.execute(
            "INSERT INTO tokens (token_b64, role, identity, allowed_vehicle_id) VALUES (?, 'vehicle', ?, NULL)",
            (vehicle_token, vehicle_id),
        )
        conn.execute(
            "INSERT INTO tokens (token_b64, role, identity, allowed_vehicle_id) VALUES (?, 'gcs', ?, ?)",
            (gcs_token, gcs_id, vehicle_id),
        )
        conn.commit()
    except sqlite3.IntegrityError as exc:
        conn.rollback()
        conn.close()
        sys.exit(f"error: {exc}")
    conn.close()

    print(f"Added vehicle {vehicle_id}")
    print(f"  token: {vehicle_token}")
    print()
    print(f"Added GCS {gcs_id}  (authorized for {vehicle_id})")
    print(f"  token: {gcs_token}")


def cmd_list(args: argparse.Namespace) -> None:
    """Print all token rows."""
    conn = _connect(args.db)
    rows = conn.execute(
        "SELECT id, role, identity, allowed_vehicle_id, token_b64 FROM tokens ORDER BY id"
    ).fetchall()
    conn.close()

    if not rows:
        print("(no tokens)")
        return

    header = f"{'ID':>4}  {'ROLE':8}  {'IDENTITY':20}  {'ALLOWED_VEHICLE':20}  TOKEN"
    print(header)
    print("-" * len(header))
    for row_id, role, identity, allowed, token in rows:
        allowed_str = allowed or "-"
        print(f"{row_id:>4}  {role:8}  {identity:20}  {allowed_str:20}  {token}")


def cmd_set_config(args: argparse.Namespace) -> None:
    """Upsert a server_config key."""
    conn = _connect(args.db)
    conn.execute(
        "INSERT INTO server_config (key, value) VALUES (?, ?)"
        " ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (args.key, args.value),
    )
    conn.commit()
    conn.close()
    print(f"Set {args.key} = {args.value}")


# ---------------------------------------------------------------------------
# CLI parser
# ---------------------------------------------------------------------------


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="manage.py",
        description="MAVLink Relay Server — database management",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # init-db
    p_init = sub.add_parser("init-db", help="Create schema in a new database")
    p_init.add_argument("db", help="Path to the SQLite database file")
    p_init.set_defaults(func=cmd_init_db)

    # add-pair
    p_pair = sub.add_parser(
        "add-pair", help="Add a matched vehicle + GCS token pair"
    )
    p_pair.add_argument("db", help="Path to the SQLite database file")
    p_pair.add_argument(
        "--number",
        metavar="N",
        help="6-digit number shared by both IDs (e.g. 1 → BB_000001 / GCS_000001)",
    )
    p_pair.add_argument("--vehicle", metavar="BB_######", help="Explicit vehicle_id")
    p_pair.add_argument("--gcs", metavar="GCS_######", help="Explicit gcs_id")
    p_pair.set_defaults(func=cmd_add_pair)

    # list
    p_list = sub.add_parser("list", help="Show all tokens")
    p_list.add_argument("db", help="Path to the SQLite database file")
    p_list.set_defaults(func=cmd_list)

    # set-config
    p_cfg = sub.add_parser("set-config", help="Set a server_config key")
    p_cfg.add_argument("db", help="Path to the SQLite database file")
    p_cfg.add_argument("key", help="Config key (e.g. cert_path)")
    p_cfg.add_argument("value", help="Value to set")
    p_cfg.set_defaults(func=cmd_set_config)

    return parser


def main() -> None:
    parser = _build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
