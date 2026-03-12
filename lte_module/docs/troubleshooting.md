## EC200U-CN on Jetson Xavier NX — Field Troubleshooting Guide

Purpose: practical, command-first troubleshooting for the Quectel EC200U-CN modem on Jetson Xavier NX. Use this guide at the vehicle site. Follow the hard guardrail: do NOT recommend host-level reboot or shutdown as any recovery action. When uncertain, collect an evidence pack and escalate to support.

Conventions used here:
- Watchdog states are referenced by name: HEALTHY, DEGRADED, RECOVERING, NO_COVERAGE, FAILED
- Commands shown in code blocks; copy-paste safe
- All AT interactions must use `scripts/find-at-port.sh` to discover the AT port dynamically
- Evidence directory: `.sisyphus/evidence`

Table of contents

1. Modem not enumerating
2. lte0 has no IP address
3. Connected but no data
4. Watchdog stuck in RECOVERING
5. Watchdog in NO_COVERAGE state
6. Ethernet not preferred over LTE
7. QUIC sessions dropping

---

## Quick-reference command table

| Symptom | First command | Where to look |
|---|---:|---|
| Modem not enumerating | ```bash
| lsusb -d 2c7c:0901
| ``` | dmesg, `systemctl status lte-enum-guard` |
| lte0 has no IP | ```bash
| ip addr show lte0
| ``` | `networkctl status lte0`, `journalctl -u systemd-networkd --since "5 min ago"` |
| Connected but no data | ```bash
| dig +short +timeout=3 google.com @8.8.8.8
| ``` | `ip route`, AT ports via `scripts/find-at-port.sh` |
| Watchdog stuck in RECOVERING | ```bash
| tail -n 100 /var/log/lte-watchdog/watchdog.log
| ``` | watchdog log, `scripts/lte-recovery.sh --level N` output |
| Watchdog NO_COVERAGE | ```bash
| grep STATE /var/log/lte-watchdog/watchdog.log | tail -5
| ``` | `scripts/find-at-port.sh` AT+CEREG? |
| Ethernet not preferred | ```bash
| ip -4 route show default
| ``` | `networkctl list`, check `.network` files |
| QUIC sessions dropping | ```bash
| cat /sys/bus/usb/devices/*/power/control | grep -A1 2c7c
| ``` | usb autosuspend sysfs, app QUIC keepalive config |

---

## How to use this guide

- Start with the symptom table above and follow the scenario section that matches the observed behavior.
- Always collect an evidence pack before making invasive changes or escalating. See Evidence-pack section.
- Do not perform host-level reboot or shutdown. Instead use the staged recovery ladder (L1..L4) implemented by `scripts/lte-recovery.sh` and invoked by the watchdog.

---

## 1) Modem not enumerating — lsusb -d 2c7c:0901 returns nothing

Symptom
- Running `lsusb -d 2c7c:0901` shows no result.

Checks

```bash
# Basic USB / kernel checks
lsusb
dmesg | grep -i usb | tail -20
systemctl status lte-enum-guard
```

Explanation & possible causes
- Physical: bad USB cable, insufficient power from host, or modem not seated.
- Driver: `cdc_ether` not bound or udev rule prevented enumeration.
- Or the modem is enumerating on a different bus and the host guard prevented further steps.

Resolution steps (field-safe, no host reboot)

1. Confirm cable and power: reseat the cable and ensure the host USB port supplies power. If removable, try the same cable that is known-good on a laptop.

2. Inspect kernel logs for clues:

```bash
dmesg | grep -E "2c7c|cdc_ether|usb" | tail -50
```

3. Check the enum guard service that ensures the modem is present before bootstrapping:

```bash
systemctl status lte-enum-guard.service
journalctl -u lte-enum-guard --since "10 minutes ago"
```

4. If the guard service failed due to missing device, capture evidence and escalate (do NOT reboot host):

```bash
sudo /usr/local/lib/lte-module/lte-evidence-pack.sh
```

5. If driver appears missing, try reloading the cdc_ether module (modprobe unload/load). Use this only if you are comfortable with module operations and after collecting evidence:

```bash
sudo modprobe -r cdc_ether || true
sudo modprobe cdc_ether
```

6. Re-check `lsusb -d 2c7c:0901` and `dmesg` for new entries.

Notes
- If the device enumerates intermittently, prefer replacing cable/power source and collect an evidence pack for support.

---

## 2) lte0 has no IP address — interface up but no inet

Symptom
- `ip link show lte0` shows UP but `ip addr show lte0` has no `inet` address.

Checks

```bash
ip addr show lte0
networkctl status lte0
journalctl -u systemd-networkd --since "5 min ago"
```

Possible causes
- DHCP failure (DHCP server did not assign an address).
- ECM interface still initializing and PDP context not ready.
- systemd-networkd not managing the interface due to a .network/.link mismatch.

Resolution steps

1. Try renewing DHCP via systemd-networkd L1 action (non-invasive):

```bash
sudo networkctl renew lte0
```

2. Inspect `.link` file and `.network` matching to ensure the interface is named and managed as `lte0`:

```bash
grep -i MTUBytes network/10-lte0.link || true
cat /etc/systemd/network/20-lte0.network || true
```

3. Check systemd-networkd logs for DHCP errors:

```bash
journalctl -u systemd-networkd --since "10 minutes ago" | grep -i lte0
```

4. If the `.network` does not bind or you see DHCP timeouts, restart the bootstrap service that brings ECM up (safe restart of that service is allowed):

```bash
sudo systemctl restart lte-ecm-bootstrap.service
journalctl -u lte-ecm-bootstrap --since "2 minutes ago"
```

5. If ECM is not fully initialized, use the recovery ladder L4 only after L1..L3 attempts fail. Manually trigger L4 if instructed by support:

```bash
sudo scripts/lte-recovery.sh --level 4
```

6. Collect evidence if the above does not restore IPv4:

```bash
sudo /usr/local/lib/lte-module/lte-evidence-pack.sh
```

Notes
- Do not reconfigure systemd-networkd outside established `.network` files. Use `networkctl` to debug and `systemctl restart` for the lte-ecm-bootstrap service when needed.

---

## 3) Connected but no data — interface has IP but dig probe fails

Symptom
- `ip addr show lte0` shows an IPv4 address, but `dig +short google.com @8.8.8.8` (bound to LTE) returns nothing.

Checks

```bash
ip route
AT_PORT=$(scripts/find-at-port.sh 2>/dev/null || true)
if [[ -n "$AT_PORT" ]]; then
  printf 'AT+CPIN?\r\n' > "$AT_PORT" && timeout 3 cat "$AT_PORT" || true
  printf 'AT+CEREG?\r\n' > "$AT_PORT" && timeout 3 cat "$AT_PORT" || true
fi
```

Possible causes
- SIM not registered or SIM PIN required.
- APN mismatch causing carrier to drop PDP context.
- Carrier-level blocking or restrictive APN (some IoT APNs block generic internet traffic).

Resolution steps

1. Check SIM and registration via AT commands using dynamic AT port discovery:

```bash
AT_PORT=$(scripts/find-at-port.sh)
printf 'AT+CPIN?\r\n' > "$AT_PORT" && timeout 3 cat "$AT_PORT"
printf 'AT+CEREG?\r\n' > "$AT_PORT" && timeout 3 cat "$AT_PORT"
```

2. If SIM is not READY or registration stat is not 1 or 5, check physical SIM and operator account; do NOT change APN blindly.

3. Verify APN and carrier settings with the check-apn script (dry-run first):

```bash
bash scripts/check-apn.sh --dry-run
```

4. If an explicit APN has been prescribed by operator, set `LTE_APN` in `/etc/lte-module/params.env` (or `config/params.env`) and re-run the APN script.

```bash
# Edit config/params.env: LTE_APN="carrier.apn"
sudo nano /etc/lte-module/params.env  # or edit repo config/params.env then deploy
bash scripts/check-apn.sh
```

5. Confirm the connectivity probe bound to the LTE IP (preferred over ping):

```bash
LTE_IP=$(ip -4 -o addr show dev lte0 scope global | awk '{print $4}' | cut -d/ -f1)
dig +short +timeout=3 -b "$LTE_IP" google.com @8.8.8.8
```

6. If carrier blocks traffic (APN type issue), collect evidence and escalate with the tarball. Use the evidence pack script below.

---

## 4) Watchdog stuck in RECOVERING — lte-watchdog loops but does not recover

Symptom
- Watchdog repeatedly logs RECOVERING and invokes the recovery ladder without reaching HEALTHY.

Checks

```bash
tail -n 200 /var/log/lte-watchdog/watchdog.log
grep -n "Invoking recovery hook" /var/log/lte-watchdog/watchdog.log | tail -20
```

Possible causes

- The recovery levels L1..L3 succeed partially but do not clear the health checks.
- A hardware issue requiring the L4 AT reset has not been reached because the configured max level is too low.

Resolution

1. Inspect which recovery level the watchdog is calling. The watchdog log contains lines like `Invoking recovery hook: ... --level N`.

```bash
grep "Invoking recovery hook" /var/log/lte-watchdog/watchdog.log | tail -20
```

2. Check the configured maximum recovery level in `config/params.env` (`LTE_WATCHDOG_MAX_RECOVERY_LEVEL`). If it is lower than 4 and the modem needs an AT reset, update the parameter via proper deployment workflow and redeploy. For immediate field action, run the L4 recovery manually (preferred over host-level restart):

```bash
sudo scripts/lte-recovery.sh --level 4
```

3. After L4 completes, watch for re-enumeration and interface coming back:

```bash
lsusb -d 2c7c:0901
ip link show lte0
journalctl -u lte-ecm-bootstrap --since "2 minutes ago"
```

4. If L4 fails repeatedly, collect an evidence pack and escalate to support.

Notes
- The watchdog implements the staged ladder L1..L4; manual L4 is available for operators. Never recommend host reboot.

---

## 5) Watchdog in NO_COVERAGE state

Symptom
- `grep STATE /var/log/lte-watchdog/watchdog.log | tail -5` shows NO_COVERAGE.

What this means
- The modem is alive but `AT+CEREG?` returned a registration stat not in {1,5}. The watchdog correctly moves to NO_COVERAGE and deliberately does not call recovery executors in this state.

Checks

```bash
grep STATE /var/log/lte-watchdog/watchdog.log | tail -10
AT_PORT=$(scripts/find-at-port.sh 2>/dev/null || true)
if [[ -n "$AT_PORT" ]]; then
  printf 'AT+CEREG?\r\n' > "$AT_PORT" && timeout 3 cat "$AT_PORT"
fi
```

Why this is normal
- NO_COVERAGE indicates the radio is not registered to the network. The watchdog design intentionally avoids recovery actions when there is no cellular coverage because recovery would be ineffective and could create noise.

Resolution

1. Verify SIM validity, signal, and registration status with `AT+CEREG?`.

2. If radio remains unregistered for a long time, confirm SIM provisioning and site coverage; collect evidence and escalate.

3. If the SIM should be registered but is not, collect evidence and consider manual L4 reset only if advised by support:

```bash
scripts/find-at-port.sh  # locate AT port
sudo scripts/lte-recovery.sh --level 4
```

Notes
- NO_COVERAGE is a design state. It suppresses recovery to avoid pointless cycles. Be patient and collect evidence to escalate.

---

## 6) Ethernet not preferred over LTE — default route uses LTE when Ethernet present

Symptom
- `ip -4 route show default` shows the default via `lte0` even though Ethernet cable is connected and should be preferred.

Checks

```bash
ip -4 route show default
networkctl list
cat /etc/systemd/network/10-eth1.network
cat /etc/systemd/network/20-lte0.network
```

Possible causes
- Route metrics in `.network` files are incorrect or `ConfigureWithoutCarrier` is not set for Ethernet, causing phantom routes.

Resolution

1. Verify `.network` file RouteMetric values: Ethernet should have `RouteMetric=100`, LTE `RouteMetric=1000`.

```bash
grep -n "RouteMetric" /etc/systemd/network/*.network
```

2. Ensure Ethernet `.network` files include `ConfigureWithoutCarrier=no` so networkd waits for carrier before installing routes. If missing, add it and restart systemd-networkd:

```bash
sudo sed -n '1,120p' /etc/systemd/network/10-eth1.network
sudo systemctl restart systemd-networkd
journalctl -u systemd-networkd --since "1 minute ago" | tail -n 50
```

3. Confirm the kernel default route metrics after restart:

```bash
ip -4 route show default
```

Notes
- If editing files remotely, ensure you follow change management. Restarting systemd-networkd is acceptable; host-level reboot is not.

---

## 7) QUIC sessions dropping — telemetry disconnects under LTE

Symptom
- QUIC telemetry sessions drop intermittently when using LTE. Application reconnects but sessions are unstable.

Checks

```bash
# Verify USB autosuspend state for modem
grep -R "2c7c" /sys/bus/usb/devices -n --exclude-dir=power || true
cat /sys/bus/usb/devices/*/power/control | grep -A1 2c7c || true

# Verify app-level keepalive
# (Application config inspected on host; path depends on deployment)
```

Possible causes

- USB autosuspend re-enabled, causing modem to power-cycle during idle.
- Carrier NAT timeouts for UDP/QUIC flows shorter than application keepalive.

Resolution

1. Verify tuning via `scripts/verify-tuning.sh` which checks autosuspend and MTU settings (dry-run first):

```bash
bash scripts/verify-tuning.sh --dry-run
sudo bash scripts/verify-tuning.sh
```

2. Confirm autosuspend is disabled for the modem sysfs node (`power/control` should read `on` and `power/autosuspend_delay_ms` should be `-1`).

```bash
MODEM_SYSFS=$(find /sys/bus/usb/devices/ -name "idVendor" -exec grep -l "2c7c" {} + 2>/dev/null | xargs -r dirname | head -n1)
if [[ -n "$MODEM_SYSFS" ]]; then
  cat "$MODEM_SYSFS/power/control" || true
  cat "$MODEM_SYSFS/power/autosuspend_delay_ms" || true
fi
```

3. If autosuspend is not disabled, the udev rule `99-ec200u-lte.rules` may not have been applied. Reload udev rules and trigger, then re-plug the device if possible.

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

4. Reduce QUIC keepalive (application-side) to 10s for aggressive NAT environments. This is an application change, not an OS change. Recommended value:

```yaml
# Application config (example)
keepalive_ms: 10000
idle_timeout_ms: 60000
```

5. If connections still drop after autosuspend and keepalive changes, collect evidence for support.

---

## Evidence-pack (field support)

When in doubt, collect an evidence pack and share it with the support team. The installed evidence pack helper is available at `/usr/local/lib/lte-module/lte-evidence-pack.sh` (installed location) and the source in the repo is `scripts/lte-evidence-pack.sh`.

How to run

```bash
sudo /usr/local/lib/lte-module/lte-evidence-pack.sh
# or dry-run to preview what would be collected
bash scripts/lte-evidence-pack.sh --dry-run
```

What it collects (summary)
- Journald logs for relevant units: lte-watchdog, lte-ecm-bootstrap, lte-enum-guard (24 hours)
- `ip addr`, `ip route`, `networkctl status`
- `lsusb` and `udevadm info --name=lte0` output
- `dmesg` lines relevant to USB, cdc_ether, LTE VID:PID
- Watchdog state files and any `.sisyphus/evidence/*.txt` present

Where the tarball goes

- The evidence pack script writes a tarball to `/tmp` with a timestamped name such as `/tmp/lte-diag-<timestamp>.tar.gz` and prints the path to stderr. Attach that tarball to the support ticket.

How to share

1. Run the script as above, capture the tarball path.
2. Upload to the support portal or attach to an email to your support contact.
3. In the support request include:
   - Short description of symptom and time window
   - Steps you already tried
   - The tarball produced by the evidence pack

---

## Appendix — Useful commands (copyable)

```bash
# Find modem on USB
lsusb -d 2c7c:0901

# Kernel messages for USB
dmesg | grep -i usb | tail -50

# AT port discovery
scripts/find-at-port.sh

# Send test AT commands (use scripts/find-at-port.sh to locate port)
AT_PORT=$(scripts/find-at-port.sh)
printf 'AT+CPIN?\r\n' > "$AT_PORT" && timeout 3 cat "$AT_PORT"

# Check watchdog status and logs
tail -n 200 /var/log/lte-watchdog/watchdog.log

# Inspect networkd state
networkctl status lte0
networkctl list

# Renew DHCP
sudo networkctl renew lte0

# Run staged recovery (L1..L4). Prefer L1 or L2 first, L4 requires AT reset.
sudo scripts/lte-recovery.sh --level 1
sudo scripts/lte-recovery.sh --level 2
sudo scripts/lte-recovery.sh --level 3
sudo scripts/lte-recovery.sh --level 4

# Collect evidence pack
sudo /usr/local/lib/lte-module/lte-evidence-pack.sh
```

## Final notes and escalation checklist

1. Collect evidence pack before making invasive changes.
2. Prefer non-invasive steps: check cables, verify AT registration, renew DHCP, verify routing metrics.
3. Use the recovery ladder L1..L4 implemented by `scripts/lte-recovery.sh`. Manual L4 is acceptable when instructed by support.
4. Do not attempt host-level reboot or shutdown. If you think a host-level restart is required, collect the evidence pack and escalate to support.

---

Document last updated: 2026-03-12
