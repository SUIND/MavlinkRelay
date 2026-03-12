#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/evidence.sh"

SCRIPT="$REPO_ROOT/scripts/lte-recovery.sh"

# Test 1: --level missing → exits 2
exit_code=0
"$SCRIPT" 2>/dev/null || exit_code=$?
if [ "$exit_code" -eq 2 ]; then
    pass "missing-level-exits-2" "exit code was $exit_code"
else
    fail "missing-level-exits-2" "expected exit 2, got $exit_code"
fi

# Test 2: --level 5 → exits 2 (invalid level)
exit_code=0
"$SCRIPT" --level 5 2>/dev/null || exit_code=$?
if [ "$exit_code" -eq 2 ]; then
    pass "invalid-level-5-exits-2" "exit code was $exit_code"
else
    fail "invalid-level-5-exits-2" "expected exit 2, got $exit_code"
fi

# Test 3: L1 dry-run → exits 0, outputs "would run"
exit_code=0
output=""
output="$("$SCRIPT" --level 1 --dry-run 2>&1)" || exit_code=$?
if [ "$exit_code" -eq 0 ] && echo "$output" | grep -q "would run"; then
    pass "l1-dry-run" "exits 0 and logs 'would run'"
else
    fail "l1-dry-run" "exit=$exit_code output did not contain 'would run': $output"
fi

# Test 4: L2 dry-run → exits 0, outputs link bounce intent
exit_code=0
output=""
output="$("$SCRIPT" --level 2 --dry-run 2>&1)" || exit_code=$?
if [ "$exit_code" -eq 0 ] && echo "$output" | grep -qi "link\|bounce\|down\|up"; then
    pass "l2-dry-run" "exits 0 and logs link bounce intent"
else
    fail "l2-dry-run" "exit=$exit_code or missing link bounce log: $output"
fi

# Test 5: L3 dry-run → exits 0, outputs USB rebind intent
exit_code=0
output=""
output="$("$SCRIPT" --level 3 --dry-run 2>&1)" || exit_code=$?
if [ "$exit_code" -eq 0 ] && echo "$output" | grep -qi "unbind\|rebind\|usb"; then
    pass "l3-dry-run" "exits 0 and logs USB rebind intent"
else
    fail "l3-dry-run" "exit=$exit_code or missing USB rebind log: $output"
fi

# Test 6: L4 dry-run with --mock-port → exits 0, does NOT invoke find-at-port.sh
TMP_LOG="$(mktemp)"
exit_code=0
output=""
output="$("$SCRIPT" --level 4 --dry-run --mock-port /dev/ttyUSB2 2>&1)" || exit_code=$?
rm -f "$TMP_LOG"
if [ "$exit_code" -eq 0 ] && ! echo "$output" | grep -q "find-at-port.sh.*discovering"; then
    pass "l4-dry-run-mock-port" "exits 0; dry-run does not invoke find-at-port discovery"
else
    fail "l4-dry-run-mock-port" "exit=$exit_code or find-at-port.sh was invoked unexpectedly"
fi

# Test 7: no-reboot check — grep all recovery files for reboot, assert zero
RECOVERY_FILES=(
    "$REPO_ROOT/scripts/lte-recovery.sh"
)
reboot_hits=""
for f in "${RECOVERY_FILES[@]}"; do
    if [ -f "$f" ]; then
        hits="$(grep -nE '\breboot\b|shutdown[[:space:]]+-r|systemctl[[:space:]]+reboot' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
        if [ -n "$hits" ]; then
            reboot_hits="$reboot_hits $f: $hits"
        fi
    fi
done

if [ -z "$reboot_hits" ]; then
    pass "no-reboot-in-recovery" "no reboot/shutdown/systemctl reboot found in recovery script"
else
    fail "no-reboot-in-recovery" "forbidden reboot command found: $reboot_hits"
fi

# Test 8: syntax check
if bash -n "$SCRIPT" 2>/tmp/bash_n_recovery_err; then
    pass "recovery-syntax" "bash -n scripts/lte-recovery.sh"
else
    err_text="$(cat /tmp/bash_n_recovery_err)"
    fail "recovery-syntax" "$err_text"
fi

summary
