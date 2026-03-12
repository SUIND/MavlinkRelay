# LTE Module Conventions & Guardrails

**Hardware Target:** Quectel EC200U-CN on Jetson Xavier NX  
**Last Updated:** 2026-03-12  

---

## 1. Hard Guardrails (Non-Negotiable)

### 1.1 No Host Reboot — Ever
- **Rule:** Host reboot is FORBIDDEN as a recovery action for LTE failures.
- **Rationale:** Rebooting the Jetson NX breaks running applications and LTE connectivity itself.
- **Recovery Ladder:**
  1. AT command reset on modem (`AT+CFUN=1,1`)
  2. USB device re-enumeration via udev hotplug
  3. systemd service restart
  4. Manual intervention + alert only (no automatic reboot)

### 1.2 systemd-networkd is Sole Network Owner
- **Rule:** NetworkManager is forbidden. All network configuration via `systemd-networkd`.
- **Config Method:** `.link` files for MAC-based renaming, `.network` files for DHCP/routing.
- **Verification:** `systemctl is-active systemd-networkd` must return `active`.

### 1.3 Ethernet-Primary Routing Policy
- **Rule:** Ethernet has RouteMetric=100, LTE has RouteMetric=1000.
- **Outcome:** Default route prefers Ethernet; LTE becomes automatic fallback.
- **Config:** Set in `.network` files under `[Route]` sections.
- **Example:**
  ```
  [Interface]
  Name=eth0
  [Route]
  Destination=0.0.0.0/0
  RouteMetric=100
  ```

### 1.4 Interface Name is `lte0`
- **Rule:** LTE modem interface MUST be renamed to `lte0` from `usb0`.
- **Method:** MAC-based `.link` file matching `02:4b:b3:b9:eb:e5`.
- **Verification:** `ip link show lte0` must exist; `usb0` must NOT exist.
- **Why:** Consistent naming across reboots; `usb0` is unstable.

### 1.5 AT Port Dynamically Discovered
- **Rule:** AT command port (`/dev/ttyUSBx`) MUST be discovered at runtime.
- **Forbidden:** Hardcoding `/dev/ttyUSB2` or any fixed device path.
- **Method:** Query `/sys/class/tty/ttyUSB*/device/driver/module/drivers/*` or udev properties.
- **Rationale:** Device enumeration order changes across boot/reboots; relying on fixed paths causes silent failures.

### 1.6 Forbidden Technologies
- **QMI (Qualcomm MSM Interface):** Not used. EC200U defaults to ECM + AT.
- **MBIM (Mobile Broadband Interface Model):** Not used.
- **usb-modeswitch:** Not used. Modem already enumerates in ECM mode.
- **NetworkManager:** Forbidden. systemd-networkd only.
- **GPS/NMEA on LTE interface:** Not supported.
- **IPv6 on LTE:** Disabled. IPv4-only on `lte0`.
- **Firmware Updates:** Not supported in this deployment phase.

### 1.7 Evidence Directory
- **Rule:** All runtime evidence (logs, captures, diagnostics) go under `.sisyphus/evidence/`.
- **Structure:** Create subdirectories by task/date: `.sisyphus/evidence/task-N-taskname/`
- **Retention:** Evidence is version-controlled; purge manually when needed.
- **Example:** `.sisyphus/evidence/task-9-modem-bringup/2026-03-12-dmesg.log`

---

## 2. Operational Conventions

### 2.1 Log Format
- **Format:** `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`
- **Levels:** DEBUG, INFO, WARN, ERROR, FATAL
- **Example:** `[2026-03-12 14:35:22] [INFO] LTE interface lte0 brought up with IP 10.251.11.1`
- **Requirement:** All scripts and daemons MUST use this format.

### 2.2 Dry-Run Mode
- **Rule:** Scripts that modify system state MUST support `--dry-run` flag.
- **Behavior:** Print actions that would be taken; do NOT execute.
- **Example Usage:**
  ```bash
  ./scripts/bring-up-lte.sh --dry-run
  [2026-03-12 14:35:22] [INFO] (dry-run) Would send AT command: AT+CFUN=1,1
  [2026-03-12 14:35:22] [INFO] (dry-run) Would configure interface lte0 with DHCP
  ```

### 2.3 Deployment Parameters (Single Source of Truth)
- **File:** `config/params.env`
- **Rule:** All deployable parameters go here. Scripts source this file.
- **Format:** Shell-compatible KEY=VALUE with comments.
- **Required Keys:**
  - `LTE_MODEM_VID_PID`: USB Vendor:Product ID
  - `LTE_MODEM_MAC`: Ethernet MAC address
  - `LTE_INTERFACE_NAME`: Interface name (must be `lte0`)
  - `LTE_USB_DRIVER`: USB driver (must be `cdc_ether`)
  - `LTE_ROUTE_METRIC`: Route metric for LTE (must be 1000)
  - `ETH_ROUTE_METRIC`: Route metric for Ethernet (must be 100)
  - `LTE_MTU`: MTU on LTE interface (recommend 1400)
  - `APN`: Access Point Name (empty = auto/default)
  - `LTE_RAT_LOCK_ENABLED`: RAT lock toggle (false = auto mode)
  - `EVIDENCE_DIR`: Path to evidence directory (must be `.sisyphus/evidence`)
  - `LOG_LEVEL`: Logging level (DEBUG, INFO, WARN, ERROR, FATAL)

### 2.4 Script Exit Codes
- `0`: Success
- `1`: General error
- `2`: Configuration error (missing params, invalid values)
- `3`: Hardware error (modem not found, AT command failure)
- `4`: Network configuration error (systemd-networkd failure)
- `5`: Permission error (not root)

### 2.5 Systemd Service Units
- **Location:** `units/`
- **Naming:** `lte-*.service`, `lte-*.socket` (prefix with `lte-`)
- **Content:** StandardOutput=journal, StandardError=journal
- **Type:** Likely `Type=simple` or `Type=oneshot` (no `Type=forking`)
- **Restart:** Use `Restart=on-failure` with `RestartSec=` backoff only where justified

---

## 3. Testing Conventions

### 3.1 Unit Tests (Offline)
- **Location:** `tests/unit/`
- **No Hardware Required:** Mock all AT commands, udev events, dmesg.
- **Framework:** Bash Bats or similar.
- **Scope:** Parameter validation, log format parsing, dry-run flag behavior.

### 3.2 Integration Tests (Hardware-in-Loop)
- **Location:** `tests/integration/`
- **Hardware Required:** EC200U-CN + Jetson Xavier NX + SIM + LTE coverage.
- **Scope:** Actual modem enumeration, DHCP negotiation, ping tests, metric verification.
- **Preconditions:** SIM must have active LTE plan; test environment must have LTE coverage.

---

## 4. udev Rules

- **Location:** `rules/`
- **Naming:** `99-lte-*.rules` (high number for low priority).
- **Actions:** Symlink creation, AT port discovery, service trigger.
- **Never Hardcode:** Device paths. Always use environment variables or dynamic discovery.

---

## 5. systemd-networkd Configuration

- **Location:** `network/`
- **`.link` files:** MAC-based interface renaming (e.g., `10-lte-usb0-to-lte0.link`).
- **`.network` files:** DHCP, static routes, route metrics.
- **Reload:** `systemctl reload systemd-networkd` after config changes.
- **Verify:** `networkctl status lte0`, `ip route show`

---

## 6. Common Pitfalls to Avoid

- ❌ Hardcoding device paths (`/dev/ttyUSB2`, `usb0`)
- ❌ Calling `echo host > /sys/bus/usb/devices/.../role` (OTG switch — wrong for this hardware)
- ❌ Running any QMI client code
- ❌ Assuming static USB enumeration order
- ❌ Using NetworkManager or any conflicting network manager
- ❌ Setting IPv6 addresses on LTE interface
- ❌ Rebooting the host as a recovery action
- ❌ Ignoring the dry-run flag in bring-up scripts

---

## 7. Deployment Checklist

Before declaring a task complete:

- [ ] All scripts support `--dry-run` flag
- [ ] All logs follow `[YYYY-MM-DD HH:MM:SS] [LEVEL] message` format
- [ ] Evidence is saved to `.sisyphus/evidence/task-N-*/`
- [ ] No hardcoded device paths in code
- [ ] systemd-networkd verified as sole network owner
- [ ] Route metrics verified: Ethernet=100, LTE=1000
- [ ] Interface renamed from `usb0` to `lte0`
- [ ] AT port discovery verified (not hardcoded)
- [ ] No NetworkManager, QMI, MBIM, or OTG code present
- [ ] Tests created in `tests/unit/` or `tests/integration/` as applicable
