# Task Completion Checklist — MavlinkRelay Server

When completing any code change to `server/mavlink_relay_server/` or `server/tests/`:

## 1. Run the full test suite
```bash
cd server && .venv/bin/pytest tests/ -v
```
All 77 tests must pass. If a new feature was added, new tests should accompany it.

## 2. Validate config (optional but useful for config changes)
```bash
cd server && mavlink-relay-server --config config.example.yaml --dry-run
```

## 3. Type checking (for non-trivial changes)
```bash
cd server && mypy mavlink_relay_server/
```

## 4. Style checks
- Ensure `from __future__ import annotations` is at top of any new module
- Ensure all public functions/methods have Google-style docstrings
- Ensure new constants follow `_UPPER_SNAKE_CASE` naming
- Ensure new module-level logger is `logger = logging.getLogger(__name__)`

## 5. Security review (for any auth / framing / control changes)
- No sensitive data in log messages or AUTH_FAIL reason strings
- Any new buffer accumulation has a size limit
- Any new CBOR deserialization is size-checked before calling `cbor2.loads()`
- Token comparison uses `hmac.compare_digest`, not `==`

## 6. Docker (for infrastructure changes)
```bash
cd server && docker compose build
# or for integration tests:
docker compose -f docker-compose.test.yml up --exit-code-from test-client
```
