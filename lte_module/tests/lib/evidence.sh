#!/usr/bin/env bash
# Shared test helper library for evidence capture and test result tracking
# Source this in all test scripts

EVIDENCE_DIR="${EVIDENCE_DIR:-.sisyphus/evidence}"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Initialize evidence directory
mkdir -p "$EVIDENCE_DIR"

# Print a passing check
pass() {
    local check_name="$1"
    local detail="${2:-}"
    ((PASS_COUNT++))
    if [ -n "$detail" ]; then
        echo "[PASS] $check_name: $detail"
    else
        echo "[PASS] $check_name"
    fi
}

# Print a failing check
fail() {
    local check_name="$1"
    local detail="${2:-unknown reason}"
    ((FAIL_COUNT++))
    echo "[FAIL] $check_name: $detail"
}

# Print a skipped check
skip() {
    local check_name="$1"
    local reason="${2:-not applicable}"
    ((SKIP_COUNT++))
    echo "[SKIP] $check_name: $reason"
}

# Require hardware tests to be enabled
# If HARDWARE_TESTS != "1", skip and return error code
require_hardware() {
    if [ "$HARDWARE_TESTS" != "1" ]; then
        skip "${FUNCNAME[1]}" "hardware tests not enabled (set HARDWARE_TESTS=1)"
        return 1
    fi
    return 0
}

# Save evidence to a file
save_evidence() {
    local filename="$1"
    local content="$2"
    mkdir -p "$EVIDENCE_DIR"
    echo "$content" > "$EVIDENCE_DIR/$filename"
}

# Print summary of all tests and return appropriate exit code
summary() {
    echo "---"
    echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
    if [ "$FAIL_COUNT" -gt 0 ]; then
        return 1
    fi
    return 0
}
