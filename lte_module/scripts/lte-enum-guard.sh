#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PARAMS_FILE="$REPO_ROOT/config/params.env"
[[ -f "/etc/lte-module/params.env" ]] && PARAMS_FILE="/etc/lte-module/params.env"
DRY_RUN=0

log() {
    local level="$1"
    shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

fail() {
    local code="$1"
    shift
    log ERROR "$*"
    exit "$code"
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=1
            ;;
        *)
            fail 1 "Unsupported argument: $arg"
            ;;
    esac
done

[ -f "$PARAMS_FILE" ] || fail 2 "Configuration file not found: $PARAMS_FILE"
# shellcheck source=config/params.env
source "$PARAMS_FILE"

[ -n "${LTE_MODEM_VID_PID:-}" ] || fail 2 "LTE_MODEM_VID_PID is not set in config/params.env"

MAX_RETRIES="${ENUM_GUARD_MAX_RETRIES:-5}"
RETRY_DELAY="${ENUM_GUARD_RETRY_DELAY:-2}"

case "$MAX_RETRIES" in
    ''|*[!0-9]*)
        fail 2 "ENUM_GUARD_MAX_RETRIES must be a positive integer"
        ;;
    0)
        fail 2 "ENUM_GUARD_MAX_RETRIES must be greater than 0"
        ;;
esac

case "$RETRY_DELAY" in
    ''|*[!0-9]*)
        fail 2 "ENUM_GUARD_RETRY_DELAY must be a non-negative integer"
        ;;
esac

command -v lsusb >/dev/null 2>&1 || fail 1 "Required command not found: lsusb"

if [ "$DRY_RUN" -eq 1 ]; then
    log INFO "(dry-run) Would run: systemctl mask --now nv-l4t-usb-device-mode"
else
    log INFO "Masking nv-l4t-usb-device-mode as a precautionary step"
    command -v systemctl >/dev/null 2>&1 || fail 1 "Required command not found: systemctl"
    systemctl mask --now nv-l4t-usb-device-mode >/dev/null 2>&1 || fail 1 "Failed to mask nv-l4t-usb-device-mode"
    log INFO "Masked nv-l4t-usb-device-mode"
fi

attempt=1
while [ "$attempt" -le "$MAX_RETRIES" ]; do
    log INFO "Checking for LTE modem VID:PID $LTE_MODEM_VID_PID (attempt $attempt/$MAX_RETRIES)"

    if lsusb -d "$LTE_MODEM_VID_PID" >/dev/null 2>&1; then
        log INFO "Detected LTE modem VID:PID $LTE_MODEM_VID_PID on USB host bus"
        exit 0
    fi

    if [ "$attempt" -lt "$MAX_RETRIES" ]; then
        log INFO "LTE modem VID:PID $LTE_MODEM_VID_PID not found; retrying in ${RETRY_DELAY}s"
        sleep "$RETRY_DELAY"
    fi

    attempt=$((attempt + 1))
done

fail 3 "LTE modem VID:PID $LTE_MODEM_VID_PID not found after $MAX_RETRIES attempts"
