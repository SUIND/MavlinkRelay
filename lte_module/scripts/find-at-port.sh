#!/usr/bin/env bash
# find-at-port.sh — Discover AT command port on EC200U-CN modem
#
# Probes all /dev/ttyUSB* candidates by sending AT\r\n and checking for OK.
# Does NOT hardcode any specific port number — probes all candidates.
#
# Usage:
#   find-at-port.sh [--dry-run] [--mock-port /dev/ttyUSBN]
#
# Options:
#   --dry-run             Skip actual device open; uses mock logic
#   --mock-port PATH      Return PATH directly (for unit testing)
#
# Exit codes:
#   0  Success — found AT port (printed to stdout)
#   1  General error
#   2  Config error
#   3  Hardware error — no AT port found
#
# Environment:
#   AT_PROBE_TIMEOUT_S    Seconds to wait per port probe (default: 2)

set -euo pipefail

##############################################################################
# Logging
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

AT_PROBE_TIMEOUT_S="${AT_PROBE_TIMEOUT_S:-2}"
DRY_RUN=false
MOCK_PORT=""

##############################################################################
# Argument parsing
##############################################################################

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --mock-port)
            if [[ $# -lt 2 ]]; then
                log_error "--mock-port requires an argument"
                exit 2
            fi
            MOCK_PORT="$2"
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
# Mock-port fast path (for unit tests)
##############################################################################

if [[ -n "$MOCK_PORT" ]]; then
    log_info "mock-port mode: returning ${MOCK_PORT}"
    echo "$MOCK_PORT"
    exit 0
fi

##############################################################################
# Discover candidate ports
##############################################################################

discover_candidates() {
    # Return all /dev/ttyUSB* devices sorted by name
    # shellcheck disable=SC2206
    local candidates=( /dev/ttyUSB* )
    # Check if glob expanded (i.e., at least one device exists)
    if [[ "${#candidates[@]}" -eq 1 && ! -e "${candidates[0]}" ]]; then
        echo ""
        return
    fi
    printf '%s\n' "${candidates[@]}"
}

##############################################################################
# Probe a single port for AT response
##############################################################################

probe_port() {
    local port="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_debug "dry-run: skipping actual probe of ${port}"
        return 1  # dry-run: treat as no response
    fi

    if [[ ! -c "$port" ]]; then
        log_debug "Skipping ${port}: not a character device"
        return 1
    fi

    # Configure port: 115200 8N1, raw mode, no hang-up
    if ! stty -F "$port" 115200 cs8 -cstopb -parenb raw -echo -hupcl 2>/dev/null; then
        log_warn "Could not configure ${port} with stty — skipping"
        return 1
    fi

    log_info "Probing ${port} (timeout=${AT_PROBE_TIMEOUT_S}s)…"

    # Send AT command and read response within timeout
    local response
    response=$(
        # Open port for read+write in a subshell
        exec 3<>"$port"
        # Send AT\r\n
        printf 'AT\r\n' >&3
        # Read with timeout
        timeout "$AT_PROBE_TIMEOUT_S" bash -c "
            while IFS= read -r -t ${AT_PROBE_TIMEOUT_S} line <&3; do
                echo \"\$line\"
            done
        " 3<>"$port" 2>/dev/null || true
        exec 3>&-
    ) 2>/dev/null || true

    if echo "$response" | grep -q "OK"; then
        log_info "AT port found: ${port}"
        return 0
    else
        log_debug "No OK from ${port}"
        return 1
    fi
}

##############################################################################
# Main
##############################################################################

main() {
    log_info "Starting AT-port discovery (timeout=${AT_PROBE_TIMEOUT_S}s per port)"

    mapfile -t candidates < <(discover_candidates)

    if [[ "${#candidates[@]}" -eq 0 || ( "${#candidates[@]}" -eq 1 && -z "${candidates[0]}" ) ]]; then
        log_error "No /dev/ttyUSB* devices found"
        exit 3
    fi

    log_info "Candidates: ${candidates[*]}"

    for port in "${candidates[@]}"; do
        [[ -z "$port" ]] && continue
        if probe_port "$port"; then
            echo "$port"
            exit 0
        fi
    done

    log_error "No AT port responded among candidates: ${candidates[*]}"
    exit 3
}

main "$@"
