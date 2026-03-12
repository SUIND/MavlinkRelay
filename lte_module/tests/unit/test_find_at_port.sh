#!/usr/bin/env bash
# Unit test: find-at-port.sh — AT port discovery script
# HARDWARE_REQUIRED: no
# Tests use --mock-port and --dry-run; no hardware access needed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/evidence.sh"

SCRIPT="$REPO_ROOT/scripts/find-at-port.sh"

# ── Test 1: --mock-port /dev/ttyUSB2 returns /dev/ttyUSB2 and exits 0 ─────────

output=$("$SCRIPT" --mock-port /dev/ttyUSB2 2>/dev/null)
exit_code=$?
if [ "$exit_code" -eq 0 ] && [ "$output" = "/dev/ttyUSB2" ]; then
    pass "mock-port-ttyUSB2" "--mock-port /dev/ttyUSB2 → stdout=/dev/ttyUSB2, exit=0"
else
    fail "mock-port-ttyUSB2" "expected stdout=/dev/ttyUSB2 exit=0, got stdout='$output' exit=$exit_code"
fi

# ── Test 2: --mock-port /dev/ttyUSB0 returns /dev/ttyUSB0 and exits 0 ─────────

output=$("$SCRIPT" --mock-port /dev/ttyUSB0 2>/dev/null)
exit_code=$?
if [ "$exit_code" -eq 0 ] && [ "$output" = "/dev/ttyUSB0" ]; then
    pass "mock-port-ttyUSB0" "--mock-port /dev/ttyUSB0 → stdout=/dev/ttyUSB0, exit=0"
else
    fail "mock-port-ttyUSB0" "expected stdout=/dev/ttyUSB0 exit=0, got stdout='$output' exit=$exit_code"
fi

# ── Test 3: --mock-port without argument exits 2 ──────────────────────────────

"$SCRIPT" --mock-port 2>/dev/null
exit_code=$?
if [ "$exit_code" -eq 2 ]; then
    pass "mock-port-no-arg" "--mock-port (no arg) exits 2 (config error)"
else
    fail "mock-port-no-arg" "expected exit=2, got exit=$exit_code"
fi

# ── Test 4: Unknown flag --bogus exits 2 ──────────────────────────────────────

"$SCRIPT" --bogus 2>/dev/null
exit_code=$?
if [ "$exit_code" -eq 2 ]; then
    pass "unknown-flag" "--bogus exits 2 (config error)"
else
    fail "unknown-flag" "expected exit=2, got exit=$exit_code"
fi

# ── Test 5: --dry-run with no ttyUSB devices exits 3 ─────────────────────────
# In CI without hardware, /dev/ttyUSB* glob will not expand → no candidates → exit 3.
# With hardware present, --dry-run skips probing → all candidates fail → exit 3.
# Either way, --dry-run must exit 3 (no AT port found).

"$SCRIPT" --dry-run 2>/dev/null
exit_code=$?
if [ "$exit_code" -eq 3 ]; then
    pass "dry-run-exits-3" "--dry-run exits 3 (no AT port in dry-run mode)"
else
    fail "dry-run-exits-3" "expected exit=3, got exit=$exit_code"
fi

# ── Test 6: bash -n syntax check ─────────────────────────────────────────────

if bash -n "$SCRIPT" 2>/tmp/bash_n_find_at_port_err; then
    pass "syntax-check" "bash -n scripts/find-at-port.sh passes syntax check"
else
    err=$(cat /tmp/bash_n_find_at_port_err)
    fail "syntax-check" "bash -n failed: $err"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

summary
