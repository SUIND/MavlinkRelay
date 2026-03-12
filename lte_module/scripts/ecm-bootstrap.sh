#!/usr/bin/env bash
# ecm-bootstrap.sh — Idempotently verify and enforce ECM mode on EC200U-CN modem
#
# Behaviour:
#   1. Discovers the AT port dynamically via find-at-port.sh
#   2. Queries AT+QCFG="usbnet" — if already ECM (,1), exits 0 (no-op)
#   3. If NOT ECM: sends AT+QCFG="usbnet",1 + AT+CFUN=1,1 to restart modem
#   4. Waits up to ECM_REENUM_TIMEOUT_S for modem USB re-enumeration
#   5. Waits up to 10s for lte0 interface to appear
#
# Exit codes (per CONVENTIONS.md §2.4):
#   0  — success (already ECM, or successfully switched to ECM + interface up)
#   1  — general error
#   2  — configuration error (missing params, find-at-port.sh absent)
#   3  — hardware error (modem didn't re-enumerate, AT unresponsive)
#   4  — network error (lte0 interface not up after re-enumeration)
#   5  — permission error (not root)
#
# Flags:
#   --dry-run            Print every action; skip real AT port open
#   --mock-ecm-mode N    Simulate AT query returning mode N (0=non-ECM, 1=ECM)
#
# Sources: config/params.env for LTE_MODEM_VID_PID, LTE_INTERFACE_NAME, etc.

set -euo pipefail

###############################################################################
# Resolve paths (SCRIPT_DIR pattern — never hardcode)
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARAMS_ENV="$REPO_ROOT/config/params.env"
# When deployed to /usr/local/lib/lte-module/, the repo-relative path is wrong;
# prefer the installed system copy if it exists.
[[ -f "/etc/lte-module/params.env" ]] && PARAMS_ENV="/etc/lte-module/params.env"

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
MOCK_ECM_MODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --mock-ecm-mode)
            if [[ $# -lt 2 ]]; then
                log_error "--mock-ecm-mode requires an argument (0 or 1)"
                exit 2
            fi
            MOCK_ECM_MODE="$2"
            shift 2
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

# Defaults for params that may be absent in older params.env
ECM_REENUM_TIMEOUT_S="${ECM_REENUM_TIMEOUT_S:-30}"
LTE_INTERFACE_NAME="${LTE_INTERFACE_NAME:-lte0}"
LTE_MODEM_VID_PID="${LTE_MODEM_VID_PID:-2c7c:0901}"

###############################################################################
# AT send/receive helpers
# Pattern: printf 'CMD\r\n' > "$AT_PORT"  /  timeout 3 cat "$AT_PORT"
###############################################################################

# Send an AT command to the port; return the response on stdout.
# In dry-run mode: log only, return simulated response.
# In mock-ecm-mode: intercept the query command and return mocked response.
at_send_recv() {
    local port="$1"
    local cmd="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would send to ${port}: ${cmd}"
        # Provide plausible mock responses for dry-run
        case "$cmd" in
            'AT+QCFG="usbnet"')
                if [[ -n "$MOCK_ECM_MODE" ]]; then
                    printf '+QCFG: "usbnet",%s,0\r\nOK\r\n' "$MOCK_ECM_MODE"
                else
                    printf '+QCFG: "usbnet",1,0\r\nOK\r\n'
                fi
                ;;
            *)
                printf 'OK\r\n'
                ;;
        esac
        return 0
    fi

    # Live mode: open port, write command, read response
    printf '%s\r\n' "$cmd" > "$port"
    timeout 3 cat "$port" || true
}

###############################################################################
# Query current USB network mode
# Returns 0 if already ECM (mode 1), 1 otherwise
###############################################################################
query_ecm_mode() {
    local port="$1"

    # --mock-ecm-mode bypasses the real AT query entirely
    if [[ -n "$MOCK_ECM_MODE" ]]; then
        log_info "(mock) Simulating AT+QCFG=\"usbnet\" response: mode=${MOCK_ECM_MODE}"
        if [[ "$MOCK_ECM_MODE" == "1" ]]; then
            return 0  # mock says already ECM
        else
            return 1  # mock says not ECM
        fi
    fi

    log_info "Querying current USB network mode: AT+QCFG=\"usbnet\""
    local response
    response="$(at_send_recv "$port" 'AT+QCFG="usbnet"')"
    log_debug "Raw response: $(printf '%s' "$response" | tr '\r\n' ' ')"

    # ECM active = response contains ",1," or ends with ",1" (e.g. +QCFG: "usbnet",1,0)
    if printf '%s' "$response" | grep -qE ',1[,\r]?'; then
        return 0  # Already ECM
    else
        return 1  # Not ECM
    fi
}

###############################################################################
# Wait for modem to re-enumerate on USB bus
# Polls lsusb -d VID:PID up to 30 times with 2s delay (MUST DO spec)
###############################################################################
wait_for_reenum() {
    local vid_pid="$1"
    local max_polls=30
    local delay_s=2

    log_info "Waiting for modem to re-enumerate on USB (VID:PID ${vid_pid}, up to $((max_polls * delay_s))s) ..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would poll: lsusb -d ${vid_pid} (${max_polls} × ${delay_s}s)"
        log_info "(dry-run) Simulating successful re-enumeration"
        return 0
    fi

    local attempt=0
    while [[ "$attempt" -lt "$max_polls" ]]; do
        if lsusb -d "$vid_pid" &>/dev/null; then
            log_info "Modem re-enumerated on USB after $((attempt * delay_s))s"
            return 0
        fi
        sleep "$delay_s"
        attempt=$((attempt + 1))
    done

    log_error "Modem did NOT re-enumerate within $((max_polls * delay_s))s (VID:PID ${vid_pid})"
    return 1
}

###############################################################################
# Wait for lte0 interface to appear
# Polls ip link show for up to 10s
###############################################################################
wait_for_interface() {
    local iface="$1"
    local timeout_s=10

    log_info "Waiting up to ${timeout_s}s for interface ${iface} to appear ..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would poll: ip link show ${iface} (up to ${timeout_s}s)"
        log_info "(dry-run) Simulating interface ${iface} appearing"
        return 0
    fi

    local elapsed=0
    while [[ "$elapsed" -lt "$timeout_s" ]]; do
        if ip link show "$iface" &>/dev/null; then
            log_info "Interface ${iface} appeared after ${elapsed}s"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    log_error "Interface ${iface} did not appear within ${timeout_s}s"
    return 1
}

###############################################################################
# Main
###############################################################################
main() {
    log_info "=== ECM Bootstrap starting ==="

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run mode active — no AT commands will be sent, no ports opened)"
    fi
    if [[ -n "$MOCK_ECM_MODE" ]]; then
        log_info "(mock-ecm-mode=${MOCK_ECM_MODE} — AT query will return simulated mode)"
    fi

    # Permission check: writing to /dev/ttyUSBx requires root or dialout group
    if [[ "$DRY_RUN" == "false" && "$EUID" -ne 0 ]]; then
        log_error "Must run as root (or member of dialout group). EUID=${EUID}"
        exit 5
    fi

    # IDEMPOTENCY FAST PATH: lte0 exists AND has carrier (LOWER_UP) AND has an IPv4 address
    # → data session already active, nothing to do.
    # If lte0 exists but has NO-CARRIER or no IP → need to initiate data session.
    if [[ "$DRY_RUN" == "false" ]] && ip link show "$LTE_INTERFACE_NAME" &>/dev/null; then
        local iface_flags
        iface_flags=$(ip link show "$LTE_INTERFACE_NAME" 2>/dev/null)
        if printf '%s' "$iface_flags" | grep -q "LOWER_UP" && \
           ip -4 addr show "$LTE_INTERFACE_NAME" 2>/dev/null | grep -q "inet "; then
            log_info "Interface ${LTE_INTERFACE_NAME} is UP with carrier and IPv4 — ECM active"
            log_info "=== ECM Bootstrap complete (no-op) ==="
            exit 0
        fi
        log_info "Interface ${LTE_INTERFACE_NAME} exists but NO-CARRIER or no IPv4 — attempting AT data session setup"
    fi

    # Validate find-at-port.sh is present and executable
    local find_at_port="$SCRIPT_DIR/find-at-port.sh"
    if [[ ! -x "$find_at_port" ]]; then
        log_error "find-at-port.sh not found or not executable: ${find_at_port}"
        exit 2
    fi

    # --- Discover AT port (never hardcode — CONVENTIONS.md §1.5) ---
    log_info "Discovering AT port via find-at-port.sh ..."
    local at_port
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would call: ${find_at_port} --dry-run"
        at_port="/dev/ttyUSB_DRYRUN"
        log_info "(dry-run) Simulated AT port: ${at_port}"
    else
        at_port="$("$find_at_port")"
        if [[ -z "$at_port" ]]; then
            log_error "find-at-port.sh returned empty — modem AT port not found"
            exit 3
        fi
        log_info "AT port discovered: ${at_port}"
    fi

    # -------------------------------------------------------------------------
    # IDEMPOTENCY GATE: query current mode before sending any set commands.
    # If already ECM (mode 1) → fall through to APN+connect step.
    # If NOT ECM → switch mode, restart, re-enumerate, wait for interface.
    # -------------------------------------------------------------------------
    if query_ecm_mode "$at_port"; then
        log_info "ECM mode already active — checking data session"
    else
        log_info "Modem is NOT in ECM mode — proceeding with mode switch"

        log_info "Sending: AT+QCFG=\"usbnet\",1 (select ECM mode)"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "(dry-run) Would send to ${at_port}: AT+QCFG=\"usbnet\",1"
        else
            printf 'AT+QCFG="usbnet",1\r\n' > "$at_port"
            timeout 3 cat "$at_port" || true
        fi

        log_info "Sending: AT+CFUN=1,1 (modem restart — required to apply USB mode change)"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "(dry-run) Would send to ${at_port}: AT+CFUN=1,1"
        else
            printf 'AT+CFUN=1,1\r\n' > "$at_port" || true
            timeout 3 cat "$at_port" 2>/dev/null || true
        fi

        log_info "Modem restart command sent — awaiting USB re-enumeration ..."

        if ! wait_for_reenum "$LTE_MODEM_VID_PID"; then
            log_error "Hardware error: modem failed to re-enumerate after ECM switch"
            exit 3
        fi

        if [[ "$DRY_RUN" == "false" ]]; then
            log_info "Sleeping 2s to allow driver re-bind ..."
            sleep 2
        fi

        if ! wait_for_interface "$LTE_INTERFACE_NAME"; then
            log_error "Network error: interface ${LTE_INTERFACE_NAME} did not appear after re-enumeration"
            exit 4
        fi

        log_info "ECM mode successfully enforced — interface ${LTE_INTERFACE_NAME} is present"
    fi

    if [[ -n "${LTE_APN:-}" ]]; then
        log_info "Setting APN: ${LTE_APN}"
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "(dry-run) Would send: AT+CGDCONT=1,\"IP\",\"${LTE_APN}\""
        else
            printf 'AT+CGDCONT=1,"IP","%s"\r\n' "$LTE_APN" > "$at_port" || true
            sleep 1
        fi
    else
        log_info "LTE_APN is empty — using modem default APN (auto-negotiated)"
    fi

    log_info "Triggering ECM data session: AT+QNETDEVCTL=1,1,1"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would send: AT+QNETDEVCTL=1,1,1"
    else
        printf 'AT+QNETDEVCTL=1,1,1\r\n' > "$at_port" || true
        sleep 3
    fi

    log_info "=== ECM Bootstrap complete ==="
    exit 0
}

main "$@"
