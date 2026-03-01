# Test Suite Reference — MavlinkRelay Server

## Summary
- **77 tests total** across 8 unit test files + integration tests
- All 77 unit tests pass as of the last session
- Run with: `cd server && .venv/bin/pytest tests/ -v`

## Test files and counts
| File | Tests | What it covers |
|------|-------|----------------|
| `tests/test_framing.py` | 8 | `encode_frame`, `FrameDecoder` basic cases |
| `tests/test_framing_extended.py` | 8 | Fragmentation, oversized frames, buffer overflow limits |
| `tests/test_registry.py` | 11 | Session registration, routing, vehicle/GCS lifecycle |
| `tests/test_config.py` | 6 | YAML loading, token decode, validation errors |
| `tests/test_control.py` | 10 | AUTH, AUTH_OK, AUTH_FAIL, PING/PONG encode/decode |
| `tests/test_security.py` | 12 | Re-auth guard, constant-time compare, payload size limits |
| `tests/test_protocol_logic.py` | 10 | Protocol state machine, auth timeout, keepalive logic |
| `tests/test_stats.py` | 12 | StatsCollector, ConnectionStats, ServerStats |

## Shared fixtures (conftest.py)
- `vehicle_token_bytes` → `b"\x00" * 16`
- `gcs_token_bytes` → `b"\xbb" * 16`
- `tls_paths` → `(str(cert), str(key))` in `tmp_path` with dummy file contents
- `token_store` → `TokenStore` with both vehicle + gcs tokens loaded
- `registry` → fresh empty `SessionRegistry`
- `server_config` → `ServerConfig(host="127.0.0.1", port=14550, ...)`
- `example_config_file` → path to generated YAML file in `tmp_path`

## Integration tests
- Location: `tests/integration/`
- Uses real aioquic clients: `VehicleClient` and `GCSClient` in `test_client.py`
- Requires a running server (run via `docker-compose.test.yml`)
- Config: `tests/integration/config.test.yaml`
- Separate Dockerfile: `tests/integration/Dockerfile.test`
- Run: `docker compose -f docker-compose.test.yml up --exit-code-from test-client`

## pytest configuration
In `pyproject.toml`:
```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
```
No need for `@pytest.mark.asyncio` on async test functions.

## Running specific tests
```bash
# All tests
pytest tests/ -v

# Single file
pytest tests/test_security.py -v

# Single test
pytest tests/test_security.py::test_reauth_guard -v

# Skip integration
pytest tests/ -v --ignore=tests/integration

# With venv pytest
.venv/bin/pytest tests/ -v
```
