#!/usr/bin/env bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
ASSUME_YES=0

REMOVED_COUNT=0
ERROR_COUNT=0

FILES=(
  "/etc/udev/rules.d/99-ec200u-lte.rules"
  "/etc/systemd/network/10-lte0.link"
  "/etc/systemd/network/20-lte0.network"
  "/etc/systemd/network/10-eth0.network"
  "/etc/systemd/network/10-eth1.network"
  "/etc/systemd/system/lte-enum-guard.service"
  "/etc/systemd/system/lte-ecm-bootstrap.service"
  "/etc/systemd/system/lte-watchdog.service"
  "/usr/local/lib/lte-module/find-at-port.sh"
  "/usr/local/lib/lte-module/ecm-bootstrap.sh"
  "/usr/local/lib/lte-module/lte-enum-guard.sh"
  "/usr/local/lib/lte-module/lte-watchdog.sh"
  "/usr/local/lib/lte-module/lte-recovery.sh"
  "/usr/local/lib/lte-module/check-apn.sh"
  "/usr/local/lib/lte-module/lte-evidence-pack.sh"
  "/etc/lte-module/params.env"
  "/etc/logrotate.d/lte-watchdog"
)

usage() {
  echo "Usage: $0 [--dry-run] [--yes]"
}

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

run_cmd() {
  local tolerate_fail="$1"
  shift

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log INFO "(dry-run) Would run: $*"
    return 0
  fi

  "$@"
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ "$tolerate_fail" -eq 1 ]]; then
      log WARN "Command failed (tolerated, rc=${rc}): $*"
      return 0
    fi
    log ERROR "Command failed (rc=${rc}): $*"
    ERROR_COUNT=$((ERROR_COUNT + 1))
    return $rc
  fi
  return 0
}

remove_file_if_present() {
  local dst="$1"

  if [[ -f "$dst" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log INFO "(dry-run) Would remove: ${dst}"
      REMOVED_COUNT=$((REMOVED_COUNT + 1))
      return 0
    fi

    if rm -f "$dst"; then
      log INFO "Removed: ${dst}"
      REMOVED_COUNT=$((REMOVED_COUNT + 1))
      return 0
    fi

    log ERROR "Failed to remove: ${dst}"
    ERROR_COUNT=$((ERROR_COUNT + 1))
    return 1
  fi

  log INFO "Not present (skip): ${dst}"
  return 0
}

print_summary() {
  echo ""
  echo "Uninstall plan (${#FILES[@]} files):"
  for dst in "${FILES[@]}"; do
    printf '  - remove %s\n' "$dst"
  done
  echo ""
}

confirm_or_abort() {
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi

  print_summary
  read -r -p "Proceed? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES)
      return 0
      ;;
    *)
      log WARN "Uninstall aborted by user"
      exit 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log ERROR "Unknown option: $1"
      usage
      exit 2
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  log ERROR "Must run as root"
  exit 5
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log INFO "DRY RUN mode enabled: no system changes will be made"
fi

confirm_or_abort

run_cmd 1 systemctl stop lte-watchdog.service lte-ecm-bootstrap.service lte-enum-guard.service
run_cmd 1 systemctl disable lte-watchdog.service lte-ecm-bootstrap.service lte-enum-guard.service
run_cmd 1 systemctl unmask nv-l4t-usb-device-mode

for dst in "${FILES[@]}"; do
  remove_file_if_present "$dst"
done

run_cmd 1 rmdir --ignore-fail-on-non-empty /usr/local/lib/lte-module
run_cmd 1 rmdir --ignore-fail-on-non-empty /etc/lte-module

run_cmd 0 systemctl daemon-reload
run_cmd 0 udevadm control --reload-rules

if [[ "$ERROR_COUNT" -gt 0 ]]; then
  log ERROR "Uninstall finished with ${ERROR_COUNT} error(s)"
  exit 1
fi

echo "Uninstall complete: ${REMOVED_COUNT} file(s) removed"
exit 0
