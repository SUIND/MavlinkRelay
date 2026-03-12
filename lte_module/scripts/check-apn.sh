#!/usr/bin/env bash
# check-apn.sh — Verify SIM state, LTE registration, configure APN, probe connectivity
#
# Strategy:
#   1. Check SIM:              AT+CPIN? must return +CPIN: READY          (exit 3 if not)
#   2. Check LTE registration: AT+CEREG? stat=1 (home) or stat=5 (roam)  (exit 3 if not)
#   3. APN logic:
#      - LTE_APN empty/unset  → auto/default APN; no AT+CGDCONT sent
#      - LTE_APN non-empty    → send AT+CGDCONT=1,"IP","${LTE_APN}"
#   4. Probe connectivity:     dig +short +timeout=3 google.com @8.8.8.8  (exit 4 if fails)
#
# Usage:
#   check-apn.sh [--dry-run] [--mock-reg-status N] [--mock-apn-mode {auto|explicit}]
#
# Options:
#   --dry-run               Log actions; skip AT port IO and dig probe; exit 0
#   --mock-reg-status N     Simulate AT+CEREG? response (1=home, 5=roaming, 0=not registered)
#   --mock-apn-mode MODE    Simulate APN path: "auto" or "explicit"
#
# Exit codes:
#   0  Success
#   1  General error
#   2  Config error (params.env not found or invalid)
#   3  Hardware error (SIM not ready, modem not registered, AT port not found)
#   4  Network error (connectivity probe failed)

set -euo pipefail

##############################################################################
# Logging — all output to stderr
##############################################################################

_log() {
    local level="$1"
    shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts}] [${level}] $*" >&2
}

log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
log_debug() { _log "DEBUG" "$@"; }

##############################################################################
# Defaults
##############################################################################

DRY_RUN=false
MOCK_REG_STATUS=""   # empty = no mock; set to 0/1/5 to simulate CEREG stat
MOCK_APN_MODE=""     # empty = no mock; "auto" or "explicit"

##############################################################################
# Argument parsing
##############################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --mock-reg-status)
            if [[ $# -lt 2 ]]; then
                log_error "--mock-reg-status requires an argument"
                exit 2
            fi
            MOCK_REG_STATUS="$2"
            shift 2
            ;;
        --mock-apn-mode)
            if [[ $# -lt 2 ]]; then
                log_error "--mock-apn-mode requires an argument (auto|explicit)"
                exit 2
            fi
            MOCK_APN_MODE="$2"
            if [[ "$MOCK_APN_MODE" != "auto" && "$MOCK_APN_MODE" != "explicit" ]]; then
                log_error "--mock-apn-mode must be 'auto' or 'explicit'; got: $MOCK_APN_MODE"
                exit 2
            fi
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

##############################################################################
# Source deployment parameters (SCRIPT_DIR pattern)
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAMS_ENV="${SCRIPT_DIR}/../config/params.env"

if [[ ! -f "$PARAMS_ENV" ]]; then
    log_error "params.env not found at: $PARAMS_ENV"
    exit 2
fi

# shellcheck source=../config/params.env
source "$PARAMS_ENV"

# LTE_APN: empty string = auto/default APN (modem negotiates with network)
#           non-empty string = explicit APN configured by operator
LTE_APN="${LTE_APN:-}"
LTE_INTERFACE_NAME="${LTE_INTERFACE_NAME:-lte0}"

##############################################################################
# AT command helper
##############################################################################

# send_at <port> <command> [timeout_seconds]
# Sends an AT command to <port>, returns the full response on stdout.
# Returns 0 always (caller inspects response content).
send_at() {
    local port="$1"
    local cmd="$2"
    local timeout_s="${3:-5}"

    local response
    response=$(
        exec 3<>"$port"
        stty -F "$port" 115200 cs8 -cstopb -parenb raw -echo -hupcl 2>/dev/null || true
        printf '%s\r\n' "$cmd" >&3
        sleep 1
        timeout "$timeout_s" cat <&3 2>/dev/null || true
        exec 3>&-
    ) 2>/dev/null || true

    log_debug "AT[${cmd}] response: $(echo "$response" | tr '\r\n' ' ')"
    printf '%s' "$response"
}

##############################################################################
# Step 1: Discover AT port
##############################################################################

log_info "Step 1: Discovering AT port via find-at-port.sh..."

if [[ "$DRY_RUN" == "true" ]]; then
    AT_PORT="/dev/ttyUSB_DRYRUN"
    log_info "[DRY-RUN] Skipping AT port discovery — placeholder: ${AT_PORT}"
else
    AT_PORT="$("${SCRIPT_DIR}/find-at-port.sh")" || {
        log_error "find-at-port.sh failed — modem not present or not responsive"
        exit 3
    }
    if [[ -z "$AT_PORT" ]]; then
        log_error "find-at-port.sh returned empty port — no AT port available"
        exit 3
    fi
    log_info "AT port discovered: ${AT_PORT}"
fi

##############################################################################
# Step 2: Check SIM state (AT+CPIN?)
##############################################################################

log_info "Step 2: Checking SIM state (AT+CPIN?)..."

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would send: AT+CPIN?"
    log_info "[DRY-RUN] Expected response: +CPIN: READY"
else
    CPIN_RESPONSE="$(send_at "$AT_PORT" "AT+CPIN?")"
    if ! echo "$CPIN_RESPONSE" | grep -q "+CPIN: READY"; then
        log_error "SIM not ready — response: $(echo "$CPIN_RESPONSE" | tr '\r\n' ' ')"
        log_error "Check that SIM is inserted and not PIN-locked"
        exit 3
    fi
    log_info "SIM state: READY"
fi

##############################################################################
# Step 3: Check LTE EPS registration (AT+CEREG?)
##############################################################################

log_info "Step 3: Checking LTE EPS registration (AT+CEREG?)..."

if [[ -n "$MOCK_REG_STATUS" ]]; then
    # Mock mode: use provided registration status
    CEREG_STAT="$MOCK_REG_STATUS"
    log_info "[MOCK] Simulating AT+CEREG? stat=${CEREG_STAT}"
elif [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would send: AT+CEREG?"
    log_info "[DRY-RUN] Expected response: +CEREG: 0,1 (home) or +CEREG: 0,5 (roaming)"
    CEREG_STAT="1"  # dry-run assumes registered
else
    CEREG_RESPONSE="$(send_at "$AT_PORT" "AT+CEREG?")"
    # +CEREG: <n>,<stat>  OR  +CEREG: <stat>
    # Extract the last integer on the +CEREG line
    CEREG_STAT="$(echo "$CEREG_RESPONSE" | grep '+CEREG:' | grep -oE '[0-9]+' | tail -1)" || CEREG_STAT=""
fi

if [[ "$DRY_RUN" != "true" ]] || [[ -n "$MOCK_REG_STATUS" ]]; then
    if [[ "$CEREG_STAT" != "1" && "$CEREG_STAT" != "5" ]]; then
        log_error "LTE not registered — AT+CEREG stat=${CEREG_STAT} (expected 1=home or 5=roaming)"
        exit 3
    fi
    if [[ "$CEREG_STAT" == "1" ]]; then
        log_info "LTE registration: HOME (stat=1)"
    else
        log_info "LTE registration: ROAMING (stat=5)"
    fi
fi

##############################################################################
# Step 4: APN logic
##############################################################################

log_info "Step 4: Evaluating APN configuration..."

# Determine effective APN mode (mock overrides real LTE_APN check)
if [[ -n "$MOCK_APN_MODE" ]]; then
    _apn_mode="$MOCK_APN_MODE"
    log_info "[MOCK] APN mode forced to: ${_apn_mode}"
elif [[ -z "$LTE_APN" ]]; then
    _apn_mode="auto"
else
    _apn_mode="explicit"
fi

if [[ "$_apn_mode" == "auto" ]]; then
    # APN=auto (using modem default): do NOT send any AT+CGDCONT command
    log_info "APN=auto (using modem default) — no PDP context modification"
    log_info "Modem will negotiate APN automatically with the carrier network"
else
    # APN=explicit: set PDP context with the configured APN
    log_info "APN=explicit: ${LTE_APN}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would send: AT+CGDCONT=1,\"IP\",\"${LTE_APN}\""
    else
        log_info "Setting PDP context: AT+CGDCONT=1,\"IP\",\"${LTE_APN}\""
        APN_RESPONSE="$(send_at "$AT_PORT" "AT+CGDCONT=1,\"IP\",\"${LTE_APN}\"")"
        if ! echo "$APN_RESPONSE" | grep -q "OK"; then
            log_error "Failed to set APN '${LTE_APN}' — response: $(echo "$APN_RESPONSE" | tr '\r\n' ' ')"
            exit 3
        fi
        log_info "PDP context set successfully: APN=${LTE_APN}"
    fi
fi

##############################################################################
# Step 5: Connectivity probe via dig
##############################################################################

log_info "Step 5: Probing connectivity (dig +short +timeout=3 google.com @8.8.8.8)..."

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY-RUN] Would run: dig +short +timeout=3 google.com @8.8.8.8"
    log_info "[DRY-RUN] Skipping connectivity probe"
else
    DIG_RESULT="$(dig +short +timeout=3 google.com @8.8.8.8 2>/dev/null)" || DIG_RESULT=""

    # A valid result is a non-empty string containing an IP address
    if [[ -z "$DIG_RESULT" ]]; then
        log_error "connectivity probe failed — APN may be incorrect or network not reachable"
        log_error "Command: dig +short +timeout=3 google.com @8.8.8.8"
        log_error "Hint: If APN=auto did not work, set LTE_APN in config/params.env"
        exit 4
    fi

    log_info "connectivity OK — google.com resolved to: ${DIG_RESULT}"
fi

##############################################################################
# Success
##############################################################################

log_info "APN verification complete: all checks passed"
exit 0
