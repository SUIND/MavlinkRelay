#!/usr/bin/env bash
# Collect full diagnostic snapshot for EC200U-CN LTE module troubleshooting
# Creates a tarball with journald logs, network state, USB info, and evidence files

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$REPO_ROOT/config/params.env"

DRY_RUN=0
TIMESTAMP=$(date +%s)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Create staging directory
STAGING_DIR="/tmp/lte-diag-${TIMESTAMP}"
if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$STAGING_DIR"
fi

# Collect diagnostics
if [[ "$DRY_RUN" -eq 0 ]]; then
    # Journalctl logs (24 hours)
    journalctl -u lte-watchdog -u lte-ecm-bootstrap -u lte-enum-guard --since "24 hours ago" --no-pager > "$STAGING_DIR/journald-24h.txt" 2>&1 || echo "Failed to collect journalctl logs" > "$STAGING_DIR/journald-24h.txt"
    
    # Network configuration
    ip addr > "$STAGING_DIR/ip-addr.txt" 2>&1
    ip route > "$STAGING_DIR/ip-route.txt" 2>&1
    networkctl status > "$STAGING_DIR/networkctl-status.txt" 2>&1 || echo "networkctl not available" > "$STAGING_DIR/networkctl-status.txt"
    
    # USB information
    lsusb > "$STAGING_DIR/lsusb.txt" 2>&1 || echo "lsusb not available" > "$STAGING_DIR/lsusb.txt"
    
    # Udevadm info for LTE0
    udevadm info --query=all --name=lte0 > "$STAGING_DIR/udevadm-lte0.txt" 2>&1 || echo "lte0 not present" > "$STAGING_DIR/udevadm-lte0.txt"
    
    # Dmesg relevant to LTE/USB
    dmesg | grep -E "(usb|cdc_ether|lte|2c7c)" | tail -200 > "$STAGING_DIR/dmesg-lte.txt" 2>&1 || echo "No matching dmesg entries" > "$STAGING_DIR/dmesg-lte.txt"
    
    # Copy watchdog state files if they exist
    if [[ -f /tmp/lte-watchdog-state ]]; then
        cp /tmp/lte-watchdog-state "$STAGING_DIR/" 2>/dev/null
    fi
    if [[ -f /tmp/lte-watchdog.lock ]]; then
        cp /tmp/lte-watchdog.lock "$STAGING_DIR/" 2>/dev/null
    fi
    
    # Copy evidence directory
    if [[ -d "$EVIDENCE_DIR" ]]; then
        mkdir -p "$STAGING_DIR/evidence"
        cp "$EVIDENCE_DIR"/*.txt "$STAGING_DIR/evidence/" 2>/dev/null
    fi
fi

# Create tarball
if [[ "$DRY_RUN" -eq 0 ]]; then
    tar -czf "/tmp/lte-diag-${TIMESTAMP}.tar.gz" -C /tmp "lte-diag-${TIMESTAMP}/" 2>/dev/null || {
        echo "Failed to create tarball" >&2
        rm -rf "$STAGING_DIR"
        exit 1
    }
    
    echo "Evidence pack: /tmp/lte-diag-${TIMESTAMP}.tar.gz" >&2
    
    # Clean up staging directory
    rm -rf "$STAGING_DIR"
else
    # Dry-run: list what would be collected
    echo "=== DRY-RUN: Would collect the following ===" >&2
    echo "Journalctl: lte-watchdog, lte-ecm-bootstrap, lte-enum-guard (24 hours)" >&2
    echo "Network: ip addr, ip route, networkctl status" >&2
    echo "USB: lsusb, udevadm lte0" >&2
    echo "Kernel: dmesg (usb|cdc_ether|lte|2c7c), last 200 lines" >&2
    echo "State files: /tmp/lte-watchdog-state, /tmp/lte-watchdog.lock (if present)" >&2
    echo "Evidence: $EVIDENCE_DIR/*.txt (if present)" >&2
    echo "Tarball: /tmp/lte-diag-${TIMESTAMP}.tar.gz" >&2
    echo "=== DRY-RUN: Complete ===" >&2
fi

exit 0
