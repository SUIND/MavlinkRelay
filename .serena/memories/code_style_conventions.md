# Code Style and Conventions — MavlinkRelay Server

## Language
Python 3.10+ with `from __future__ import annotations` at the top of every module.

## Type hints
- Full type annotations on all public functions and class methods
- `-> None` on functions with no return value
- `-> bool`, `-> dict[str, Any]`, etc. on everything else
- Use `TYPE_CHECKING` guard for imports that would cause circular imports:
  ```python
  from typing import TYPE_CHECKING
  if TYPE_CHECKING:
      from mavlink_relay_server.protocol import RelayProtocol
  ```
- Use `dict[str, Any]` for CBOR message payloads
- Use `bytes` for raw token/frame data
- Use `list[bytes]` for decoded frame lists from FrameDecoder

## Docstrings
- All public classes, methods, and functions have Google-style docstrings
- Format:
  ```python
  def my_func(arg: int) -> str:
      """Short one-line summary.

      Args:
          arg: Description of argument.

      Returns:
          Description of return value.

      Raises:
          ValueError: When and why.
      """
  ```
- Private helpers (`_prefixed`) may have shorter docstrings

## Naming conventions
- Classes: `PascalCase` (e.g. `RelayProtocol`, `TokenStore`, `FrameDecoder`)
- Functions: `snake_case` (e.g. `encode_frame`, `handle_auth`, `load_config`)
- Private methods/functions: `_snake_case` (e.g. `_send_auth_fail`, `_start_keepalive`)
- Module-level constants: `_UPPER_SNAKE_CASE` with leading underscore when private (e.g. `_MAX_BUFFER_SIZE`, `_CONTROL_STREAM_ID`)
- Logger: always `logger = logging.getLogger(__name__)` at module level

## Module structure pattern
Each module has this structure:
1. Module docstring
2. `from __future__ import annotations`
3. stdlib imports
4. third-party imports
5. local imports (with TYPE_CHECKING guard if needed)
6. `logger = logging.getLogger(__name__)`
7. Module-level constants (`_UPPER_SNAKE`)
8. Classes / functions

## Dataclasses
`ServerConfig` and `TokenConfig` use `@dataclass` with typed fields and sensible defaults:
```python
@dataclass
class ServerConfig:
    host: str = "0.0.0.0"
    port: int = 14550
    ...
```

## Error handling
- Raise `ValueError` for invalid inputs (oversized payloads, bad config, empty frames)
- Log with appropriate level before raising or returning falsy
- Use `logger.warning(...)` for expected-but-wrong inputs
- Use `logger.error(...)` for unexpected/internal errors
- Never leak sensitive information in error messages or AUTH_FAIL reasons

## Asyncio patterns
- `asyncio_mode = "auto"` in pyproject.toml (no `@pytest.mark.asyncio` needed)
- Use `asyncio.ensure_future(coro)` for fire-and-forget async calls from sync context
- Use `asyncio.get_event_loop().call_soon(...)` for deferred sync callbacks
- Entry point uses `asyncio.run(run_server(config))`

## Tests
- Test files in `server/tests/`, one file per module
- Fixtures in `conftest.py` — shared `token_store`, `registry`, `server_config`, `tls_paths`
- Use `tmp_path` pytest fixture for temporary files
- Token bytes for tests: vehicle = `b"\x00" * 16`, gcs = `b"\xbb" * 16`
- Mock QUIC objects (not real connections) in unit tests
- Integration tests in `tests/integration/` use real aioquic clients
