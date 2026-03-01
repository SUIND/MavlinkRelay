# Decisions — mavlink-quic-relay-server

## [2026-02-28] Session ses_35aa44d0fffe49ZZzIKobtzJqD — Plan Start

### Execution Waves
- Wave 1: Tasks 1 + 3 (scaffold + framing) — PARALLEL
- Wave 2: Tasks 2 + 4 + 6 (QUIC server + registry + config) — PARALLEL, depends on Wave 1
- Wave 3: Tasks 5 + 7 (relay integration + keepalive) — PARALLEL, depends on Wave 2
- Wave 4: Tasks 8 + 9 + 10 (tests + stats + docker) — PARALLEL, depends on Wave 3
