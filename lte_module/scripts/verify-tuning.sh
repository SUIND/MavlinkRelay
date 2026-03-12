#!/usr/bin/env bash
# verify-tuning.sh — Post-enumeration tuning verification for EC200U-CN modem
#
# Checks that OS-level tuning parameters are correctly applied after modem
# enumeration. Designed to be run after deployment to confirm:
#   1. USB autosuspend is disabled (sysfs power/control = on)
#   2. MTU is set to 1400 in network/10-lte0.link
#   3. If LTE_RAT_LOCK_ENABLED=1: AT+QNWPREFMDE=2 applied (LTE-only)
#   4. Autosuspend delay (autosuspend_delay_ms) is reported
#
# Usage:
#   verify-tuning.sh [--dry-run]
#
# Options:
#   --dry-run    Skip actual sysfs reads and AT commands; log intent only
#
# Exit codes (per CONVENTIONS.md §2.4):
#   0  All applicable checks pass
#   1  General error
#   2  Configuration error (missing params.env, missing find-at-port.sh)
#   3  Hardware error (modem sysfs path not found, AT command failure)
#   4  Check failure (autosuspend not disabled, MTU mismatch, RAT lock mismatch)
#   5  Permission error (not root, in live mode)
#
# Sources: config/params.env for LTE_MODEM_VID_PID, LTE_RAT_LOCK_ENABLED, etc.

###############################################################################
# Resolve paths (SCRIPT_DIR pattern — never hardcode)
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARAMS_ENV="$REPO_ROOT/config/params.env"

###############################################################################
# Logging helpers — all output to stderr (CONVENTIONS.md §2.1)
###############################################################################
_log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >&2
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
log_debug() { _log "DEBUG" "$@"; }

###############################################################################
# Argument parsing
###############################################################################
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 2
            ;;
        *)
            log_error "Unexpected argument: $1"
            exit 2
            ;;
    esac
done

###############################################################################
# Source deployment parameters (single source of truth)
###############################################################################
if [[ ! -f "$PARAMS_ENV" ]]; then
    log_error "params.env not found: $PARAMS_ENV"
    exit 2
fi
# shellcheck source=../config/params.env
source "$PARAMS_ENV"

# Defaults for params that may be absent
LTE_MODEM_VID_PID="${LTE_MODEM_VID_PID:-2c7c:0901}"
LTE_RAT_LOCK_ENABLED="${LTE_RAT_LOCK_ENABLED:-0}"
LTE_MTU="${LTE_MTU:-1400}"

# Derive VID from VID:PID (e.g. "2c7c" from "2c7c:0901")
MODEM_VID="${LTE_MODEM_VID_PID%%:*}"

###############################################################################
# Track check results
###############################################################################
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0

check_pass() {
    log_info "[PASS] $*"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

check_fail() {
    log_error "[FAIL] $*"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

check_skip() {
    log_info "[SKIP] $*"
    CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1))
}

###############################################################################
# Dynamically locate the modem's sysfs USB device path
#
# Strategy: find by VID (idVendor file in /sys/bus/usb/devices/)
# Returns the parent device directory (e.g. /sys/bus/usb/devices/1-1)
###############################################################################
find_modem_sysfs_path() {
    local vid="$1"
    local found_path=""

    # Search all USB devices for the matching idVendor
    # Each USB device directory contains an idVendor file
    local vendor_file
    while IFS= read -r vendor_file; do
        local device_dir
        device_dir="$(dirname "$vendor_file")"
        # Check idVendor matches
        if [[ "$(cat "$vendor_file" 2>/dev/null)" == "$vid" ]]; then
            found_path="$device_dir"
            break
        fi
    done < <(find /sys/bus/usb/devices/ -maxdepth 2 -name "idVendor" 2>/dev/null)

    echo "$found_path"
}

###############################################################################
# CHECK 1: USB autosuspend disabled (power/control = on)
###############################################################################
check_autosuspend() {
    log_info "--- Check 1: USB autosuspend (power/control) ---"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would: find modem sysfs path using VID=${MODEM_VID}"
        log_info "(dry-run) Would: read /sys/bus/usb/devices/<modem-path>/power/control"
        log_info "(dry-run) Would: assert value equals 'on'"
        check_skip "autosuspend-control (dry-run — skipping actual sysfs read)"
        return
    fi

    local modem_sysfs_path
    modem_sysfs_path="$(find_modem_sysfs_path "$MODEM_VID")"

    if [[ -z "$modem_sysfs_path" ]]; then
        check_fail "autosuspend-control — modem sysfs path not found for VID=${MODEM_VID}"
        log_error "Is the modem plugged in? Is VID correct? LTE_MODEM_VID_PID=${LTE_MODEM_VID_PID}"
        CHECKS_FAILED=$((CHECKS_FAILED - 1))  # undo double-count; we exit early
        log_error "Cannot continue checks without modem sysfs path"
        exit 3
    fi

    log_info "Modem sysfs path: ${modem_sysfs_path}"

    local power_control_path="${modem_sysfs_path}/power/control"
    if [[ ! -f "$power_control_path" ]]; then
        check_fail "autosuspend-control — sysfs file not found: ${power_control_path}"
        return
    fi

    local power_control_value
    power_control_value="$(cat "$power_control_path" 2>/dev/null | tr -d '[:space:]')"
    log_info "power/control value: '${power_control_value}' (path: ${power_control_path})"

    if [[ "$power_control_value" == "on" ]]; then
        check_pass "autosuspend-control — power/control=on (autosuspend disabled)"
    else
        check_fail "autosuspend-control — power/control='${power_control_value}' (expected 'on')"
        log_error "Autosuspend is NOT disabled. The udev rule may not have applied."
        log_error "Fix: sudo udevadm control --reload-rules && sudo udevadm trigger"
    fi
}

###############################################################################
# CHECK 2: Autosuspend delay reported (autosuspend_delay_ms)
###############################################################################
check_autosuspend_delay() {
    log_info "--- Check 4: USB autosuspend delay (autosuspend_delay_ms) ---"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would: read /sys/bus/usb/devices/<modem-path>/power/autosuspend_delay_ms"
        log_info "(dry-run) Would: log value (should be -1 = disabled)"
        check_skip "autosuspend-delay (dry-run — skipping actual sysfs read)"
        return
    fi

    local modem_sysfs_path
    modem_sysfs_path="$(find_modem_sysfs_path "$MODEM_VID")"

    if [[ -z "$modem_sysfs_path" ]]; then
        check_skip "autosuspend-delay — modem sysfs path not found (already reported in Check 1)"
        return
    fi

    local delay_path="${modem_sysfs_path}/power/autosuspend_delay_ms"
    if [[ ! -f "$delay_path" ]]; then
        log_warn "autosuspend_delay_ms file not found: ${delay_path} (kernel may not expose this)"
        check_skip "autosuspend-delay — sysfs file not present on this kernel"
        return
    fi

    local delay_value
    delay_value="$(cat "$delay_path" 2>/dev/null | tr -d '[:space:]')"
    log_info "power/autosuspend_delay_ms value: '${delay_value}' (path: ${delay_path})"

    if [[ "$delay_value" == "-1" ]]; then
        check_pass "autosuspend-delay — autosuspend_delay_ms=-1 (disabled)"
    else
        log_warn "autosuspend-delay — autosuspend_delay_ms='${delay_value}' (expected '-1'; non-critical if power/control=on)"
        check_skip "autosuspend-delay — value is non-standard but power/control takes precedence"
    fi
}

###############################################################################
# CHECK 3: MTU=1400 in network/10-lte0.link (static file check)
###############################################################################
check_mtu() {
    log_info "--- Check 2: MTU setting in network/10-lte0.link ---"

    local link_file="${REPO_ROOT}/network/10-lte0.link"

    if [[ ! -f "$link_file" ]]; then
        check_fail "mtu-link-file — file not found: ${link_file}"
        return
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would: grep MTUBytes in ${link_file}"
        log_info "(dry-run) Would: assert MTUBytes=${LTE_MTU}"
        check_skip "mtu-link-file (dry-run — skipping grep)"
        return
    fi

    local mtu_line
    mtu_line="$(grep -i 'MTUBytes' "$link_file" 2>/dev/null || true)"

    if [[ -z "$mtu_line" ]]; then
        check_fail "mtu-link-file — MTUBytes not found in ${link_file}"
        return
    fi

    log_info "MTU line found: '${mtu_line}'"

    if echo "$mtu_line" | grep -qE "MTUBytes\s*=\s*${LTE_MTU}"; then
        check_pass "mtu-link-file — MTUBytes=${LTE_MTU} confirmed in ${link_file}"
    else
        local found_mtu
        found_mtu="$(echo "$mtu_line" | grep -oE '[0-9]+')"
        check_fail "mtu-link-file — MTUBytes=${found_mtu} (expected ${LTE_MTU}) in ${link_file}"
    fi
}

###############################################################################
# CHECK 4 (conditional): LTE RAT lock via AT+QNWPREFMDE?
###############################################################################
check_rat_lock() {
    log_info "--- Check 3: LTE RAT lock (LTE_RAT_LOCK_ENABLED=${LTE_RAT_LOCK_ENABLED}) ---"

    # Normalize: treat "0", "false", "no" as disabled
    local rat_enabled=false
    case "${LTE_RAT_LOCK_ENABLED,,}" in
        1|true|yes|on)
            rat_enabled=true
            ;;
        *)
            rat_enabled=false
            ;;
    esac

    if [[ "$rat_enabled" == "false" ]]; then
        log_info "RAT lock disabled (opt-in) — LTE_RAT_LOCK_ENABLED=${LTE_RAT_LOCK_ENABLED}"
        log_info "Modem will use automatic RAT selection (LTE → WCDMA → GSM fallback)"
        check_skip "rat-lock (opt-in disabled — set LTE_RAT_LOCK_ENABLED=1 to enable LTE-only mode)"
        return
    fi

    log_info "RAT lock enabled — verifying AT+QNWPREFMDE=2 via AT command"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would: discover AT port via scripts/find-at-port.sh"
        log_info "(dry-run) Would: send AT+QNWPREFMDE? to AT port"
        log_info "(dry-run) Would: assert response contains '+QNWPREFMDE: 2'"
        check_skip "rat-lock (dry-run — skipping AT command)"
        return
    fi

    # Discover AT port (CONVENTIONS.md §1.5 — never hardcode)
    local find_at_port="${SCRIPT_DIR}/find-at-port.sh"
    if [[ ! -x "$find_at_port" ]]; then
        log_error "find-at-port.sh not found or not executable: ${find_at_port}"
        check_fail "rat-lock — cannot discover AT port (find-at-port.sh missing)"
        return
    fi

    local at_port
    at_port="$("$find_at_port" 2>/dev/null)"
    if [[ -z "$at_port" ]]; then
        check_fail "rat-lock — AT port discovery failed (modem not connected or AT port unresponsive)"
        return
    fi

    log_info "AT port discovered: ${at_port}"

    # Send AT+QNWPREFMDE? and read response
    local response
    response="$(printf 'AT+QNWPREFMDE?\r\n' > "$at_port" && timeout 3 cat "$at_port" 2>/dev/null || true)"
    log_debug "AT+QNWPREFMDE? raw response: $(printf '%s' "$response" | tr '\r\n' ' ')"

    if printf '%s' "$response" | grep -qE '\+QNWPREFMDE:\s*2'; then
        check_pass "rat-lock — AT+QNWPREFMDE=2 confirmed (LTE-only mode active)"
    elif printf '%s' "$response" | grep -qE '\+QNWPREFMDE:\s*0'; then
        check_fail "rat-lock — modem is in auto RAT mode (QNWPREFMDE=0); expected LTE-only (QNWPREFMDE=2)"
        log_error "To lock: send 'AT+QNWPREFMDE=2' to ${at_port}"
    else
        check_fail "rat-lock — unexpected or empty response from AT+QNWPREFMDE?: '$(printf '%s' "$response" | tr '\r\n' ' ')'"
    fi
}

###############################################################################
# Main
###############################################################################
main() {
    log_info "=== verify-tuning.sh starting ==="

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run mode active — no sysfs reads or AT commands will be executed)"
    fi

    # Permission check: sysfs reads are generally OK without root, but AT port requires root
    if [[ "$DRY_RUN" == "false" && "$EUID" -ne 0 ]]; then
        log_warn "Not running as root — sysfs reads may succeed but AT commands require root"
        log_warn "If AT checks fail with permission errors, re-run with sudo"
    fi

    log_info "Parameters: VID:PID=${LTE_MODEM_VID_PID}, LTE_RAT_LOCK_ENABLED=${LTE_RAT_LOCK_ENABLED}, LTE_MTU=${LTE_MTU}"

    # Run checks (order: autosuspend, MTU, RAT lock, autosuspend delay)
    check_autosuspend
    check_mtu
    check_rat_lock
    check_autosuspend_delay

    # Summary
    log_info "=== Verification Summary ==="
    log_info "Passed:  ${CHECKS_PASSED}"
    log_info "Failed:  ${CHECKS_FAILED}"
    log_info "Skipped: ${CHECKS_SKIPPED}"

    if [[ "$CHECKS_FAILED" -gt 0 ]]; then
        log_error "=== verify-tuning.sh FAILED (${CHECKS_FAILED} check(s) failed) ==="
        exit 4
    fi

    log_info "=== verify-tuning.sh PASSED ==="
    exit 0
}

main "$@"
