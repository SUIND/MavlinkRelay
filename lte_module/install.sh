#!/usr/bin/env bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=0
ASSUME_YES=0
LTE_APN_ARG=""

INSTALLED_COUNT=0
BACKUP_COUNT=0
ERROR_COUNT=0

FILES=(
  "rules/99-ec200u-lte.rules:/etc/udev/rules.d/99-ec200u-lte.rules"
  "network/10-lte0.link:/etc/systemd/network/10-lte0.link"
  "network/20-lte0.network:/etc/systemd/network/20-lte0.network"
  "network/10-eth0.network:/etc/systemd/network/10-eth0.network"
  "network/10-eth1.network:/etc/systemd/network/10-eth1.network"
  "units/lte-enum-guard.service:/etc/systemd/system/lte-enum-guard.service"
  "units/lte-ecm-bootstrap.service:/etc/systemd/system/lte-ecm-bootstrap.service"
  "units/lte-watchdog.service:/etc/systemd/system/lte-watchdog.service"
  "scripts/find-at-port.sh:/usr/local/lib/lte-module/find-at-port.sh"
  "scripts/ecm-bootstrap.sh:/usr/local/lib/lte-module/ecm-bootstrap.sh"
  "scripts/lte-enum-guard.sh:/usr/local/lib/lte-module/lte-enum-guard.sh"
  "scripts/lte-watchdog.sh:/usr/local/lib/lte-module/lte-watchdog.sh"
  "scripts/lte-recovery.sh:/usr/local/lib/lte-module/lte-recovery.sh"
  "scripts/check-apn.sh:/usr/local/lib/lte-module/check-apn.sh"
  "scripts/lte-evidence-pack.sh:/usr/local/lib/lte-module/lte-evidence-pack.sh"
  "config/params.env:/etc/lte-module/params.env"
  "config/lte-watchdog-logrotate:/etc/logrotate.d/lte-watchdog"
  "config/ec200u-lte.modules:/etc/modules-load.d/ec200u-lte.conf"
)

usage() {
  echo "Usage: $0 [--dry-run] [--yes] [--apn <apn>]"
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

copy_with_backup() {
  local rel_src="$1"
  local dst="$2"
  local src="${REPO_ROOT}/${rel_src}"

  if [[ ! -f "$src" ]]; then
    log ERROR "Missing source file: ${src}"
    ERROR_COUNT=$((ERROR_COUNT + 1))
    return 1
  fi

  if [[ -f "$dst" ]] && ! cmp -s "$src" "$dst"; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log INFO "(dry-run) Would back up changed file: ${dst} -> ${dst}.bak"
    else
      if cp -f "$dst" "${dst}.bak"; then
        log INFO "Backed up existing file: ${dst}.bak"
        BACKUP_COUNT=$((BACKUP_COUNT + 1))
      else
        log ERROR "Failed to back up file: ${dst}"
        ERROR_COUNT=$((ERROR_COUNT + 1))
      fi
    fi
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log INFO "(dry-run) Would install: ${src} -> ${dst}"
    INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    return 0
  fi

  if cp -f "$src" "$dst"; then
    log INFO "Installed: ${dst}"
    INSTALLED_COUNT=$((INSTALLED_COUNT + 1))
    return 0
  fi

  log ERROR "Failed to install: ${src} -> ${dst}"
  ERROR_COUNT=$((ERROR_COUNT + 1))
  return 1
}

print_summary() {
  echo ""
  echo "Install plan (${#FILES[@]} files):"
  for entry in "${FILES[@]}"; do
    local rel_src="${entry%%:*}"
    local dst="${entry#*:}"
    printf '  - %s -> %s\n' "${REPO_ROOT}/${rel_src}" "$dst"
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
      log WARN "Installation aborted by user"
      exit 1
      ;;
  esac
}


detect_modem_mac() {
  local iface_path
  for iface_path in /sys/class/net/*/; do
    local device_path
    device_path=$(readlink -f "${iface_path}device" 2>/dev/null) || continue
    local check_path="$device_path"
    local _i
    for _i in 1 2 3; do
      check_path=$(dirname "$check_path")
      local vid pid
      vid=$(cat "${check_path}/idVendor" 2>/dev/null || true)
      pid=$(cat "${check_path}/idProduct" 2>/dev/null || true)
      if [[ "$vid" == "2c7c" && "$pid" == "0901" ]]; then
        cat "${iface_path}address" 2>/dev/null
        return 0
      fi
    done
  done
  return 1
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
    --apn)
      if [[ $# -lt 2 ]]; then
        log ERROR "--apn requires an argument"
        usage
        exit 2
      fi
      LTE_APN_ARG="$2"
      shift 2
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

run_cmd 0 mkdir -p /usr/local/lib/lte-module
run_cmd 0 mkdir -p /etc/lte-module
run_cmd 0 mkdir -p /etc/modules-load.d

for entry in "${FILES[@]}"; do
  rel_src="${entry%%:*}"
  dst="${entry#*:}"
  copy_with_backup "$rel_src" "$dst"
done

if [[ -n "$LTE_APN_ARG" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log INFO "(dry-run) Would append: LTE_APN=\"${LTE_APN_ARG}\" to /etc/lte-module/params.env"
  else
    printf 'LTE_APN="%s"\n' "$LTE_APN_ARG" >> /etc/lte-module/params.env
    log INFO "Set LTE_APN=\"${LTE_APN_ARG}\" in /etc/lte-module/params.env"
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log INFO "(dry-run) Would detect modem MAC and patch /etc/systemd/network/10-lte0.link"
else
  detected_mac=""
  detected_mac=$(detect_modem_mac || true)
  if [[ -n "$detected_mac" ]]; then
    log INFO "Detected modem MAC: ${detected_mac}"
    sed -i "s/__MODEM_MAC__/${detected_mac}/g" /etc/systemd/network/10-lte0.link
    log INFO "Patched /etc/systemd/network/10-lte0.link with MAC ${detected_mac}"
  else
    log WARN "Modem not detected in sysfs — /etc/systemd/network/10-lte0.link still contains __MODEM_MAC__ placeholder"
    log WARN "Connect the modem and re-run install.sh to complete MAC detection"
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  log INFO "(dry-run) Would run: chmod +x /usr/local/lib/lte-module/*.sh"
else
  for script in /usr/local/lib/lte-module/*.sh; do
    if [[ -f "$script" ]]; then
      if chmod +x "$script"; then
        log INFO "Set executable: $script"
      else
        log ERROR "Failed to chmod +x: $script"
        ERROR_COUNT=$((ERROR_COUNT + 1))
      fi
    fi
  done
fi

run_cmd 1 systemctl mask --now nv-l4t-usb-device-mode
run_cmd 0 systemctl daemon-reload
run_cmd 0 udevadm control --reload-rules
run_cmd 0 udevadm trigger
run_cmd 0 systemctl enable --now lte-enum-guard.service
run_cmd 0 systemctl enable --now lte-ecm-bootstrap.service
run_cmd 0 systemctl enable --now lte-watchdog.service

if [[ "$ERROR_COUNT" -gt 0 ]]; then
  log ERROR "Installation finished with ${ERROR_COUNT} error(s)"
  exit 1
fi

echo "Installation complete: ${INSTALLED_COUNT} file(s) installed, ${BACKUP_COUNT} backup(s) created"
exit 0
