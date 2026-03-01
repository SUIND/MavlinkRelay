# Configuration Reference — MavlinkRelay Server

## YAML config structure
```yaml
server:
  host: "0.0.0.0"       # bind address (default: "0.0.0.0")
  port: 14550            # UDP port (default: 14550)

tls:
  cert: "certs/cert.pem" # path to server TLS certificate (required)
  key: "certs/key.pem"   # path to TLS private key (required)

auth:
  tokens:
    - token: "AAAAAAAAAAAAAAAAAAAAAA=="  # base64-encoded 16-byte token (required)
      role: "vehicle"                    # "vehicle" or "gcs" (required)
      vehicle_id: 1                      # required when role=vehicle
    - token: "BBBBBBBBBBBBBBBBBBBBBB=="
      role: "gcs"
      gcs_id: "gcs-alpha"               # required when role=gcs

relay:
  bulk_queue_max: 100       # max frames in bulk outbound queue
  priority_queue_max: 500   # max frames in priority outbound queue

keepalive:
  interval_s: 15    # PING interval in seconds (default: 15.0)
  timeout_s: 45     # close connection after this many seconds without PONG (default: 45.0)

log_level: "INFO"    # INFO | DEBUG | WARNING | ERROR (default: "INFO")
log_format: "json"   # "json" or "text" (default: "json")
```

## ServerConfig dataclass defaults
```python
ServerConfig(
    host="0.0.0.0",
    port=14550,
    cert_path="",           # REQUIRED — empty string triggers ValueError in load_config
    key_path="",            # REQUIRED
    bulk_queue_max=100,
    priority_queue_max=500,
    keepalive_interval_s=15.0,
    keepalive_timeout_s=45.0,
    auth_timeout_s=10.0,    # Note: CLI default is 30.0, YAML default is 10.0
    log_level="INFO",
    log_format="json",
    tokens=[],
)
```

## CLI flags (override YAML values)
| Flag | YAML field overridden | Default |
|------|----------------------|---------|
| `--config` | N/A (loads whole file) | — |
| `--host` | `server.host` | `"0.0.0.0"` |
| `--port` | `server.port` | `14550` |
| `--cert` | `tls.cert` | — (required if no config) |
| `--key` | `tls.key` | — (required if no config) |
| `--log-level` | `log_level` | `"INFO"` |
| `--auth-timeout` | `auth_timeout_s` | `30.0` |
| `--dry-run` | N/A | — |

## load_config() function
Located in `mavlink_relay_server/config.py`:
```python
load_config(path: str, cli_overrides: dict[str, Any]) -> ServerConfig
```
- Raises `FileNotFoundError` if YAML file doesn't exist
- Raises `ValueError` for missing required fields (cert, key, invalid tokens)
- CLI overrides keys: `"host"`, `"port"`, `"cert"`, `"key"`, `"log_level"`

## Token validation (TokenStore)
- `TokenStore(tokens: list[TokenConfig])` — decodes base64 tokens at init
- `TokenStore.validate(token_bytes: bytes) -> TokenConfig | None`
  - Uses `hmac.compare_digest` loop for constant-time comparison
  - Returns `TokenConfig` on match, `None` on miss
- `TokenConfig` fields: `token_b64`, `role`, `vehicle_id`, `gcs_id`

## Test fixtures (conftest.py)
- `vehicle_token_bytes` → `b"\x00" * 16`
- `gcs_token_bytes` → `b"\xbb" * 16`
- `tls_paths` → `(str(cert_path), str(key_path))` with dummy content in tmp_path
- `token_store` → TokenStore with vehicle + gcs tokens
- `registry` → empty SessionRegistry
- `server_config` → ServerConfig with 127.0.0.1:14550, 10s auth timeout
- `example_config_file` → path to a valid YAML config in tmp_path
