# Learnings

## Hardware Facts (Confirmed from User dmesg)
- VID:PID: `2c7c:0901` (Quectel EC200U-CN)
- MAC: `02:4b:b3:b9:eb:e5` — stable across re-enumeration (device number changed 3→5 but MAC identical)
- Driver: `cdc_ether` — binds automatically in ECM mode
- USB controller: `usb-3610000.xhci-1` (XHCI **host** controller, NOT OTG)
- Interface name at enumeration: `usb0` → must be renamed to `lte0`
- IPv6 link-local auto-assigned; IPv4 NOT assigned (DHCP not run yet)
- Existing interfaces: `eth0` (no IP, cable not plugged), `eth1` (active: `192.168.1.7/24`), `tailscale0`, `docker0`, `lo`

## Controller Topology
- `3610000.xhci` = XHCI host controller (modem attaches here) — NO role-switch needed
- `3550000.xudc` = USB device/OTG controller — modem does NOT attach here
- `nv-l4t-usb-device-mode` controls `3550000.xudc` only — masking is precautionary

## AT Commands
- `AT+QCFG="usbnet"` — query current mode (expect `,1` = ECM)
- `AT+QCFG="usbnet",1` — set ECM mode (modem restart required after)
- `AT+CFUN=1,1` — full function + restart (preferred reset)
- `AT+QRST=1,0` — alternative reset
- `AT+QNWPREFMDE=2` — LTE-only RAT lock (opt-in)
- `AT+CPIN?` — SIM state (expect `+CPIN: READY`)
- `AT+CREG?` — GSM registration (stat=1 home, stat=5 roaming)
- `AT+CEREG?` — LTE EPS registration (stat=1 home, stat=5 roaming)

## Network Stack
- Stack owner: `systemd-networkd` (NOT NetworkManager)
- Route metrics: Ethernet `RouteMetric=100`, LTE `RouteMetric=1000`
- MTU: 1400 on `lte0`
- IPv6: disabled on LTE
- APN: auto/default first; explicit APN as fallback deployment parameter

## MavlinkRelay App Config (context)
- QUIC keepalive: 15s (consider 10s for aggressive carrier NAT)
- Idle timeout: 60s
- Reconnect backoff: 1→2→4→8→16→30s cap
- Profile: `QUIC_EXECUTION_PROFILE_LOW_LATENCY`

## Udev Rules for EC200U-CN

### File: `rules/99-ec200u-lte.rules`

#### VID:PID Matching Strategy
- Uses **exact VID:PID matching only** (`2c7c:0901`)
- Subsystem filter: `SUBSYSTEMS=="usb"` (prevents false positives)
- Attributes: `ATTRS{idVendor}=="2c7c"` + `ATTRS{idProduct}=="0901"`
- Rationale: Narrow targeting prevents unintended side effects on other USB devices

#### ModemManager Blocking
- Action: `ENV{ID_MM_DEVICE_IGNORE}="1"`
- Why: ModemManager probes ttyUSB ports for modem control, conflicts with:
  - Custom AT command bootstrap scripts on `/dev/ttyUSB0` (DM port)
  - External pipeline management of device state
  - Race conditions between ModemManager and our telemetry startup sequence
- Effect: Modem will NOT appear in `mmcli -L` output

#### USB Autosuspend Disabling
- Actions:
  - `ATTR{power/control}="on"` (force device to stay powered)
  - `ATTR{power/autosuspend_delay_ms}="-1"` (disable autosuspend)
- Why: EC200U-CN suspends mid-flight otherwise, breaking telemetry/GPS/commands
- Critical for drone flight operations (altitude > 0m + data flowing)

#### Device Labeling
- `TAG="ec200u_lte_modem"` — identifies device in udevadm queries
- `SYMLINK+="ec200u-lte"` — creates predictable symlink at `/dev/ec200u-lte`
- Helps with debugging and system integration

### Deployment Steps
1. Copy to `/etc/udev/rules.d/99-ec200u-lte.rules` on Jetson Xavier NX
2. Reload rules: `sudo udevadm control --reload-rules && sudo udevadm trigger`
3. Verify: `udevadm info /dev/ec200u-lte` (after device plugged in)
4. Check tags: `udevadm info /dev/ec200u-lte | grep TAGS`
5. Confirm ModemManager blocking: `mmcli -L` (EC200U should NOT list)

### Verification Commands
```bash
# Check if modem is matched by rule
udevadm test $(udevadm info -q path -n /dev/ec200u-lte) 2>&1 | grep -i "tag\|symlink"

# Check power settings
cat /sys/bus/usb/devices/*/power/control | grep -A1 ec200u

# Confirm ModemManager ignores device
mmcli -L | grep -i quectel || echo "Modem correctly ignored by ModemManager"
```

## Task 1: Skeleton & Conventions (2026-03-12)
- Created full project directory structure: scripts/, units/, rules/, network/, tests/unit, tests/integration, docs/, config/
- Documented comprehensive conventions in `docs/CONVENTIONS.md`:
  - Hard guardrail: No host reboot ever (max recovery is AT modem reset)
  - Network stack: systemd-networkd only (NetworkManager forbidden)
  - Route metrics: Ethernet 100 (primary), LTE 1000 (fallback)
  - Interface naming: MAC-based rename from usb0→lte0 (verified stable MAC: 02:4b:b3:b9:eb:e5)
  - AT port discovery: Must be dynamic (no hardcoded /dev/ttyUSBx paths)
  - Forbidden: QMI, MBIM, usb-modeswitch, NetworkManager, GPS/NMEA, IPv6 on LTE, firmware updates
  - Evidence directory: `.sisyphus/evidence/task-N-*` (version-controlled)
  - Log format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`
  - Dry-run mode: All system-modifying scripts support `--dry-run` flag
  - Deployment parameters: Single source of truth in `config/params.env`
  - Service exit codes: 0=success, 1=general error, 2=config error, 3=hardware error, 4=network error, 5=permission error
  - Testing: Unit tests offline (mocked), integration tests hardware-in-loop
  - Deployment checklist provided for task completion verification
- Created `config/params.env` with all deployable parameters:
  - Hardware IDs: VID:PID=2c7c:0901, MAC=02:4b:b3:b9:eb:e5
  - Network config: Interface name=lte0, Driver=cdc_ether, MTU=1400
  - Route metrics: LTE=1000, Ethernet=100
  - Modem behavior: APN auto/default, RAT lock disabled (auto mode)
  - Logging: Evidence directory, log level configurable
- Evidence saved to `.sisyphus/evidence/task-1-skeleton.txt`

## Task 3: systemd-networkd .link File for EC200U (2026-03-12)
- Created `/home/kevin/workspace/MavlinkRelay/lte_module/network/10-lte0.link` file
- **Matching Strategy**: MAC-based (`MACAddress=02:4b:b3:b9:eb:e5`) instead of USB path
  - USB device paths change between kernel versions and reboots
  - MAC address is hardware-burned and stable across re-enumeration (verified: device 3→5, MAC identical)
  - This ensures rename persists without maintenance burden
- **File Naming**: Prefix `10-` ensures `.link` file processes before `.network` files (20+)
- **Link Configuration**:
  - `[Match]` section: `MACAddress=02:4b:b3:b9:eb:e5`
  - `[Link]` section: `Name=lte0`, `MTUBytes=1400`
- **MTU Rationale**: 1400 bytes accommodates LTE GTP overhead (~20 bytes), prevents IP fragmentation in high-latency/lossy remote telemetry environments
- **Deployment**: Must install to `/etc/systemd/network/10-lte0.link` on target system
- **Comments Added**: Extensive documentation on MAC stability, MAC-vs-USB-path rationale, MTU tuning for telemetry, device numbering conventions
- **Evidence**: Saved to `.sisyphus/evidence/task-3-link.txt` and `.sisyphus/evidence/task-3-usb0-scan.txt`
- **Verification**: grep for usb0 references shows only documentation comments (no functional dependencies)

### Key Decision: MAC Matching Over USB Path
- **Pro MAC**: Stable across hardware re-enumeration, kernel updates, firmware changes
- **Con USB Path**: Breaks when device enumeration order changes (common in Jetson environments during kernel patches)
- **Trade-off**: Simple human-readable MAC vs complex USB device path matching — MAC wins for production reliability

## SCOPE.md creation note

- SCOPE.md was created and committed to docs/. It contains Purpose, In Scope, Non-Goals (including host reboot guardrail), Confirmed Deployment Assumptions, Deployment Variables, Compatibility Notes, Must Not Do, Context, and Recovery Ladder.

(Appended 2026-03-12)

## Task 5: Test Harness Skeleton (2026-03-12)
- Created complete test framework with shared evidence library and test runners
- **`tests/lib/evidence.sh`**: Shared helper library providing:
  - `pass()` / `fail()` / `skip()` — result reporting with optional detail strings
  - `require_hardware()` — skips hardware-dependent checks if `HARDWARE_TESTS != "1"`
  - `save_evidence()` — writes evidence files to `.sisyphus/evidence/`
  - `summary()` — prints test counts and returns exit code (1 if any failures)
  - Automatic evidence directory creation on first use
- **`tests/unit/run_all.sh`**: Unit test runner
  - Iterates all `tests/unit/test_*.sh` files
  - Runs each in subprocess to prevent test failure from aborting runner
  - Uses exit codes for pass/fail tracking (not summary() output)
  - Prints per-test status lines with ✓/✗ markers
  - Returns runner_fail_count as exit code (0 = all passed)
  - No hardware required (offline, all mocked)
- **`tests/integration/run_all.sh`**: Integration test runner
  - Same structure as unit runner but for `tests/integration/test_*.sh` files
  - Supports `HARDWARE_TESTS=1` environment variable to enable hardware tests
  - Supports `--skip-hardware` CLI flag for dry-run without hardware
  - Relies on per-test `require_hardware` calls to skip hardware-dependent steps
- **`tests/unit/test_placeholder.sh`**: Sample unit test
  - Minimal working example: sources evidence.sh, calls pass(), calls summary()
  - Demonstrates correct test structure for future test authoring
- **Hardware Marker Convention**: Any integration test requiring hardware must:
  - Include `# HARDWARE_REQUIRED: yes` comment near top
  - Call `require_hardware` before hardware-dependent steps
  - Will safely skip if `HARDWARE_TESTS != "1"` (no test failures, just skips reported)
- **Test Output Format**:
  ```
  Running test_placeholder.sh...
  [PASS] harness-sanity: test framework loads and runs correctly
  ---
  RESULTS: 1 passed, 0 failed, 0 skipped
    ✓ test_placeholder.sh passed
  ```
- **Exit Codes**: Runners return 0 on all pass, non-zero if any test fails
- **Evidence**: Unit runner test output saved to `.sisyphus/evidence/task-5-unit-runner.txt`
- **Syntax Verification**: All scripts pass `bash -n` syntax check without errors

### Design Rationale
- **Subprocess execution**: Prevents early exit on test failure, enables continuation to other tests
- **Shared evidence library**: Single source of truth for test output format and evidence collection
- **Hardware environment variable**: Allows CI/CD to control hardware access without script changes
- **No `set -e`**: Explicit exit code tracking gives finer control over test flow (individual test failures don't cascade)

## Routing Policy Document (Task 4 — 2026-03-12)

### File Created
- `docs/ROUTING-POLICY.md` — full routing policy design document

### Key Points Documented
- Route metric strategy: eth0/eth1 = 100, lte0 = 1000
- LTE warm standby explicitly defined: always-on, never disabled
- Failover timing: < 5 s (carrier event → route withdrawal → LTE default active)
- Recovery: automatic when Ethernet carrier returns (DHCP → metric 100 route reinstalled)
- QUIC impact: path migration on failover; recommend keepalive_ms=10000 (was 15000)
- Verification commands documented: `ip route show`, `networkctl list`, etc.

### Sections in document
1. Policy Summary (golden rule: LTE never disabled)
2. Implementation Details (metrics, .network files, carrier detection, timing, recovery)
3. Hardware Context (eth0/eth1/lte0 inventory with confirmed IPs)
4. Telemetry Impact (QUIC failover sequence, keepalive recommendation)
5. Verification Commands (full set of ip/networkctl checks)
6. Non-Goals (explicit list of what this policy does NOT cover)
7. Why Not Disable LTE (rationale for warm standby over cold standby)

## Task 10: systemd-networkd .network Files (2026-03-12)

### Files Created
- `network/20-lte0.network` — EC200U-CN LTE interface (DHCP=ipv4, RouteMetric=1000)
- `network/10-eth0.network` — Secondary Ethernet interface (RouteMetric=100)
- `network/10-eth1.network` — Primary Ethernet interface (RouteMetric=100)

### Design Decisions
1. **IPv4-only DHCP on LTE**: `DHCP=ipv4` (not "yes" which would enable IPv6RA-based configuration)
   - Rationale: IPv6 on LTE modem explicitly suppressed per ROUTING-POLICY.md
   - Used `IPv6AcceptRA=no` to disable IPv6 prefix acceptance

2. **Route Metrics Alignment**:
   - Ethernet (eth0/eth1): `RouteMetric=100` — preferred uplink
   - LTE (lte0): `RouteMetric=1000` — warm standby fallback
   - Aligns with ROUTING-POLICY.md (see Task 4 documentation)

3. **EC200U-CN DHCP Tuning**:
   - `MaxAttempts=5` — modem hands short leases, keep renewing aggressively
   - `UseNTP=no` — UTC sync handled by host NTP service, not DHCP
   - `SendHostname=yes` — hostname advertised to DHCP server (optional but improves logging)

4. **MTU Not Duplicated**:
   - MTU=1400 already set in `network/10-lte0.link` (Task 3)
   - Not repeated in `.network` file to avoid ambiguity (single source of truth)
   - Per systemd-networkd docs: Link properties in `.link`, Address/Route in `.network`

5. **Boot Not Blocked**:
   - `RequiredForOnline=no` on all interfaces
   - Prevents "waiting for network" delays at boot
   - All interfaces DHCP but optional for system readiness

6. **MAC-based Interface Identification**:
   - lte0 matched by `[Match] Name=lte0` (renamed from usb0 by 10-lte0.link)
   - 10-lte0.link uses MAC `02:4b:b3:b9:eb:e5` for stable rename (see Task 3)

### Routing Warm Standby Behavior
- **Ethernet active** (cable plugged in):
  - eth1 gets DHCP, installs default route with metric 100
  - lte0 holds DHCP lease, keeps default route with metric 1000 (shadow/inactive)
  - Kernel uses metric 100 (Ethernet) — LTE is standby
- **Ethernet fails** (cable unplugged, carrier drops):
  - eth1 carrier lost → networkd withdraws eth1 routes
  - Only lte0 default route remains (metric 1000) → becomes active
  - Failover time: < 5 s (kernel event-driven)
- **Ethernet returns**:
  - eth1 carrier up → DHCP → metric 100 route installed
  - LTE route still present but metric 1000 > 100 → reverts to shadow standby

### File Naming Convention
- `10-*.link` — interface renaming rules (processed first)
- `10-*.network` — Ethernet network configuration (processed after links)
- `20-*.network` — LTE network configuration (processed after Ethernet)
- Higher numbers: fallback/special cases

### Systemd-networkd vs NetworkManager
- All files follow systemd-networkd syntax (NOT NetworkManager keyfiles)
- No `.nmconnection` files used
- No nmcli commands required
- Manual line entry verification: no NetworkManager references in any file

### Evidence
- Saved to `.sisyphus/evidence/task-10-networkd.txt`
- Content verified: IPv4-only, RouteMetric values, IPv6 suppression
- All three files deployed to network/ directory

### Verification Steps (on Target System)
```bash
# Check default routes with metrics
ip -4 route show default

# Expected (Ethernet active, LTE warm standby):
#   default via 192.168.1.1 dev eth1 proto dhcp src 192.168.1.7 metric 100
#   default via 192.168.225.1 dev lte0 proto dhcp src 192.168.225.x metric 1000

# Check per-interface configuration
networkctl status lte0
networkctl status eth1

# Simulate failover: unplug Ethernet cable, then check:
ip -4 route show default  # Should only show LTE (metric 1000) now

# Restore: plug Ethernet back in, then check:
ip -4 route show default  # Should show both metrics again
```

### Deployment Checklist
1. ✓ Create network/20-lte0.network (LTE configuration)
2. ✓ Create network/10-eth0.network (Secondary Ethernet)
3. ✓ Create network/10-eth1.network (Primary Ethernet)
4. Copy files to `/etc/systemd/network/` on target Jetson
5. Reload and verify: `systemctl restart systemd-networkd`
6. Test failover manually or via watchdog module (Task 7)

## Task 12: Static Validation Runner (2026-03-12)

### Pattern: `((VAR++))` with `set -e` is a trap
- `((PASS_COUNT++))` exits with status 1 when `PASS_COUNT=0` (arithmetic eval of 0 is falsy)
- Test scripts sourcing `evidence.sh` must NOT use `set -euo pipefail` — the harness uses `((PASS_COUNT++))` etc.
- Workaround: omit `set -e` in test scripts, or add `|| true` after arithmetic increments in the library

### Pattern: Test self-scanning false positives
- A static validation script that scans for forbidden patterns will match itself
- Solution: exclude the test file itself (`*test_static_validation.sh`) from forbidden-pattern scans
- Use `case "$f" in *test_static_validation.sh) ;; *) FORBIDDEN_FILES+=("$f") ;; esac`

### Scripts created
- `tests/unit/test_static_validation.sh` — static CI gate: bash -n, shellcheck, forbidden patterns
- `scripts/validate.sh` — convenience runner: static + unit suite, `--ci` flag for machine-readable output

### Evidence
- `.sisyphus/evidence/task-12-static.txt` — 9 passed, 0 failed, 6 skipped
- `.sisyphus/evidence/task-12-smoke.txt` — full validate.sh run, overall PASS

## Task 8: Dynamic AT-port discovery (find-at-port.sh)

**Date:** 2026-03-12

### What was built
- `scripts/find-at-port.sh` — probes all `/dev/ttyUSB*` candidates dynamically; never hardcodes port numbers
- `tests/unit/test_find_at_port.sh` — 4 unit tests (mock-port, no-device exit-3, syntax, no-hardcode)
- `AT_PROBE_TIMEOUT_S=2` added to `config/params.env`

### Key patterns / conventions
- `--mock-port PATH` flag provides a fast-path for unit testing without hardware (returns PATH directly, exits 0)
- `--dry-run` flag skips `stty`/`exec` device open; useful for smoke tests on systems without the modem
- Glob expansion check: `[[ ! -e "${candidates[0]}" ]]` detects unexpanded glob (no devices present) cleanly
- `stty -F $port 115200 cs8 -cstopb -parenb raw -echo -hupcl` sets up 115200 8N1 raw before sending `AT\r\n`
- `exec 3<>"$port"` opens the port bidirectional; `printf 'AT\r\n' >&3` sends the command
- `timeout $N bash -c "while IFS= read -r -t $N line <&3; do echo $line; done"` reads response safely
- Evidence counters in `evidence.sh` (PASS_COUNT etc.) must NOT be used inside a subshell/pipe — run tests in the main shell, write evidence file separately

### Exit codes used
- 0 = AT port found (printed to stdout)
- 2 = config/arg error
- 3 = hardware error (no port responded)

### Gotchas
- Piping test body through `tee` for simultaneous evidence capture runs it in a subshell, zeroing counters — write evidence file separately after tests run
- `mapfile -t` requires bash 4+; safe on Jetson Xavier NX (Ubuntu 20.04, bash 5.0)
- EC200U-CN typical layout: ttyUSB0=DM, ttyUSB1=NMEA, ttyUSB2=AT, ttyUSB3=modem — but probing all is correct; USB kernel assignment order is not guaranteed

## Task 11: APN Verification Script (2026-03-12)

### File Created
- `scripts/check-apn.sh` — APN verification with auto/default first, explicit APN as deployment fallback

### Design: Auto/Default APN as Primary Path
- `LTE_APN=""` in `config/params.env` → script logs "using auto/default APN", skips AT+CGDCONT= set command
- EC200U-CN negotiates APN automatically with the carrier network in auto mode
- Explicit APN only set when operator configures `LTE_APN=<value>` in params.env

### APN Variable Rename
- `params.env` updated: `APN=""` → `LTE_APN=""` (consistent with LTE_ prefix convention)
- Old `APN` variable removed to prevent ambiguity

### Connectivity Probe: dig not ping
- Chinese carrier NAT blocks ICMP → `ping` is unreliable for LTE connectivity probing
- `dig +short +timeout=3 -b <lte0_ip> google.com @8.8.8.8` probes UDP/53 through 8.8.8.8
- Bound to lte0 IP to force traffic through LTE interface (bypasses Ethernet route)

### AT Command Sequence
1. `AT+CPIN?` → SIM state (must be READY)
2. `AT+CEREG?` → LTE EPS registration (stat=1 home, stat=5 roaming)
3. `AT+CGDCONT?` → query current PDP context (informational)
4. If LTE_APN set: `AT+CGDCONT=1,"IP","<apn>"` → explicit APN set
5. dig probe → connectivity verification

### AT Port Discovery
- Uses `scripts/find-at-port.sh` if it exists (Task 9 expected deliverable)
- Falls back to probing `/dev/ttyUSB*` sequentially with `AT\r` + response check
- Dynamic discovery — no hardcoded `/dev/ttyUSBx` paths

### Exit Codes
- 0 = success
- 2 = config error (params.env missing)
- 3 = hardware error (SIM not ready, not registered, AT port not found)
- 4 = network error (dig probe failed — no IP on lte0, or DNS unreachable)

### Evidence
- `.sisyphus/evidence/task-11-auto-apn.txt` — dry-run output showing auto APN path
- `.sisyphus/evidence/task-11-apn-param.txt` — grep confirming no hardcoded carrier APN

## Task 9: ECM Bootstrap Script (2026-03-12)

### Files Created
- `scripts/ecm-bootstrap.sh` — idempotent ECM mode enforcer
- `units/lte-ecm-bootstrap.service` — oneshot systemd unit

### Key Design Decisions

#### Idempotency Gate First
- Script ALWAYS sends `AT+QCFG="usbnet"` query BEFORE any set command
- Parses response for `,1` (ECM indicator); if found, exits 0 immediately (no-op)
- Prevents unnecessary modem restarts on already-correct systems

#### AT Command Flow
1. `AT+QCFG="usbnet"` — query mode
2. If not ECM: `AT+QCFG="usbnet",1` — set ECM
3. `AT+CFUN=1,1` — restart modem (required for mode change to take effect)
4. `|| true` on CFUN=1,1 — modem may drop connection before ACKing the restart

#### Re-enumeration Polling
- Polls `lsusb -d 2c7c:0901` every 1s for up to `ECM_REENUM_TIMEOUT_S` seconds
- After re-enumeration: sleeps 2s to allow driver re-bind and ttyUSB node creation
- Re-runs `find-at-port.sh` after restart (device node index may change)
- Exits 3 (hardware error) if modem doesn't re-appear within timeout

#### Dry-Run Mode
- All AT commands replaced with log lines showing intent
- `ECM_DRY_RUN_ALREADY_ECM=1` env var simulates the "already ECM" idempotency path
- Default dry-run simulates NOT-ECM path (full bootstrap flow)
- `lsusb` poll replaced with a simulated success log line

#### Parameter Added to params.env
- `ECM_REENUM_TIMEOUT_S=30` — default USB re-enumeration wait (override-able)

### Evidence
- `.sisyphus/evidence/task-9-idempotent.txt` — dry-run "already ECM" path
- `.sisyphus/evidence/task-9-bootstrap.txt` — dry-run full bootstrap path

### Verification
- `bash -n scripts/ecm-bootstrap.sh` — passes clean
- Both dry-run paths execute to expected exit 0 with correct log lines


## Task 11: check-apn.sh (APN Verification Script)

- `set -euo pipefail` required — the existing file had `set -uo pipefail` (missing `-e`); fixed
- All logging goes to **stderr** (`>&2`) — stdout is reserved for machine-parseable output (AT port path)
- CEREG response parsing: `+CEREG: <n>,<stat>` or `+CEREG: <stat>` — use `grep -oE '[0-9]+' | tail -1` to reliably extract stat
- `--mock-reg-status` and `--mock-apn-mode` flags enable unit testing without hardware
- APN logic gating: `if [[ -z "$LTE_APN" ]]` → auto path (no AT+CGDCONT sent); non-empty → explicit path
- `find-at-port.sh` called via `"${SCRIPT_DIR}/find-at-port.sh"` (not hardcoded path)
- Connectivity probe: `dig +short +timeout=3 google.com @8.8.8.8` (NOT ping/nslookup)
- params.env uses `LTE_APN` (not `APN`); CONVENTIONS.md says `APN` but actual file key is `LTE_APN`


## Task 7: USB Enumeration Guard (2026-03-12)
- Created `scripts/lte-enum-guard.sh` to gate downstream modem setup on `lsusb -d <VID:PID>` visibility.
- Script sources `config/params.env` and accepts `MODEM_VID_PID` fallback to existing `LTE_MODEM_VID_PID` so the guard stays parameter-driven without hardcoding the VID:PID in logic.
- Retry policy defaults: `ENUM_GUARD_MAX_RETRIES=5`, `ENUM_GUARD_RETRY_DELAY_S=2`; missing modem exits with code `3` (hardware error) and a timestamped error log.
- `--dry-run` logs the precautionary `systemctl mask nv-l4t-usb-device-mode` action without executing it.
- Live path masks `nv-l4t-usb-device-mode` as a precaution only, then fails clearly if the modem never appears on the XHCI host bus.
- Created `units/lte-enum-guard.service` as `Type=oneshot`, `RemainAfterExit=yes`, ordered `Before=lte-ecm-bootstrap.service`, with no reboot-based failure behavior.
- Added `docs/USB-TOPOLOGY.md` documenting `3610000.xhci` (host bus for modem) vs `3550000.xudc` (device/OTG controller) and why OTG role-switch code is intentionally absent.
- Evidence saved to `.sisyphus/evidence/task-7-enum-guard.txt` and `.sisyphus/evidence/task-7-no-otg-roleswitch.txt`.

## Task 7: USB-C Host Enumeration Guard (2026-03-12)
- Added `scripts/lte-enum-guard.sh` to source `config/params.env`, read `LTE_MODEM_VID_PID`, and retry `lsusb -d "$LTE_MODEM_VID_PID"` using `ENUM_GUARD_MAX_RETRIES` and `ENUM_GUARD_RETRY_DELAY`.
- Guard behavior is host-bus validation only: if the modem is absent after retries, the script logs a hardware error and exits 3 without attempting reboot or OTG role-switch writes.
- `--dry-run` logs the `systemctl mask --now nv-l4t-usb-device-mode` action without executing it; normal mode masks the service as a precaution only.
- Added `units/lte-enum-guard.service` to run before `lte-ecm-bootstrap.service` and documented controller separation in `docs/USB-TOPOLOGY.md`: `3610000.xhci` is the modem host path, `3550000.xudc` is unrelated gadget/OTG hardware.
- Evidence captured in `.sisyphus/evidence/task-7-enum-guard.txt` and `.sisyphus/evidence/task-7-no-otg-roleswitch.txt`.

## Task 15: Ethernet-Primary Route Arbitration (2026-03-12)

### What was verified
- `network/20-lte0.network`: `RouteMetric=1000` — already correct (Task 10), no change
- `network/10-eth0.network`: `RouteMetric=100` — already correct (Task 10), no change
- `network/10-eth1.network`: `RouteMetric=100` — already correct (Task 10), no change

### What was added
- `ConfigureWithoutCarrier=no` added to `[Network]` section of both Ethernet `.network` files
  - Prevents systemd-networkd from installing phantom routes when cable is unplugged
  - Without this, networkd may attempt DHCP on a carrier-less link and leave stale routes
  - LTE file (`20-lte0.network`) does NOT need this — lte0 is USB-based, not carrier-detect

### Test Created
- `tests/unit/test_route_metrics.sh` — 7 static tests, all pass:
  1. lte0 RouteMetric=1000
  2. eth0 RouteMetric=100
  3. eth1 RouteMetric=100
  4. Ethernet metrics (100,100) < LTE metric (1000)
  5. LTE metric (1000) > Ethernet metrics (100,100) — double-check
  6. eth0 has ConfigureWithoutCarrier=no
  7. eth1 has ConfigureWithoutCarrier=no

### ConfigureWithoutCarrier=no Rationale
- systemd-networkd by default will attempt to configure an interface even without a carrier signal
- For Ethernet: if cable is unplugged at boot, networkd would still try DHCP (eventually timing out)
  and may install a route with no active carrier — creating a phantom default route
- `ConfigureWithoutCarrier=no` disables this behavior: networkd waits for carrier before doing anything
- This ensures Ethernet routes are ONLY present when the cable is actually plugged in
- Combined with metric arbitration, this gives clean failover: Ethernet routes only exist when carrier present

### Evidence
- `.sisyphus/evidence/task-15-metrics.txt` — grep output + full test run (7 passed, 0 failed)
- `.sisyphus/evidence/task-15-warm-standby.txt` — SKIP (hardware test, no hardware available)

## Task 16: Telemetry-Oriented Tuning Defaults (2026-03-12)

### Files Created
- `docs/TUNING.md` — comprehensive tuning reference for operators (6 sections + deployment checklist)
- `scripts/verify-tuning.sh` — post-enumeration autosuspend/MTU/RAT-lock verification script

### Files Updated
- `config/params.env` — `LTE_RAT_LOCK_ENABLED=false` → `LTE_RAT_LOCK_ENABLED=0` with expanded opt-in comment

### Key Design Decisions

#### MTU Documentation
- MTU=1400 confirmed in `network/10-lte0.link` line 55 (`MTUBytes=1400`)
- Rationale: LTE GTP overhead ~20 bytes; 1400 provides 80-byte safety margin
- Not in `.network` file — single source of truth is `.link` (per systemd-networkd convention)

#### Autosuspend Verification
- udev rule sets `ATTR{power/control}="on"` and `ATTR{power/autosuspend_delay_ms}="-1"` at device enumeration
- Post-enumeration sysfs verification requires finding modem path dynamically via VID
- Strategy: `find /sys/bus/usb/devices/ -maxdepth 2 -name "idVendor"` + match `2c7c` content
- `power/control=on` is the critical check; `autosuspend_delay_ms=-1` is supplementary

#### RAT Lock as Opt-In
- `LTE_RAT_LOCK_ENABLED=0` — default stays auto mode (LTE → WCDMA → GSM fallback)
- AT+QNWPREFMDE=2 (LTE-only) is NEVER sent by bootstrap scripts
- Only `verify-tuning.sh` checks it — and only when `LTE_RAT_LOCK_ENABLED=1` is set
- verify-tuning.sh checks confirm the command is absent from all non-verify scripts

#### QUIC Keepalive (Documentation Only)
- Current: `keepalive_ms=15000`; Recommended: `10000` for aggressive NAT environments
- Chinese carriers (China Mobile/Unicom/Telecom) observed NAT timeout < 15s for UDP
- relay_params.yaml NOT modified — this is app-level config, not OS-level
- Guidance documented in TUNING.md §4

#### Carrier NAT Probe
- ICMP ping unreliable (carrier NAT blocks ICMP)
- `dig +short +timeout=3 google.com @8.8.8.8` is the reliable probe method
- Documented in TUNING.md §5 (Carrier NAT Behavior)

#### verify-tuning.sh Architecture
- Sources `config/params.env` for `LTE_MODEM_VID_PID`, `LTE_RAT_LOCK_ENABLED`, `LTE_MTU`
- 4 checks: autosuspend (sysfs), MTU (static file), RAT lock (AT, conditional), autosuspend delay (sysfs)
- `--dry-run` flag: all 4 checks skip gracefully with logged intent
- Dynamic sysfs path discovery: find idVendor file matching `2c7c` VID
- AT port discovery: delegates to `scripts/find-at-port.sh` (never hardcoded)
- Exit 4 on check failure; Exit 0 on all pass; skips in dry-run don't count as failures
- `set -euo pipefail` NOT added per MUST NOT DO in task spec

### Evidence
- `.sisyphus/evidence/task-16-mtu.txt` — grep confirming MTUBytes=1400
- `.sisyphus/evidence/task-16-autosuspend-verify.txt` — dry-run output, all checks logged
- `.sisyphus/evidence/task-16-rat-opt-in.txt` — confirms QNWPREFMDE absent from bootstrap scripts
- `.sisyphus/evidence/task-16-keepalive-guidance.txt` — TUNING.md keepalive section excerpt

## Task 13: LTE Watchdog State Machine (2026-03-12)

- Implemented `scripts/lte-watchdog.sh` with 5 explicit states: `HEALTHY`, `DEGRADED`, `RECOVERING`, `NO_COVERAGE`, `FAILED`.
- Transition logging is explicit and timestamped in conventions format: `STATE <old> -> <new>: <reason>` using `[YYYY-MM-DD HH:MM:SS] [LEVEL] message`.
- Health model checks 3 layers in strict order:
  1. Interface up (`ip link show lte0`)
  2. IPv4 assigned (`ip -4 addr show lte0`)
  3. DNS reachability (`dig +short +timeout=3 -b <lte-ip> google.com @8.8.8.8`)
- Connectivity probe uses DNS (not ping) to tolerate carrier ICMP filtering/NAT behavior.
- `DEGRADED -> RECOVERING` guarded by `LTE_WATCHDOG_GRACE_CHECKS=2` to reduce thrash on transient dips.
- `NO_COVERAGE` is gated by LTE registration (`AT+CEREG?`, stat not in `{1,5}`) and explicitly suppresses recovery hook execution.
- Recovery logic is externalized only: watchdog invokes `scripts/lte-recovery.sh --level N` when executable exists; no inline recovery executors implemented.
- Terminal behavior: `FAILED` logs operator-intervention message, writes state file, and exits `0` (systemd policy handles restart behavior).
- Singleton guard uses PID lockfile with stale-lock cleanup (`kill -0` check) before acquiring a new lock.
- Added testability hooks via env overrides: `LTE_WATCHDOG_MOCK_MODE`, mocked interface/IP/DNS/CEREG, and `LTE_WATCHDOG_ONE_SHOT`.
- Added `units/lte-watchdog.service` (Type=simple, journal logging, restart on failure).
- Added params in `config/params.env`: watchdog intervals, grace checks, and max recovery level.
- Added `tests/unit/test_watchdog.sh` with coverage for singleton, NO_COVERAGE no-recovery path, transition logging, no reboot action, and syntax check.
- Evidence generated: `task-13-singleton.txt`, `task-13-no-coverage.txt`, `task-13-state-log.txt`, `task-13-no-reboot.txt`.

## Task 14: Recovery Executors — Staged Ladder L1-L4 (2026-03-12)

### Files Created
- `scripts/lte-recovery.sh` — four-level recovery ladder called by watchdog as `--level N`
- `tests/unit/test_recovery.sh` — 8 unit tests (all offline/dry-run, 8 passed, 0 failed)

### Recovery Ladder Design
- L1: `networkctl renew lte0` — DHCP renew (grace 10s after success)
- L2: `ip link set lte0 down; sleep 2; ip link set lte0 up` + `networkctl renew` + wait 10s for IPv4 (grace 15s)
- L3: USB rebind via `cdc_ether` unbind/bind using dynamically derived sysfs path (grace 30s)
- L4: `AT+CFUN=1,1` via `find-at-port.sh` + wait for USB re-enumeration up to `ECM_REENUM_TIMEOUT_S` (grace 30s)
- NO Level 5 / host reboot — hard guardrail per CONVENTIONS.md §1.1

### L3 Dynamic USB Path Pattern
- Use `readlink -f /sys/class/net/lte0/device` to get the USB interface sysfs path dynamically
- `basename` of that path yields the USB interface ID (e.g. `1-1.1:1.0`)
- Write that ID to `/sys/bus/usb/drivers/cdc_ether/unbind` and `/bind`
- Never hardcode paths like `/sys/bus/usb/devices/1-1` — USB enumeration order is not stable

### L4 AT Reset Pattern
- `exec 3<>"$at_port"` opens the port bidirectional
- `printf 'AT+CFUN=1,1\r\n' >&3` sends the reset command
- Wrapped in `|| true` — modem drops connection before ACKing the restart
- Poll `lsusb -d $LTE_MODEM_VID_PID` for up to `ECM_REENUM_TIMEOUT_S` (30s) for re-enumeration
- Sleep 3s after re-enumeration for driver re-bind
- Then poll `ip link show lte0` for up to 30s for interface to reappear

### Test Patterns
- `--mock-port PATH` skips `find-at-port.sh` entirely (L4 unit test path)
- `--dry-run` exits 0 without touching hardware at every level
- No-reboot check: `grep -nE '\breboot\b...' | grep -vE '^[0-9]+:[[:space:]]*#'` to exclude comment lines
- Do NOT use `set -euo pipefail` in test scripts (arithmetic `((PASS_COUNT++))` fails when count=0)

### Key Conventions Followed
- All logs to stderr; stdout clean
- `source config/params.env` at start; use `LTE_MODEM_VID_PID`, `ECM_REENUM_TIMEOUT_S`, `LTE_USB_DRIVER`, `LTE_INTERFACE_NAME`
- Exit 2 for config errors (missing/invalid `--level`), exit 1 for recovery failures, exit 0 for success
- Grace periods baked into each level (sleep after successful exit, before returning to watchdog)


## Task 17: Hardware-in-loop smoke runner (2026-03-12)
- Created `tests/integration/smoke.sh` as an executable hardware-in-loop smoke runner (not a unit test), sourcing both `config/params.env` and `tests/lib/evidence.sh`.
- Implemented exactly 11 ordered checks with required names and `[PASS]`/`[FAIL]` reporting style:
  1. `usb-enum`
  2. `cdc-ether-driver`
  3. `lte0-up-ipv4`
  4. `lte0-mtu`
  5. `autosuspend-off`
  6. `ecm-mode`
  7. `sim-ready`
  8. `lte-data`
  9. `apn-auto`
  10. `default-route-lte`
  11. `eth-metric-lower` (conditional skip when Ethernet default route absent)
- Evidence tee is enabled at script start to `.sisyphus/evidence/smoke-<timestamp>.txt` using `exec > >(tee -a "$EVIDENCE_FILE") 2>&1`.
- AT interactions are dynamic-port only via `scripts/find-at-port.sh`; no hardcoded `/dev/ttyUSBx`.
- Autosuspend check follows dynamic sysfs resolution from `/sys/class/net/lte0/device` and validates `power/control=on`.
- Data connectivity check uses `dig` bound to `lte0` IP first, then `curl --interface lte0` fallback if `dig` is unavailable.
- Added `save_evidence "smoke-latest.txt"` breadcrumb plus final `summary` handling and explicit final line `RESULTS: N passed, M failed`.
- Created stub evidence file `.sisyphus/evidence/task-17-smoke-pass.txt` documenting script completion and deferred hardware execution.
- Syntax verification completed: `bash -n tests/integration/smoke.sh` passed.

## Task 19: Failure Injection Tests (2026-03-12)
- failure_inject.sh: 5 scenarios (A-E)
- Non-disruptive by default: A, B, D auto; C, E require --all or explicit name
- Scenario D: trap-based iptables cleanup (critical — must never leave DROP rule behind)
- Scenario D: checks watchdog state file and recovery log for NO_COVERAGE + no executor call
- AT commands for Scenario E: AT+CFUN=4 (airplane), AT+CFUN=1 (restore)
- State file for watchdog state: check scripts/lte-watchdog.sh for STATE_FILE path

## Task 20: Deployment Installer/Uninstaller (2026-03-12)
- Added `install.sh` and `uninstall.sh` at repo root with `#!/usr/bin/env bash` and **no** `set -euo pipefail` per deployment-script guardrail.
- Both scripts enforce root with `[[ $EUID -ne 0 ]]` and exit code `5` for permission errors.
- Both scripts implement `--dry-run` and `--yes`; without `--yes` they prompt interactively with `Proceed? [y/N]`.
- Install mapping implemented exactly for 17 artifacts: udev rule, networkd `.link/.network` files, 3 systemd units, 7 library scripts, `params.env`, and logrotate config.
- Install flow is idempotent: `mkdir -p`, `cp -f`, and pre-overwrite backup only when destination differs (`! cmp -s src dst`) to `dst.bak`.
- Post-install actions implemented in order: mask `nv-l4t-usb-device-mode` (tolerated), daemon-reload, udev reload+trigger, enable/start 3 LTE services.
- Uninstall flow is idempotent: stop+disable services (tolerated), unmask precautionary service (tolerated), remove installed files if present, then remove install dirs only if empty.
- Added explicit DRY RUN banner line in both scripts so evidence files clearly show simulation mode before action logs.
- Syntax checks passed: `bash -n install.sh && bash -n uninstall.sh`.
- Evidence generated: `.sisyphus/evidence/task-20-install.txt` and `.sisyphus/evidence/task-20-uninstall.txt` with DRY RUN command/file listings.

## Task 21: Troubleshooting doc created (2026-03-12)

- Added `docs/troubleshooting.md` — a field guide covering the seven required scenarios, quick-reference table, and evidence-pack instructions.
- Ensured every AT interaction references `scripts/find-at-port.sh` (no hardcoded /dev/ttyUSBx).
- Explicitly forbids host reboot recommendations; replaced any reboot suggestion with evidence-pack + support escalation.
- Quick-reference command table maps each symptom to first command and where to look.
- Evidence pack usage documented, pointing to `/usr/local/lib/lte-module/lte-evidence-pack.sh` and `scripts/lte-evidence-pack.sh` (dry-run supported).

(Appended 2026-03-12)

## Task 22: Acceptance Test Checklist (2026-03-12)

### failure_inject.sh argument interface
- Accepts positional args: `scenario-a`, `scenario-b`, etc. (NOT `--scenarios a,b`)
- Default (no args): runs scenario-a, scenario-b, scenario-d
- `--all` or `all` runs all 5 scenarios
- Calls `require_hardware` internally; if `HARDWARE_TESTS!=1`, skips all and exits 0

### lte-evidence-pack.sh --dry-run
- Exits 0 even in dry-run mode (no services needed)
- All output goes to stderr; stdout is empty
- Safe to call unconditionally in acceptance testing

### Acceptance script pattern
- Use `SECONDS` builtin for elapsed time (no subshell needed)
- Use `exec > >(tee -a "$EVIDENCE_FILE") 2>&1` before any output to capture everything
- Arrays (`STEP_RESULTS`, `STEP_NAMES`, `STEP_TIMES`) with `$((i + 1))` indexing for summary
- Never `exit` early on step failure — accumulate into `FAIL_COUNT`, exit at end
- `hw_required` param (0/1) + `SKIP_HARDWARE` flag cleanly gates hardware steps

### validate.sh behavior
- `scripts/validate.sh --ci` runs BOTH static validation AND unit tests (it's a wrapper)
- So Step 1 (validate.sh --ci) + Step 2 (run_all.sh) duplicates unit test execution
- This is intentional per the acceptance spec — belt-and-suspenders

## 2026-03-12 — F1 compliance audit learnings
- Full 22-task acceptance cross-check found critical implementation-to-plan mismatches in Tasks 9, 18, and 20.
- Task 9 gap: ecm-bootstrap enforces usbnet mode but does not re-query AT+QCFG="usbnet" after reboot/re-enumeration, so post-reset ECM verification is incomplete.
- Task 18 gap: evidence pack state file collection uses /tmp/lte-watchdog-state and /tmp/lte-watchdog.lock while watchdog defaults are /tmp/lte-watchdog.state and /tmp/lte-watchdog.pid.
- Task 20 gap: installer copies runtime scripts to /usr/local/lib/lte-module, but units ExecStart paths reference /opt/lte_module and /opt/lte-module, causing service path incoherence.
- Global guardrails scan: no active reboot command in scripts, no hardcoded /dev/ttyUSB2 in scripts, no NetworkManager/qmi/mbim in scripts, no set -euo pipefail in tests.


## 2026-03-12 — F4 scope fidelity audit learnings
- Ethernet-preferred routing is implemented in active config (not just docs): `RouteMetric=100` on both Ethernet `.network` files and `RouteMetric=1000` on `network/20-lte0.network`, validated again by `tests/unit/test_route_metrics.sh` PASS output.
- No-host-reboot guardrail is enforced in executable paths: active code scan over `scripts/`, `units/`, installers, rules, and network config found no reboot/shutdown/systemctl reboot actions.
- Out-of-scope scans can produce false positives from comments/non-goal text; final judgment must distinguish implementation from explanatory guardrail text (e.g., "NOT NetworkManager" comments, no-GPS explanatory wording).
- `nv-l4t-usb-device-mode` masking in `scripts/lte-enum-guard.sh` is precautionary conflict-avoidance and not OTG role-switch logic; treat as in-scope when no `/sys` role-switch writes exist.
