#!/usr/bin/env bash
# lte-recovery.sh — Staged recovery executor for LTE modem (L1–L4)
#
# Called by the watchdog as: lte-recovery.sh --level N
#
# Recovery ladder:
#   L1: DHCP renew via networkctl renew lte0                      (grace: 10s)
#   L2: Link bounce (ip link down/up) + DHCP trigger              (grace: 15s)
#   L3: USB rebind via cdc_ether unbind/bind (dynamic sysfs path) (grace: 30s)
#   L4: AT modem reset via AT+CFUN=1,1 + wait for re-enumeration  (grace: 30s)
#
# HARD GUARDRAIL: NO host reboot — ever. Recovery stops at Level 4.
#
# Usage:
#   lte-recovery.sh --level N [--dry-run] [--mock-port PATH]
#
# Options:
#   --level N        Recovery level (required): 1, 2, 3, or 4
#   --dry-run        Log intent without executing commands; exit 0
#   --mock-port PATH Use PATH as AT port for L4 (skips find-at-port.sh; for testing)
#
# Exit codes:
#   0  Success
#   1  General/hardware failure (recovery action failed)
#   2  Config error (--level missing or invalid)
#
# Sources: config/params.env

set -uo pipefail

##############################################################################
# Resolve paths
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARAMS_ENV="$REPO_ROOT/config/params.env"
[[ -f "/etc/lte-module/params.env" ]] && PARAMS_ENV="/etc/lte-module/params.env"

##############################################################################
# Logging — all output to stderr (CONVENTIONS.md §2.1)
##############################################################################

_log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*" >&2
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@"; }
log_debug() { _log "DEBUG" "$@"; }

##############################################################################
# Argument parsing
##############################################################################

RECOVERY_LEVEL=""
DRY_RUN=false
MOCK_PORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --level)
            if [[ $# -lt 2 ]]; then
                log_error "--level requires an argument (1-4)"
                exit 2
            fi
            RECOVERY_LEVEL="$2"
            shift 2
            ;;
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

# Validate --level: required and must be in {1,2,3,4}
if [[ -z "$RECOVERY_LEVEL" ]]; then
    log_error "--level is required (use --level 1, 2, 3, or 4)"
    exit 2
fi

case "$RECOVERY_LEVEL" in
    1|2|3|4) ;;  # valid
    *)
        log_error "Invalid --level '${RECOVERY_LEVEL}': must be 1, 2, 3, or 4"
        exit 2
        ;;
esac

##############################################################################
# Source deployment parameters
##############################################################################

if [[ ! -f "$PARAMS_ENV" ]]; then
    log_error "params.env not found: $PARAMS_ENV"
    exit 2
fi
# shellcheck source=../config/params.env
source "$PARAMS_ENV"

# Defaults for params that may be absent in older params.env
LTE_INTERFACE_NAME="${LTE_INTERFACE_NAME:-lte0}"
LTE_MODEM_VID_PID="${LTE_MODEM_VID_PID:-2c7c:0901}"
ECM_REENUM_TIMEOUT_S="${ECM_REENUM_TIMEOUT_S:-30}"
LTE_USB_DRIVER="${LTE_USB_DRIVER:-cdc_ether}"

##############################################################################
# Helper: wait for IPv4 address on interface
##############################################################################

wait_for_ip() {
    local iface="$1"
    local timeout_s="${2:-10}"
    local elapsed=0

    log_info "Waiting up to ${timeout_s}s for IPv4 on ${iface} ..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would poll: ip -4 addr show ${iface} | grep inet (up to ${timeout_s}s)"
        return 0
    fi

    while [[ "$elapsed" -lt "$timeout_s" ]]; do
        if ip -4 addr show "$iface" 2>/dev/null | grep -q 'inet '; then
            log_info "${iface} has IPv4 after ${elapsed}s"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    log_error "${iface} did not get IPv4 within ${timeout_s}s"
    return 1
}

##############################################################################
# Helper: wait for interface to appear (link level)
##############################################################################

wait_for_link() {
    local iface="$1"
    local timeout_s="${2:-30}"
    local elapsed=0

    log_info "Waiting up to ${timeout_s}s for interface ${iface} to appear ..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would poll: ip link show ${iface} (up to ${timeout_s}s)"
        return 0
    fi

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

##############################################################################
# Helper: wait for modem USB re-enumeration
##############################################################################

wait_for_reenum() {
    local vid_pid="$1"
    local timeout_s="${2:-30}"
    local elapsed=0

    log_info "Waiting up to ${timeout_s}s for modem re-enumeration (VID:PID ${vid_pid}) ..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "(dry-run) Would poll: lsusb -d ${vid_pid} (up to ${timeout_s}s)"
        return 0
    fi

    while [[ "$elapsed" -lt "$timeout_s" ]]; do
        if lsusb -d "$vid_pid" &>/dev/null; then
            log_info "Modem re-enumerated on USB after ${elapsed}s"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    log_error "Modem did NOT re-enumerate within ${timeout_s}s (VID:PID ${vid_pid})"
    return 1
}

##############################################################################
# Level 1: DHCP renew
##############################################################################

recover_l1() {
    log_info "L1: DHCP renew on ${LTE_INTERFACE_NAME}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "L1: would run: networkctl renew ${LTE_INTERFACE_NAME}"
        exit 0
    fi

    if networkctl renew "$LTE_INTERFACE_NAME" 2>/dev/null; then
        log_info "L1: DHCP renew succeeded"
        sleep 10
        exit 0
    else
        log_error "L1: DHCP renew failed"
        exit 1
    fi
}

##############################################################################
# Level 2: Link bounce + DHCP trigger
##############################################################################

recover_l2() {
    log_info "L2: Link bounce on ${LTE_INTERFACE_NAME}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "L2: would run: ip link set ${LTE_INTERFACE_NAME} down; sleep 2; ip link set ${LTE_INTERFACE_NAME} up; networkctl renew ${LTE_INTERFACE_NAME}"
        exit 0
    fi

    log_info "L2: bringing ${LTE_INTERFACE_NAME} down"
    if ! ip link set "$LTE_INTERFACE_NAME" down 2>/dev/null; then
        log_error "L2: failed to bring ${LTE_INTERFACE_NAME} down"
        exit 1
    fi

    sleep 2

    log_info "L2: bringing ${LTE_INTERFACE_NAME} up"
    if ! ip link set "$LTE_INTERFACE_NAME" up 2>/dev/null; then
        log_error "L2: failed to bring ${LTE_INTERFACE_NAME} up"
        exit 1
    fi

    log_info "L2: triggering DHCP renew"
    networkctl renew "$LTE_INTERFACE_NAME" 2>/dev/null || true

    if wait_for_ip "$LTE_INTERFACE_NAME" 10; then
        log_info "L2: link bounce succeeded — IPv4 assigned"
        sleep 15
        exit 0
    else
        log_error "L2: link bounce failed — no IPv4 after bounce"
        exit 1
    fi
}

##############################################################################
# Level 3: USB rebind (dynamic sysfs path — NO hardcoded paths)
##############################################################################

recover_l3() {
    log_info "L3: USB rebind for ${LTE_INTERFACE_NAME} via ${LTE_USB_DRIVER}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "L3: would unbind/rebind USB interface for ${LTE_INTERFACE_NAME} via /sys/bus/usb/drivers/${LTE_USB_DRIVER}"
        exit 0
    fi

    # Derive the USB interface device ID dynamically from the net device sysfs tree.
    # Walk: /sys/class/net/lte0/device  ->  (USB interface node, e.g. 1-1.1:1.0)
    # The interface node is the direct parent of the net device's sysfs directory.
    # Pattern:
    #   /sys/class/net/lte0/device/../../../  = USB device node (e.g. 1-1.1)
    # We need the interface node: /sys/class/net/lte0/device  (the USB interface, e.g. 1-1.1:1.0)
    local net_dev_path
    net_dev_path="$(readlink -f "/sys/class/net/${LTE_INTERFACE_NAME}/device" 2>/dev/null || true)"

    if [[ -z "$net_dev_path" ]]; then
        log_error "L3: cannot resolve sysfs path for ${LTE_INTERFACE_NAME} — interface may not exist"
        exit 1
    fi

    log_debug "L3: net device sysfs path: ${net_dev_path}"

    # Extract the interface device basename (e.g. "1-1.1:1.0") from the sysfs path
    local usb_interface_id
    usb_interface_id="$(basename "$net_dev_path")"

    if [[ -z "$usb_interface_id" ]]; then
        log_error "L3: could not extract USB interface ID from sysfs path: ${net_dev_path}"
        exit 1
    fi

    log_info "L3: USB interface ID: ${usb_interface_id}"

    local driver_path="/sys/bus/usb/drivers/${LTE_USB_DRIVER}"

    # Verify driver bind path exists
    if [[ ! -d "$driver_path" ]]; then
        log_error "L3: USB driver path not found: ${driver_path}"
        exit 1
    fi

    # Unbind
    log_info "L3: unbinding ${usb_interface_id} from ${LTE_USB_DRIVER}"
    if ! echo "$usb_interface_id" > "${driver_path}/unbind" 2>/dev/null; then
        log_error "L3: failed to unbind ${usb_interface_id}"
        exit 1
    fi

    sleep 2

    # Bind
    log_info "L3: binding ${usb_interface_id} to ${LTE_USB_DRIVER}"
    if ! echo "$usb_interface_id" > "${driver_path}/bind" 2>/dev/null; then
        log_error "L3: failed to bind ${usb_interface_id}"
        exit 1
    fi

    if wait_for_link "$LTE_INTERFACE_NAME" 30; then
        log_info "L3: USB rebind succeeded — ${LTE_INTERFACE_NAME} reappeared"
        sleep 30
        exit 0
    else
        log_error "L3: USB rebind failed — ${LTE_INTERFACE_NAME} did not reappear"
        exit 1
    fi
}

##############################################################################
# Level 4: AT modem reset (AT+CFUN=1,1) + re-enumeration wait
##############################################################################

recover_l4() {
    log_info "L4: AT modem reset via AT+CFUN=1,1"

    local find_at_port="$SCRIPT_DIR/find-at-port.sh"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "L4: would discover AT port via ${find_at_port}"
        log_info "L4: would send: AT+CFUN=1,1 to discovered AT port"
        log_info "L4: would wait up to ${ECM_REENUM_TIMEOUT_S}s for modem re-enumeration (VID:PID ${LTE_MODEM_VID_PID})"
        log_info "L4: would wait for ${LTE_INTERFACE_NAME} to reappear"
        exit 0
    fi

    # Discover AT port — use --mock-port if provided (for unit testing)
    local at_port=""
    if [[ -n "$MOCK_PORT" ]]; then
        log_info "L4: using mock port: ${MOCK_PORT}"
        at_port="$MOCK_PORT"
    else
        if [[ ! -x "$find_at_port" ]]; then
            log_error "L4: find-at-port.sh not found or not executable: ${find_at_port}"
            exit 1
        fi
        log_info "L4: discovering AT port via ${find_at_port}"
        at_port="$("$find_at_port" 2>/dev/null || true)"
        if [[ -z "$at_port" ]]; then
            log_error "L4: find-at-port.sh returned empty — AT port not found"
            exit 1
        fi
        log_info "L4: AT port discovered: ${at_port}"
    fi

    # Send AT+CFUN=1,1 — full modem reset
    # Modem may drop connection before ACKing; use || true
    log_info "L4: sending AT+CFUN=1,1 to ${at_port}"
    {
        exec 3<>"$at_port"
        printf 'AT+CFUN=1,1\r\n' >&3
        timeout 3 bash -c "
            while IFS= read -r -t 3 line <&3; do
                echo \"\$line\"
            done
        " 3<>"$at_port" 2>/dev/null || true
        exec 3>&-
    } 2>/dev/null || true

    log_info "L4: modem reset command sent — awaiting USB re-enumeration ..."

    # Wait for modem to re-enumerate on USB bus
    if ! wait_for_reenum "$LTE_MODEM_VID_PID" "$ECM_REENUM_TIMEOUT_S"; then
        log_error "L4: modem failed to re-enumerate after reset"
        exit 1
    fi

    # Allow OS time to re-bind cdc_ether driver and recreate ttyUSB nodes
    log_info "L4: sleeping 3s for driver re-bind ..."
    sleep 3

    # Wait for lte0 to reappear
    if wait_for_link "$LTE_INTERFACE_NAME" 30; then
        log_info "L4: AT modem reset succeeded — ${LTE_INTERFACE_NAME} reappeared"
        sleep 30
        exit 0
    else
        log_error "L4: ${LTE_INTERFACE_NAME} did not reappear after modem reset"
        exit 1
    fi
}

##############################################################################
# Main dispatch
##############################################################################

log_info "=== LTE Recovery starting: level=${RECOVERY_LEVEL} dry_run=${DRY_RUN} ==="

case "$RECOVERY_LEVEL" in
    1) recover_l1 ;;
    2) recover_l2 ;;
    3) recover_l3 ;;
    4) recover_l4 ;;
esac
