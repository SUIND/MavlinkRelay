# Suggested Commands — MavlinkRelay Server

## Working directory
All server commands run from `server/` unless otherwise noted.

## Install
```bash
cd server
pip install -e .          # production deps
pip install -e ".[dev]"   # + pytest, pytest-asyncio, mypy
```

## Run server
```bash
# Via installed entry point (after pip install -e .)
mavlink-relay-server --config config.example.yaml

# Validate config without starting (dry-run)
mavlink-relay-server --config config.example.yaml --dry-run

# All CLI flags:
#   --config <path>       YAML config file
#   --host <addr>         override server.host (default: 0.0.0.0)
#   --port <int>          override server.port (default: 14550)
#   --cert <path>         override tls.cert
#   --key <path>          override tls.key
#   --log-level <level>   DEBUG|INFO|WARNING|ERROR (default: INFO)
#   --auth-timeout <sec>  seconds before unauthed connections closed (default: 30)
#   --dry-run             print config summary and exit

# Via Python module
python -m mavlink_relay_server --config config.example.yaml
```

## Generate TLS certificate (self-signed EC prime256v1)
```bash
cd server/certs && bash generate_certs.sh
```

## Generate a new auth token
```bash
python3 -c "import os, base64; print(base64.b64encode(os.urandom(16)).decode())"
```

## Run tests
```bash
cd server

# Run all 77 unit tests (recommended)
.venv/bin/pytest tests/ -v

# Or if pytest is on PATH
pytest tests/ -v

# Skip integration tests (they require a running server)
pytest tests/ -v --ignore=tests/integration

# Single test file
pytest tests/test_framing.py -v

# Single test by name
pytest tests/test_security.py::test_reauth_guard -v
```

## Docker
```bash
cd server

# Production
docker compose up

# Integration tests (runs test-client against a real server container)
docker compose -f docker-compose.test.yml up --exit-code-from test-client

# Build image only
docker build -t mavlink-relay-server:latest .
```

## Type checking
```bash
cd server
mypy mavlink_relay_server/
```
