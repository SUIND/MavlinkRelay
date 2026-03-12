#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARAMS_ENV="$REPO_ROOT/config/params.env"

_log() {
    local level="$1"
    shift
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] $*"
    echo "$line" >&2
    if [[ -n "${LTE_WATCHDOG_LOG_FILE:-}" ]]; then
        mkdir -p "$(dirname "$LTE_WATCHDOG_LOG_FILE")"
        printf '%s\n' "$line" >> "$LTE_WATCHDOG_LOG_FILE"
    fi
}

log_info()  { _log "INFO" "$@"; }
log_warn()  { _log "WARN" "$@"; }
log_error() { _log "ERROR" "$@"; }

if [[ -f "$PARAMS_ENV" ]]; then
    source "$PARAMS_ENV"
else
    log_error "Missing config file: $PARAMS_ENV"
    exit 2
fi

LTE_INTERFACE_NAME="${LTE_INTERFACE_NAME:-lte0}"
LTE_WATCHDOG_CHECK_INTERVAL_S="${LTE_WATCHDOG_CHECK_INTERVAL_S:-15}"
LTE_WATCHDOG_DEGRADED_INTERVAL_S="${LTE_WATCHDOG_DEGRADED_INTERVAL_S:-5}"
LTE_WATCHDOG_GRACE_CHECKS="${LTE_WATCHDOG_GRACE_CHECKS:-2}"
LTE_WATCHDOG_MAX_RECOVERY_LEVEL="${LTE_WATCHDOG_MAX_RECOVERY_LEVEL:-4}"

LTE_WATCHDOG_LOCKFILE="${LTE_WATCHDOG_LOCKFILE:-/tmp/lte-watchdog.pid}"
LTE_WATCHDOG_STATE_FILE="${LTE_WATCHDOG_STATE_FILE:-/tmp/lte-watchdog.state}"
LTE_WATCHDOG_ONE_SHOT="${LTE_WATCHDOG_ONE_SHOT:-0}"

RECOVERY_SCRIPT="${LTE_WATCHDOG_RECOVERY_SCRIPT:-$SCRIPT_DIR/lte-recovery.sh}"
FIND_AT_PORT_SCRIPT="$SCRIPT_DIR/find-at-port.sh"

STATE="HEALTHY"
DEGRADED_FAIL_COUNT=0
RECOVERY_LEVEL=1
LOCK_OWNED=0

cleanup() {
    if [[ "$LOCK_OWNED" -eq 1 && -f "$LTE_WATCHDOG_LOCKFILE" ]]; then
        local lock_pid
        lock_pid="$(<"$LTE_WATCHDOG_LOCKFILE")"
        if [[ "$lock_pid" == "$$" ]]; then
            rm -f "$LTE_WATCHDOG_LOCKFILE"
        fi
    fi
}

trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM

write_state_file() {
    mkdir -p "$(dirname "$LTE_WATCHDOG_STATE_FILE")"
    printf '%s\n' "$STATE" > "$LTE_WATCHDOG_STATE_FILE"
}

set_state() {
    local new_state="$1"
    local reason="$2"
    local old_state="$STATE"
    if [[ "$new_state" != "$old_state" ]]; then
        STATE="$new_state"
        log_info "STATE ${old_state} -> ${new_state}: ${reason}"
        write_state_file
    else
        write_state_file
    fi
}

acquire_lock() {
    mkdir -p "$(dirname "$LTE_WATCHDOG_LOCKFILE")"

    if [[ -f "$LTE_WATCHDOG_LOCKFILE" ]]; then
        local existing_pid
        existing_pid="$(<"$LTE_WATCHDOG_LOCKFILE")"
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            log_error "Another watchdog instance is running with PID ${existing_pid}; exiting"
            exit 1
        fi
        log_warn "Stale lockfile detected at ${LTE_WATCHDOG_LOCKFILE}; removing"
        rm -f "$LTE_WATCHDOG_LOCKFILE"
    fi

    printf '%s\n' "$$" > "$LTE_WATCHDOG_LOCKFILE"
    LOCK_OWNED=1
    log_info "Acquired singleton lock: ${LTE_WATCHDOG_LOCKFILE} (pid=$$)"
}

is_registered_stat() {
    local stat="$1"
    [[ "$stat" == "1" || "$stat" == "5" ]]
}

get_iface_up() {
    if [[ "${LTE_WATCHDOG_MOCK_MODE:-0}" == "1" && -n "${LTE_WATCHDOG_MOCK_IFACE_UP:-}" ]]; then
        [[ "${LTE_WATCHDOG_MOCK_IFACE_UP}" == "1" ]] && return 0
        return 1
    fi

    local link_output
    link_output="$(ip link show "$LTE_INTERFACE_NAME" 2>/dev/null || true)"
    [[ -n "$link_output" ]] || return 1
    if [[ "$link_output" == *"state UP"* ]] || printf '%s' "$link_output" | grep -q '<[^>]*UP[^>]*>'; then
        return 0
    fi
    return 1
}

get_ipv4_addr() {
    if [[ "${LTE_WATCHDOG_MOCK_MODE:-0}" == "1" && "${LTE_WATCHDOG_MOCK_IP+x}" == "x" ]]; then
        printf '%s\n' "${LTE_WATCHDOG_MOCK_IP}"
        return 0
    fi

    local raw_ip
    raw_ip="$(ip -4 -o addr show dev "$LTE_INTERFACE_NAME" scope global 2>/dev/null | awk 'NR==1{print $4}' || true)"
    if [[ -z "$raw_ip" ]]; then
        printf '\n'
        return 0
    fi
    printf '%s\n' "${raw_ip%%/*}"
}

dns_probe_ok() {
    local bind_ip="$1"

    if [[ "${LTE_WATCHDOG_MOCK_MODE:-0}" == "1" && -n "${LTE_WATCHDOG_MOCK_DNS:-}" ]]; then
        [[ "${LTE_WATCHDOG_MOCK_DNS}" == "1" ]] && return 0
        return 1
    fi

    [[ -n "$bind_ip" ]] || return 1
    local dns_output
    dns_output="$(dig +short +timeout=3 -b "$bind_ip" google.com @8.8.8.8 2>/dev/null || true)"
    [[ -n "$dns_output" ]]
}

get_reg_stat() {
    if [[ "${LTE_WATCHDOG_MOCK_MODE:-0}" == "1" && -n "${LTE_WATCHDOG_MOCK_REG_STAT:-}" ]]; then
        printf '%s\n' "${LTE_WATCHDOG_MOCK_REG_STAT}"
        return 0
    fi

    if [[ ! -x "$FIND_AT_PORT_SCRIPT" ]]; then
        log_warn "AT discovery script not executable: $FIND_AT_PORT_SCRIPT"
        return 1
    fi

    local at_port
    at_port="$($FIND_AT_PORT_SCRIPT 2>/dev/null || true)"
    if [[ -z "$at_port" ]]; then
        log_warn "AT port discovery failed"
        return 1
    fi

    local response
    response="$({
        printf 'AT+CEREG?\r\n' > "$at_port"
        timeout 3 cat "$at_port" || true
    } 2>/dev/null || true)"

    local cereg_line
    cereg_line="$(printf '%s\n' "$response" | grep -m1 '\+CEREG:' || true)"
    [[ -n "$cereg_line" ]] || return 1

    local stat
    stat="$(printf '%s' "$cereg_line" | grep -oE '[0-9]+' | tail -n1 || true)"
    [[ -n "$stat" ]] || return 1
    printf '%s\n' "$stat"
}

health_check() {
    HEALTH_IFACE_UP=0
    HEALTH_IP_ADDR=""
    HEALTH_DNS_OK=0

    if get_iface_up; then
        HEALTH_IFACE_UP=1
    else
        return 1
    fi

    HEALTH_IP_ADDR="$(get_ipv4_addr)"
    if [[ -z "$HEALTH_IP_ADDR" ]]; then
        return 1
    fi

    if dns_probe_ok "$HEALTH_IP_ADDR"; then
        HEALTH_DNS_OK=1
        return 0
    fi

    return 1
}

move_to_no_coverage_if_needed() {
    local reg_stat
    reg_stat="$(get_reg_stat || true)"
    if [[ -n "$reg_stat" ]] && ! is_registered_stat "$reg_stat"; then
        set_state "NO_COVERAGE" "CEREG stat=${reg_stat}; waiting for network coverage"
        return 0
    fi
    return 1
}

run_recovery_level() {
    local level="$1"

    if [[ ! -x "$RECOVERY_SCRIPT" ]]; then
        log_warn "recovery script not found: $RECOVERY_SCRIPT"
        RECOVERY_LEVEL=$((RECOVERY_LEVEL + 1))
        return 1
    fi

    log_warn "Invoking recovery hook: $RECOVERY_SCRIPT --level $level"
    if "$RECOVERY_SCRIPT" --level "$level"; then
        return 0
    fi
    return 1
}

main() {
    acquire_lock
    write_state_file
    log_info "LTE watchdog started for interface ${LTE_INTERFACE_NAME}"

    while true; do
        local health_ok=0
        if health_check; then
            health_ok=1
        fi

        case "$STATE" in
            HEALTHY)
                if [[ "$health_ok" -eq 1 ]]; then
                    :
                else
                    DEGRADED_FAIL_COUNT=1
                    set_state "DEGRADED" "health failure detected (interface/IP/DNS)"
                    move_to_no_coverage_if_needed || true
                fi
                ;;

            DEGRADED)
                if [[ "$health_ok" -eq 1 ]]; then
                    DEGRADED_FAIL_COUNT=0
                    RECOVERY_LEVEL=1
                    set_state "HEALTHY" "all health layers recovered"
                else
                    if move_to_no_coverage_if_needed; then
                        DEGRADED_FAIL_COUNT=0
                    else
                        DEGRADED_FAIL_COUNT=$((DEGRADED_FAIL_COUNT + 1))
                        if [[ "$DEGRADED_FAIL_COUNT" -ge "$LTE_WATCHDOG_GRACE_CHECKS" ]]; then
                            set_state "RECOVERING" "consecutive degraded checks=${DEGRADED_FAIL_COUNT}"
                        fi
                    fi
                fi
                ;;

            NO_COVERAGE)
                if [[ "$health_ok" -eq 1 ]]; then
                    DEGRADED_FAIL_COUNT=0
                    RECOVERY_LEVEL=1
                    set_state "HEALTHY" "coverage and connectivity restored"
                else
                    local reg_stat
                    reg_stat="$(get_reg_stat || true)"
                    if [[ -n "$reg_stat" ]] && is_registered_stat "$reg_stat"; then
                        set_state "DEGRADED" "registration recovered (CEREG stat=${reg_stat}) but health still failing"
                    else
                        log_warn "waiting for network coverage"
                        write_state_file
                    fi
                fi
                ;;

            RECOVERING)
                if [[ "$health_ok" -eq 1 ]]; then
                    DEGRADED_FAIL_COUNT=0
                    RECOVERY_LEVEL=1
                    set_state "HEALTHY" "recovered during recovery loop"
                else
                    if move_to_no_coverage_if_needed; then
                        :
                    else
                        if run_recovery_level "$RECOVERY_LEVEL"; then
                            if health_check; then
                                DEGRADED_FAIL_COUNT=0
                                RECOVERY_LEVEL=1
                                set_state "HEALTHY" "recovery hook succeeded and health checks passed"
                            else
                                RECOVERY_LEVEL=$((RECOVERY_LEVEL + 1))
                            fi
                        else
                            if [[ -x "$RECOVERY_SCRIPT" ]]; then
                                RECOVERY_LEVEL=$((RECOVERY_LEVEL + 1))
                            fi
                        fi

                        if [[ -x "$RECOVERY_SCRIPT" && "$RECOVERY_LEVEL" -gt "$LTE_WATCHDOG_MAX_RECOVERY_LEVEL" ]]; then
                            set_state "FAILED" "all recovery levels exhausted"
                        fi
                    fi
                fi
                ;;

            FAILED)
                log_error "watchdog entering FAILED state — operator intervention required"
                write_state_file
                exit 0
                ;;

            *)
                log_error "Unknown state: $STATE"
                exit 1
                ;;
        esac

        if [[ "$STATE" == "FAILED" ]]; then
            log_error "watchdog entering FAILED state — operator intervention required"
            write_state_file
            exit 0
        fi

        if [[ "$LTE_WATCHDOG_ONE_SHOT" == "1" ]]; then
            exit 0
        fi

        case "$STATE" in
            HEALTHY)
                sleep "$LTE_WATCHDOG_CHECK_INTERVAL_S"
                ;;
            *)
                sleep "$LTE_WATCHDOG_DEGRADED_INTERVAL_S"
                ;;
        esac
    done
}

main "$@"
