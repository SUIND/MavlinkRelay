# EC200U-CN ECM Deployment on Jetson Xavier NX (Quark USB-C OTG)

## TL;DR

> **Quick Summary**: Build a deterministic ECM-mode bring-up and recovery stack for a 7SEMI USB-C modem on the Quark USB-C OTG port, managed by `systemd-networkd`, with Ethernet preferred when present and LTE as fallback.
>
> **Deliverables**:
> - ECM bootstrap and modem setup scripts
> - `udev` + `systemd-networkd` + `systemd` service set for stable `lte0` bring-up
> - Layered watchdog/recovery flow that never reboots the host
> - Hardware-in-loop validation suite and deployment checklist
>
> **Estimated Effort**: Medium
> **Parallel Execution**: YES - 4 waves + final verification
> **Critical Path**: USB-C host role → ECM bootstrap → stable `lte0` networkd config → watchdog/recovery → hardware validation

---

## Context

### Original Request
Research what is required to reliably connect a 7SEMI LTE modem using Quectel EC200U-CN to a Jetson Xavier NX on a Connect Tech Quark carrier board in ECM mode so it appears as a native interface such as `usb0`, and identify performance/reliability options for bidirectional drone telemetry over QUIC in remote locations.

### Interview Summary
**Key Discussions**:
- ECM mode is the target; no QMI/MBIM implementation in this plan.
- Host network owner should be `systemd-networkd`.
- The modem is the **USB-C** 7SEMI form factor and will use the **Quark USB-C OTG port**.
- LTE failures must **never** reboot the Jetson host.
- Ethernet should become the **primary** uplink whenever plugged in; LTE is fallback.
- APN should first be tested in auto/default mode; explicit APN support is required only as a fallback path.

**Research Findings**:
- EC200U-CN ECM mode is typically enabled with `AT+QCFG="usbnet",1`, followed by modem restart.
- In ECM mode the modem should enumerate as a Linux USB NIC via `cdc_ether`/`usbnet`, while AT serial ports remain available separately.
- Jetson `nv-l4t-usb-device-mode` conflicts with USB gadget/device-mode behavior and must be disabled for this deployment.
- USB-C modem form factor likely has no dedicated hardware reset line exposed to the carrier, so recovery must stop at interface/USB/AT-reset levels and never escalate to host reboot.

### Metis Review
**Identified Gaps** (addressed):
- Port-role ambiguity on the Quark USB-C OTG path is now explicit: host-role assertion is a required first-class task.
- Recovery scope is locked: no QMI/MBIM, no NetworkManager, no host reboot, no GPS/NMEA, no firmware update, no band locking, no IPv6.
- APN handling is clarified: validate auto/default first, then parameterize explicit APN fallback.
- Routing policy is explicit: Ethernet preferred when healthy; LTE fallback only.

---

## Work Objectives

### Core Objective
Produce a robust host-side deployment package that makes the EC200U-CN USB-C modem come up in ECM mode as a stable Linux interface (`lte0`), keeps telemetry connectivity healthy for QUIC workloads, and recovers from LTE/interface faults without ever rebooting the Jetson host.

### Concrete Deliverables
- Deployment directory structure for scripts, units, rules, tests, and docs
- ECM bootstrap script with dynamic AT-port discovery and idempotent USB-mode enforcement
- `udev` rules for ModemManager ignore, autosuspend control, and modem identification
- `systemd-networkd` `.link` and `.network` files for `lte0`
- `systemd` services for USB-C OTG host-role assertion, modem setup, and watchdog/recovery
- Validation scripts for ECM bring-up, routing preference, APN fallback, and recovery steps
- Deployment/troubleshooting documentation

### Definition of Done
- [ ] On boot, with only the USB-C modem attached, Jetson exposes a stable `lte0` interface and gains routed IPv4 connectivity over LTE without manual intervention.
- [ ] With Ethernet plugged in, route preference shifts to Ethernet while LTE remains available as fallback.
- [ ] Recoverable LTE failures are handled by service logic without rebooting the Jetson host.
- [ ] Hardware-in-loop smoke tests and documented recovery tests pass.

### Must Have
- Deterministic USB-C OTG host-mode bring-up
- Idempotent ECM-mode enforcement
- Dynamic AT-port discovery
- `systemd-networkd`-managed `lte0`
- Ethernet-preferred routing policy
- No-host-reboot recovery ladder
- APN auto/default verification plus explicit APN fallback support

### Must NOT Have (Guardrails)
- No QMI/MBIM implementation
- No NetworkManager support
- No host reboot as LTE recovery action
- No hardcoded `/dev/ttyUSB2`
- No dependence on volatile interface name `usb0`
- No IPv6 on LTE unless explicitly requested later
- No GPS/NMEA, modem firmware update, or RF band-lock scope creep

---

## Verification Strategy

> **ZERO HUMAN INTERVENTION** — all verification is agent-executed where possible. Hardware-in-loop tests are scripted and executable.

### Test Decision
- **Infrastructure exists**: NO
- **Automated tests**: TDD for script logic + hardware-in-loop scripted integration verification
- **Framework**: shell-based test harness (`bash`, `shellcheck`, integration scripts)
- **If TDD**: logic-first scripts and config generators follow RED → GREEN → REFACTOR before hardware validation

### QA Policy
Every task includes agent-executed QA scenarios and evidence capture under `.sisyphus/evidence/`.

- **CLI / services**: `bash` + `systemctl` + `networkctl` + `ip` + `udevadm`
- **Hardware integration**: scripted AT checks, USB enumeration checks, DHCP/routing checks
- **Static validation**: `bash -n`, `shellcheck`, config inspection, grep/AST checks for forbidden patterns

---

## Execution Strategy

### Parallel Execution Waves

```
Wave 1 (Start Immediately — structure + interface ownership):
├── Task 1: Project skeleton + conventions
├── Task 2: USB modem identification + udev rules
├── Task 3: Persistent network naming via .link
├── Task 4: Ethernet-preferred routing policy design
├── Task 5: Test harness skeleton (unit/integration/evidence)
└── Task 6: Non-goals + deployment assumptions docs

Wave 2 (After Wave 1 — bring-up foundation):
├── Task 7: USB-C OTG host-role assertion service
├── Task 8: Dynamic AT-port discovery library/script
├── Task 9: ECM bootstrap + idempotent usbnet enforcement
├── Task 10: systemd-networkd LTE DHCP config
├── Task 11: APN auto-detect / explicit fallback logic
└── Task 12: Static validation + offline smoke tests

Wave 3 (After Wave 2 — recovery + routing behavior):
├── Task 13: LTE health model and recovery state machine
├── Task 14: Recovery executors (link bounce / DHCP renew / USB rebind / AT reset)
├── Task 15: Ethernet-primary route arbitration
├── Task 16: Telemetry-oriented tuning defaults (MTU / keepalive guidance / autosuspend proof)
└── Task 17: Hardware-in-loop smoke runner

Wave 4 (After Wave 3 — hardening + operator usability):
├── Task 18: Persistent logging and evidence packaging
├── Task 19: Failure-injection test scripts
├── Task 20: Deployment installer / uninstaller
├── Task 21: Field troubleshooting guide
└── Task 22: Acceptance test checklist wrapper

Wave FINAL (After ALL tasks — independent review, 4 parallel):
├── Task F1: Plan compliance audit
├── Task F2: Code quality + shell/static review
├── Task F3: Hardware validation replay
└── Task F4: Scope fidelity + routing policy audit

Critical Path: 7 → 8 → 9 → 10 → 13 → 14 → 17 → 22 → F1-F4
Parallel Speedup: ~65% faster than sequential
Max Concurrent: 6
```

### Dependency Matrix

- **1**: — → 7, 8, 20
- **2**: — → 9, 16, 19
- **3**: — → 10, 15, 22
- **4**: — → 15, 21, 22
- **5**: — → 12, 17, 19, 22
- **6**: — → 21, F1, F4
- **7**: 1 → 9, 17
- **8**: 1 → 9, 11, 14, 19
- **9**: 2, 7, 8 → 11, 17, 19
- **10**: 3, 9 → 13, 15, 17
- **11**: 8, 9 → 17, 19, 22
- **12**: 5, 8, 9, 10, 11 → 20
- **13**: 10 → 14, 17, 18
- **14**: 8, 13 → 17, 19, 22
- **15**: 3, 4, 10 → 17, 22
- **16**: 2, 9, 10 → 17, 21, 22
- **17**: 5, 7, 9, 10, 11, 13, 14, 15, 16 → 18, 19, 21, 22
- **18**: 13, 17 → F1, F3
- **19**: 2, 5, 8, 9, 11, 14, 17 → 22, F3
- **20**: 1, 12 → 22, F2
- **21**: 4, 6, 16, 17 → F1, F4
- **22**: 3, 4, 5, 11, 14, 15, 16, 17, 19, 20 → F1, F3, F4

### Agent Dispatch Summary

- **Wave 1**: T1 `quick`, T2 `quick`, T3 `quick`, T4 `business-logic`, T5 `quick`, T6 `writing`
- **Wave 2**: T7 `unspecified-high`, T8 `precise`, T9 `business-logic`, T10 `quick`, T11 `business-logic`, T12 `precise`
- **Wave 3**: T13 `deep`, T14 `precise`, T15 `business-logic`, T16 `precise`, T17 `deep`
- **Wave 4**: T18 `quick`, T19 `deep`, T20 `quick`, T21 `writing`, T22 `business-logic`
- **Final**: F1 `oracle`, F2 `precise`, F3 `unspecified-high`, F4 `deep`

---

## TODOs

- [x] 1. Create LTE deployment skeleton and conventions

  **What to do**:
  - Create the deployment directory structure for scripts, units, rules, tests, and docs.
  - Add a conventions document covering naming, logging format, evidence paths, dry-run rules, and hard guardrails.
  - Establish a single place for deployment parameters and environment assumptions.

  **Must NOT do**:
  - Do not add modem bring-up logic yet.
  - Do not introduce NetworkManager or QMI/MBIM support.

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: foundational project setup with low complexity.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: 7, 8, 20
  - **Blocked By**: None

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` - confirmed requirements, routing policy, and guardrails.

  **Acceptance Criteria**:
  - [ ] Directory layout exists for scripts, units, rules, tests, docs, and evidence.
  - [ ] Conventions document explicitly states no-host-reboot and Ethernet-primary policy.

  **QA Scenarios**:
  ```
  Scenario: Skeleton exists and conventions are recorded
    Tool: Bash
    Preconditions: Repository checked out
    Steps:
      1. Run `ls` on expected deployment directories
      2. Read the conventions document
      3. Assert required guardrail text is present
    Expected Result: All expected directories and conventions file exist
    Failure Indicators: Missing directory or missing guardrail text
    Evidence: .sisyphus/evidence/task-1-skeleton.txt

  Scenario: Forbidden scope is documented as non-goal only
    Tool: Bash
    Preconditions: Conventions document exists
    Steps:
      1. Search docs for `QMI|MBIM|NetworkManager|reboot`
      2. Assert active support language is absent
    Expected Result: Forbidden items appear only in non-goal/guardrail context
    Evidence: .sisyphus/evidence/task-1-scope-scan.txt
  ```

- [x] 2. Add USB modem identification and targeted udev rules

  **What to do**:
  - Add udev rules for the EC200U-CN USB-C modem.
  - Ignore ModemManager for this device.
  - Disable USB autosuspend for this modem only.

  **Must NOT do**:
  - Do not apply wildcard rules to unrelated USB devices.
  - Do not leave ModemManager interference unresolved.

  **Recommended Agent Profile**:
  - **Category**: `quick`
    - Reason: focused hardware-identification rule work.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: 9, 16, 19
  - **Blocked By**: None

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` - captures ModemManager and autosuspend concerns.

  **Acceptance Criteria**:
  - [ ] udev rules match modem hardware identifiers.
  - [ ] Rule sets `ID_MM_DEVICE_IGNORE` and targeted autosuspend policy.

  **QA Scenarios**:
  ```
  Scenario: Udev rule contains required modem directives
    Tool: Bash
    Preconditions: Rule file exists
    Steps:
      1. Read the udev rule file
      2. Assert modem VID:PID targeting is present
      3. Assert `ID_MM_DEVICE_IGNORE` is set
      4. Assert autosuspend handling is defined
    Expected Result: Rule is complete and modem-specific
    Failure Indicators: Missing ignore or autosuspend directives
    Evidence: .sisyphus/evidence/task-2-udev.txt

  Scenario: Rule does not affect unrelated USB devices
    Tool: Bash
    Preconditions: Rule file exists
    Steps:
      1. Search the rule for broad USB wildcards
      2. Assert matches are constrained to modem IDs or path
    Expected Result: Rule scope is narrow and safe
    Evidence: .sisyphus/evidence/task-2-targeting.txt
  ```

- [x] 3. Add persistent `lte0` naming with systemd `.link`

  **What to do**:
  - Add `.link` configuration assigning the LTE interface to `lte0`.
  - Match on stable modem properties such as MAC or USB path.
  - Make naming independent from `usb0`.

  **Must NOT do**:
  - Do not depend on kernel-assigned interface names.
  - Do not assume the MAC is stable without documenting verification.

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: 10, 15, 22
  - **Blocked By**: None

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` - stable naming requirement and avoidance of `usb0` coupling.

  **Acceptance Criteria**:
  - [ ] `.link` file sets `Name=lte0`.
  - [ ] Matching strategy is explicit and testable.

  **QA Scenarios**:
  ```
  Scenario: Link file defines lte0 naming
    Tool: Bash
    Preconditions: .link file exists
    Steps:
      1. Read the .link file
      2. Assert `Name=lte0` is present
      3. Assert stable match fields are present
    Expected Result: Interface can be persistently named `lte0`
    Failure Indicators: Missing `Name=lte0` or no stable match fields
    Evidence: .sisyphus/evidence/task-3-link.txt

  Scenario: No active usb0 dependency remains
    Tool: Bash
    Preconditions: Config files exist
    Steps:
      1. Search deployment files for `usb0`
      2. Assert only explanatory references remain
    Expected Result: Active config targets `lte0` only
    Evidence: .sisyphus/evidence/task-3-usb0-scan.txt
  ```

- [x] 4. Define Ethernet-primary routing policy

  **What to do**:
  - Define route metric or policy routing behavior that prefers Ethernet when connected.
  - Keep LTE as fallback when Ethernet is absent or unhealthy.
  - Document how telemetry traffic should follow the preferred uplink.

  **Must NOT do**:
  - Do not allow LTE to override healthy Ethernet.
  - Do not require manual operator switching.

  **Recommended Agent Profile**:
  - **Category**: `business-logic`
    - Reason: route preference is a behavior-policy task.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: 15, 21, 22
  - **Blocked By**: None

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` - confirms Ethernet primary / LTE fallback requirement.

  **Acceptance Criteria**:
  - [ ] Route policy explicitly prefers Ethernet over LTE.
  - [ ] LTE fallback behavior is explicitly defined.

  **QA Scenarios**:
  ```
  Scenario: Route policy prefers Ethernet
    Tool: Bash
    Preconditions: Routing config or doc exists
    Steps:
      1. Read route policy files
      2. Assert Ethernet has the preferred metric/rule
    Expected Result: Ethernet is the primary uplink
    Failure Indicators: LTE equal or higher priority than Ethernet
    Evidence: .sisyphus/evidence/task-4-route-policy.txt

  Scenario: LTE fallback remains available
    Tool: Bash
    Preconditions: Routing config or doc exists
    Steps:
      1. Inspect fallback behavior documentation/config
      2. Assert LTE takeover is automatic when Ethernet disappears
    Expected Result: LTE serves as fallback only
    Evidence: .sisyphus/evidence/task-4-fallback.txt
  ```

- [x] 5. Create the test harness skeleton and evidence conventions

  **What to do**:
  - Create unit and integration test directories with runners.
  - Add a common evidence/logging helper.
  - Mark hardware-required tests clearly and keep offline logic tests runnable without hardware.

  **Must NOT do**:
  - Do not make all tests hardware-dependent.
  - Do not omit parseable pass/fail output.

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: 12, 17, 19, 22
  - **Blocked By**: None

  **References**:
  - Metis review output - requires split unit/integration tests and structured `[PASS]/[FAIL]` output.

  **Acceptance Criteria**:
  - [ ] Unit and integration runners exist.
  - [ ] Hardware-in-loop tests are clearly marked.
  - [ ] Evidence helper emits parseable output.

  **QA Scenarios**:
  ```
  Scenario: Test harness runs offline
    Tool: Bash
    Preconditions: Test harness files exist
    Steps:
      1. Run unit test runner without hardware attached
      2. Assert it exits successfully
      3. Assert output contains structured pass/fail markers
    Expected Result: Offline test harness works without modem hardware
    Evidence: .sisyphus/evidence/task-5-unit-runner.txt

  Scenario: Hardware tests are clearly gated
    Tool: Bash
    Preconditions: Integration tests exist
    Steps:
      1. Search integration tests for hardware marker text
      2. Assert every hardware test contains the marker
    Expected Result: Hardware-required tests are explicitly labeled
    Evidence: .sisyphus/evidence/task-5-hw-markers.txt
  ```

- [x] 6. Write non-goals and deployment assumptions documentation

  **What to do**:
  - Document the exact in-scope and out-of-scope boundaries.
  - Record assumptions about USB-C OTG usage, ECM-only mode, no host reboot, IPv4-only LTE, and Ethernet preference.
  - Capture unanswered operator inputs as deployment variables only.

  **Must NOT do**:
  - Do not leave scope boundaries implicit.
  - Do not describe unsupported features as active implementation goals.

  **Recommended Agent Profile**:
  - **Category**: `writing`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 1
  - **Blocks**: 21, F1, F4
  - **Blocked By**: None

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` - source of all confirmed assumptions and exclusions.

  **Acceptance Criteria**:
  - [ ] Documentation includes a Non-Goals section.
  - [ ] Documentation explicitly forbids host reboot for LTE recovery.

  **QA Scenarios**:
  ```
  Scenario: Non-goals are explicit
    Tool: Bash
    Preconditions: Scope document exists
    Steps:
      1. Read the scope document
      2. Assert Non-Goals section includes QMI, MBIM, NetworkManager, IPv6, firmware update, GPS/NMEA
    Expected Result: Scope boundaries are explicit
    Evidence: .sisyphus/evidence/task-6-nongoals.txt

  Scenario: Recovery guardrail is explicit
    Tool: Bash
    Preconditions: Scope document exists
    Steps:
      1. Search for `reboot` and `host reboot`
      2. Assert text forbids host reboot as recovery action
    Expected Result: No-host-reboot rule is clearly documented
    Evidence: .sisyphus/evidence/task-6-reboot-guardrail.txt
  ```

---

- [x] 7. Add USB-C host enumeration guard service

  **What to do**:
  - **Hardware finding**: Real hardware dmesg confirms the modem enumerates on **`usb-3610000.xhci-1`** — the Quark's XHCI **host** controller — NOT the OTG/device controller (`3550000.xudc`). The USB-C port on the Quark already routes to the host bus; no OTG role-switch is required.
  - Add a systemd `oneshot` service that runs at boot and verifies the modem is visible on the XHCI bus (VID:PID `2c7c:0901`) before modem-setup continues. If not found, it retries up to N times with a brief delay and exits non-zero so downstream services do not start blindly.
  - Mask `nv-l4t-usb-device-mode` as a **precautionary** step (it controls the OTG/device bus `3550000.xudc`, which is a separate controller, but masking it prevents any future conflict if the Quark board revision or kernel update re-enables gadget mode).
  - Document the controller topology clearly so future maintainers understand why OTG role-switching code is absent.

  **Must NOT do**:
  - Do not write OTG role-switch code (`echo host > /sys/...`) — the hardware already presents as host; adding this would be wrong and fragile.
  - Do not assume `nv-l4t-usb-device-mode` is the root cause of any enumeration failure — it controls a different controller.
  - Do not continue to modem setup if `lsusb -d 2c7c:0901` or equivalent returns empty.

  **Recommended Agent Profile**:
  - **Category**: `unspecified-high`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2
  - **Blocks**: 9, 17
  - **Blocked By**: 1

  **References**:
  - **Hardware evidence** (from user dmesg): `usb 1-1: new SuperSpeed Plus Gen 2x1 USB device number 3 using xhci_hcd` followed by `cdc_ether 1-1:1.0 usb0: register 'cdc_ether'` — confirms host-mode XHCI enumeration.
  - **Controller separation**: `3610000.xhci` = XHCI host (modem attaches here). `3550000.xudc` = USB device/OTG controller (modem does NOT attach here). These are separate hardware blocks.
  - `nv-l4t-usb-device-mode` systemd unit controls `3550000.xudc` only — masking is precautionary, not load-bearing.
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — USB topology analysis and hardware confirmation section.

  **Acceptance Criteria**:
  - [ ] Service checks for modem VID:PID `2c7c:0901` on the USB bus before proceeding.
  - [ ] `nv-l4t-usb-device-mode` is masked (precautionary).
  - [ ] Service fails clearly (non-zero exit, logged message) if modem is absent after retries.
  - [ ] Documentation explains controller topology: XHCI host vs OTG device, and why no role-switch code is needed.

  **QA Scenarios**:
  ```
  Scenario: Enumeration guard detects modem presence
    Tool: Bash
    Preconditions: Service/script file exists
    Steps:
      1. Read the service/script
      2. Assert it queries USB bus for VID:PID 2c7c:0901 (e.g. lsusb -d 2c7c:0901 or udevadm query)
      3. Assert it exits non-zero if modem is absent after retries
      4. Assert success condition passes through to modem-setup start
    Expected Result: Script gates modem setup on confirmed USB presence
    Failure Indicators: Script has no USB presence check; continues regardless
    Evidence: .sisyphus/evidence/task-7-enum-guard.txt

  Scenario: OTG role-switch code is absent
    Tool: Bash
    Preconditions: All scripts/units exist
    Steps:
      1. Search deployment files for `3550000`, `xudc`, `echo host >`, `/sys/bus/platform/drivers/xudc`
      2. Assert zero active code references (documentation/comments are OK)
    Expected Result: No OTG role-switch code present — it is not needed
    Failure Indicators: Any active OTG role-switch code found
    Evidence: .sisyphus/evidence/task-7-no-otg-roleswitch.txt

  Scenario: nv-l4t-usb-device-mode is masked
    Tool: Bash
    Preconditions: Installer/setup has run
    Steps:
      1. Run `systemctl is-enabled nv-l4t-usb-device-mode`
      2. Assert output is `masked`
    Expected Result: Gadget-mode service is masked
    Evidence: .sisyphus/evidence/task-7-gadget-masked.txt
  ```

- [x] 8. Build dynamic AT-port discovery logic

  **What to do**:
  - Implement AT-port probing across candidate ttyUSB devices.
  - Return the first port that responds correctly to `AT`/`OK`.
  - Expose dry-run/mock behavior for offline testability.

  **Must NOT do**:
  - Do not hardcode `/dev/ttyUSB2`.
  - Do not assume port ordering is stable.

  **Recommended Agent Profile**:
  - **Category**: `precise`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2
  - **Blocks**: 9, 11, 14, 19
  - **Blocked By**: 1

  **References**:
  - Metis review - dynamic probing is mandatory because tty numbering is unstable.

  **Acceptance Criteria**:
  - [ ] Port discovery logic probes multiple ttyUSB candidates.
  - [ ] Offline unit tests exist for positive and negative probe results.

  **QA Scenarios**:
  ```
  Scenario: Offline AT-port probe test passes
    Tool: Bash
    Preconditions: Unit tests exist
    Steps:
      1. Run AT-port unit tests in mock mode
      2. Assert success and parseable test output
    Expected Result: Probe logic works without hardware
    Evidence: .sisyphus/evidence/task-8-probe-unit.txt

  Scenario: No hardcoded ttyUSB2 remains
    Tool: Bash
    Preconditions: Scripts exist
    Steps:
      1. Search project files for `/dev/ttyUSB2`
      2. Assert zero active matches
    Expected Result: Port selection is dynamic
    Evidence: .sisyphus/evidence/task-8-no-hardcode.txt
  ```

- [x] 9. Add ECM bootstrap and idempotent usbnet enforcement

  **What to do**:
  - Implement script logic to query current `usbnet` mode.
  - If not already ECM, set `AT+QCFG="usbnet",1` and trigger modem restart.
  - Wait for re-enumeration and confirm ECM networking and AT ports return.

  **Must NOT do**:
  - Do not blindly write usbnet mode every time.
  - Do not continue if ECM mode cannot be verified after reset.

  **Recommended Agent Profile**:
  - **Category**: `business-logic`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2
  - **Blocks**: 11, 17, 19
  - **Blocked By**: 2, 7, 8

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` - `AT+QCFG="usbnet",1` ECM guidance.
  - Metis review - script must query before writing and handle first-time bootstrap.

  **Acceptance Criteria**:
  - [ ] Script queries existing usbnet mode before changing anything.
  - [ ] ECM mode is verifiable after modem reset/re-enumeration.

  **QA Scenarios**:
  ```
  Scenario: Existing ECM mode does not force unnecessary reset
    Tool: Bash
    Preconditions: Mock or hardware path returns `usbnet,1`
    Steps:
      1. Run bootstrap script in a state where ECM is already active
      2. Assert it reports no mode change required
    Expected Result: Script is idempotent
    Evidence: .sisyphus/evidence/task-9-idempotent.txt

  Scenario: ECM bootstrap path enforces and verifies mode
    Tool: Bash
    Preconditions: Mock or hardware path simulates non-ECM initial mode
    Steps:
      1. Run bootstrap logic
      2. Assert it issues mode set + reset sequence
      3. Assert post-check requires ECM confirmation
    Expected Result: Script handles first-time ECM setup correctly
    Evidence: .sisyphus/evidence/task-9-bootstrap.txt
  ```

- [x] 10. Add `systemd-networkd` LTE DHCP configuration

  **What to do**:
  - Add `.network` configuration for `lte0`.
  - Enable IPv4 DHCP, disable IPv6 RA/default behavior, and document version-sensitive options.
  - Ensure configuration supports carrier loss behavior suitable for LTE.

  **Must NOT do**:
  - Do not enable IPv6 by default.
  - Do not use NetworkManager keyfiles or commands.

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2
  - **Blocks**: 13, 15, 17
  - **Blocked By**: 3, 9

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` - systemd-networkd choice, IPv4 focus.
  - Metis review - explicit IPv6 disable and version-aware options are required.

  **Acceptance Criteria**:
  - [ ] `.network` file targets `lte0` with DHCPv4.
  - [ ] IPv6 acceptance is explicitly disabled.

  **QA Scenarios**:
  ```
  Scenario: LTE networkd config is IPv4-only
    Tool: Bash
    Preconditions: .network file exists
    Steps:
      1. Read the .network file
      2. Assert DHCP is IPv4-only or equivalent
      3. Assert `IPv6AcceptRA=no` or equivalent disablement exists
    Expected Result: LTE config is IPv4-only by default
    Evidence: .sisyphus/evidence/task-10-networkd.txt

  Scenario: NetworkManager is not introduced
    Tool: Bash
    Preconditions: Config files exist
    Steps:
      1. Search project for `nmcli|NetworkManager`
      2. Assert zero active matches
    Expected Result: systemd-networkd is the sole network owner
    Evidence: .sisyphus/evidence/task-10-no-nm.txt
  ```

 - [x] 11. Add APN auto/default verification with explicit fallback support

  **What to do**:
  - Implement checks that try the modem’s default/automatic APN behavior first.
  - If auto/default does not yield a working data path, support explicit APN configuration via deployment parameters.
  - Keep APN logic decoupled from unrelated bring-up steps.

  **Must NOT do**:
  - Do not hardcode a carrier APN.
  - Do not require explicit APN if auto/default works.

  **Recommended Agent Profile**:
  - **Category**: `business-logic`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2
  - **Blocks**: 17, 19, 22
  - **Blocked By**: 8, 9

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` - APN should be tested in auto mode first.
  - Metis review - APN cannot be silently assumed.

  **Acceptance Criteria**:
  - [ ] Auto/default APN validation path exists.
  - [ ] Explicit APN parameter path exists as fallback only.

  **QA Scenarios**:
  ```
  Scenario: Auto APN path is attempted first
    Tool: Bash
    Preconditions: APN logic exists
    Steps:
      1. Inspect the APN setup logic
      2. Assert default/auto path is attempted before explicit APN override
    Expected Result: Auto/default behavior is the first path
    Evidence: .sisyphus/evidence/task-11-auto-apn.txt

  Scenario: Explicit APN remains parameterized
    Tool: Bash
    Preconditions: APN logic exists
    Steps:
      1. Search scripts/config for APN values
      2. Assert no carrier APN is hardcoded in logic
    Expected Result: APN fallback is deployment-configurable
    Evidence: .sisyphus/evidence/task-11-apn-param.txt
  ```

- [x] 12. Add offline static validation and smoke checks

  **What to do**:
  - Add syntax, lint, and basic config validation commands.
  - Verify scripts pass `bash -n` and `shellcheck`.
  - Add smoke checks that can run without hardware.

  **Must NOT do**:
  - Do not ship shell scripts without offline validation.
  - Do not make smoke validation depend on the modem.

  **Recommended Agent Profile**:
  - **Category**: `precise`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 2
  - **Blocks**: 20
  - **Blocked By**: 5, 8, 9, 10, 11

  **References**:
  - Metis review - all bash scripts must be syntax-checked offline.

  **Acceptance Criteria**:
  - [ ] Static validation runner exists.
  - [ ] Offline smoke path covers script/config sanity without hardware.

  **QA Scenarios**:
  ```
  Scenario: Static validation runner passes
    Tool: Bash
    Preconditions: Validation runner exists
    Steps:
      1. Run the static validation runner
      2. Assert `bash -n` and `shellcheck` checks pass
    Expected Result: Scripts are offline-validated
    Evidence: .sisyphus/evidence/task-12-static.txt

  Scenario: Offline smoke test does not require hardware
    Tool: Bash
    Preconditions: Smoke test exists
    Steps:
      1. Run smoke test on a system without modem hardware
      2. Assert it either passes offline checks or skips hardware sections cleanly
    Expected Result: Smoke path is CI-friendly
    Evidence: .sisyphus/evidence/task-12-smoke.txt
  ```

- [x] 13. Implement LTE health model and recovery state machine

  **What to do**:
  - Design and implement a watchdog daemon (shell script or small binary) that monitors `lte0` health at three layers:
    1. **Interface layer**: Is `lte0` present and UP? Check via `ip link show lte0`.
    2. **IP layer**: Does `lte0` have a valid IPv4 address? Check via `ip -4 addr show lte0`.
    3. **Connectivity layer**: Can we reach the internet/gateway? Use a lightweight probe (e.g., ICMP or DNS `dig`/`nslookup` against a known-stable target; do NOT use `ping` alone as carrier NAT may block ICMP — use a DNS resolution probe as primary).
  - State machine has these states: `HEALTHY`, `DEGRADED`, `RECOVERING`, `NO_COVERAGE`, `FAILED`.
    - `HEALTHY → DEGRADED` on any layer failure.
    - `DEGRADED → RECOVERING` after grace period (avoid thrashing on transient dips).
    - `RECOVERING → HEALTHY` if recovery executor succeeds and all layers pass.
    - `RECOVERING → FAILED` if all recovery levels exhausted.
    - `DEGRADED → NO_COVERAGE` if SIM/registration checks (`AT+CREG?`, `AT+CEREG?`) confirm no signal — watchdog waits and polls without escalating recovery executors (no point retrying USB rebind if there's no signal).
    - `FAILED` state is terminal per session — log, emit alert, and wait for operator or service restart.
  - Watchdog MUST be a singleton: use a PID/lockfile to prevent multiple instances.
  - Check interval: 15s nominal; reduce to 5s in `DEGRADED`/`RECOVERING`.
  - Log all state transitions with timestamps.
  - **No host reboot as a recovery action — ever**.

  **Must NOT do**:
  - Do not reboot the host for any LTE failure.
  - Do not conflate `NO_COVERAGE` (no signal) with hardware failure — they require different responses.
  - Do not start recovery executors while in `NO_COVERAGE` state.
  - Do not run as multiple concurrent instances (lockfile is mandatory).
  - Do not use `ping` alone as connectivity check — DNS probe is required.

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: state-machine design with multiple health layers and nuanced transition logic.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3
  - **Blocks**: 14, 17, 18
  - **Blocked By**: 10

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — no-reboot guardrail, no-coverage vs hardware-failure distinction, watchdog singleton requirement.
  - Metis review — "watchdog must distinguish no-coverage from hardware failure" and "watchdog must be a singleton."
  - `jetson/mavlink_quic_relay/config/relay_params.yaml` — QUIC reconnect backoff 1→2→4→8→16→30s; watchdog recovery timing should be compatible.
  - AT commands for registration check: `AT+CREG?` (GSM), `AT+CEREG?` (LTE EPS). Parse response format: `+CREG: <mode>,<stat>` — stat=1 (home) or stat=5 (roaming) = registered. stat=0,2,3,4 = not registered.

  **Acceptance Criteria**:
  - [ ] State machine has all five states with defined transitions.
  - [ ] `NO_COVERAGE` state does not trigger recovery executors.
  - [ ] Singleton lockfile prevents duplicate watchdog instances.
  - [ ] DNS probe (not just ICMP) is used for connectivity check.
  - [ ] All state transitions are logged with timestamps.
  - [ ] No host reboot action anywhere in the watchdog code.

  **QA Scenarios**:
  ```
  Scenario: Singleton enforcement prevents duplicate instances
    Tool: Bash
    Preconditions: Watchdog script exists
    Steps:
      1. Start watchdog in background
      2. Attempt to start a second instance
      3. Assert second instance exits non-zero or prints "already running"
      4. Kill background instance
    Expected Result: Only one watchdog runs at a time
    Failure Indicators: Two watchdog processes coexist
    Evidence: .sisyphus/evidence/task-13-singleton.txt

  Scenario: NO_COVERAGE state does not escalate
    Tool: Bash
    Preconditions: Watchdog has mock/injectable health probe
    Steps:
      1. Inject mock state: connectivity fail + registration check returns stat=0 (not registered)
      2. Run watchdog for 2 check cycles
      3. Assert state is NO_COVERAGE
      4. Assert no recovery executor was invoked
    Expected Result: Watchdog waits in NO_COVERAGE without triggering recovery
    Failure Indicators: Recovery executor called despite no-coverage condition
    Evidence: .sisyphus/evidence/task-13-no-coverage.txt

  Scenario: State transitions are logged
    Tool: Bash
    Preconditions: Watchdog runs through a HEALTHY→DEGRADED transition in mock mode
    Steps:
      1. Inject health probe failure
      2. Run watchdog check
      3. Read watchdog log output
      4. Assert log contains state transition with timestamp
    Expected Result: State changes are timestamped in logs
    Evidence: .sisyphus/evidence/task-13-state-log.txt

  Scenario: No reboot action exists anywhere
    Tool: Bash
    Preconditions: All watchdog code files exist
    Steps:
      1. Search watchdog scripts/code for `reboot`, `shutdown -r`, `systemctl reboot`
      2. Assert zero active matches
    Expected Result: Host reboot is entirely absent from watchdog logic
    Evidence: .sisyphus/evidence/task-13-no-reboot.txt
  ```

  **Commit**: YES (groups with 14)
  - Message: `feat(lte): add LTE health watchdog state machine`

---

- [x] 14. Implement recovery executors (staged ladder)

  **What to do**:
  - Implement four recovery executor functions/scripts, invoked in order by the watchdog state machine. Each level is only escalated to after the previous level has failed. After each executor, re-check all health layers before declaring success or escalating.
  - **Level 1 — DHCP renew**: `networkctl renew lte0` or `systemctl restart systemd-networkd-wait-online` equivalent. Fixes stale leases or IP loss without disrupting the interface. Fast, safe, low impact. (EC200U-CN's internal DHCP server hands short leases; this is the most common fix.)
  - **Level 2 — Link bounce**: `ip link set lte0 down && sleep 2 && ip link set lte0 up` + trigger DHCP again. Resets the Linux-side NIC state while leaving the USB device untouched.
  - **Level 3 — USB rebind**: Unbind and rebind the `cdc_ether` driver for the modem's USB path via sysfs (`echo <usb-path> > /sys/bus/usb/drivers/cdc_ether/unbind` then `bind`). This reinitializes the USB-to-Ethernet stack without unplugging. Use the confirmed USB path from Task 2/7 udev data.
  - **Level 4 — AT modem reset**: Send `AT+CFUN=1,1` (full modem restart) or `AT+QRST=1,0` via the dynamically-discovered AT port (Task 8). Wait for modem re-enumeration (up to 30s) and then restart from Level 1.
  - If all four levels fail: enter `FAILED` state, log prominently, do NOT reboot.
  - Each executor must return a clear pass/fail result so the watchdog can make the escalation decision.
  - Grace periods between levels: at least 10s after Level 1, 15s after Level 2, 30s after Level 3/4 for re-enumeration.

  **Must NOT do**:
  - Do not proceed to a higher level without first retrying and checking the lower level result.
  - Do not hardcode the USB sysfs path — derive it from the confirmed modem VID:PID using udev/sysfs lookup.
  - Do not include a Level 5 that reboots the host.
  - Do not invoke any recovery executor while in `NO_COVERAGE` state (watchdog handles this — executors should be callable independently but the watchdog gates invocation).

  **Recommended Agent Profile**:
  - **Category**: `precise`
    - Reason: hardware-level USB sysfs manipulation and AT command sequencing require precision.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3
  - **Blocks**: 17, 19, 22
  - **Blocked By**: 8, 13

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — four-level recovery ladder definition, AT reset commands.
  - **AT reset commands**: `AT+CFUN=1,1` (preferred — full function + restart) or `AT+QRST=1,0` (alternative).
  - **USB sysfs rebind pattern**: `/sys/bus/usb/drivers/cdc_ether/unbind` and `bind` — use the USB device path obtained from `udevadm info` for VID:PID `2c7c:0901`.
  - **Hardware-confirmed VID:PID**: `2c7c:0901`, driver `cdc_ether`, controller `3610000.xhci`.
  - Task 8 (AT-port discovery) — Level 4 executor depends on dynamic AT port; must call the discovery helper.
  - `jetson/mavlink_quic_relay/src/reconnect_manager.cpp` — app-level backoff 1→2→4→8→16→30s; Level 4 re-enumeration wait should align (30s matches app max backoff).

  **Acceptance Criteria**:
  - [ ] Four distinct executor levels exist.
  - [ ] Each executor returns a binary pass/fail.
  - [ ] Level 3 derives USB sysfs path dynamically (no hardcoded path).
  - [ ] Level 4 uses the AT discovery helper from Task 8.
  - [ ] No executor reboots the host.
  - [ ] Grace periods between levels are documented and implemented.

  **QA Scenarios**:
  ```
  Scenario: Level 1 (DHCP renew) executor returns pass/fail cleanly
    Tool: Bash
    Preconditions: Level 1 executor script exists; can be tested without modem if networkctl is mocked
    Steps:
      1. Call Level 1 executor
      2. Assert it returns 0 (success) or non-zero (failure) exit code
      3. Assert it emits a log line describing the action taken
    Expected Result: Clean pass/fail interface for watchdog integration
    Failure Indicators: Executor exits 0 even when DHCP renew fails; no log output
    Evidence: .sisyphus/evidence/task-14-level1.txt

  Scenario: Level 3 derives USB path dynamically
    Tool: Bash
    Preconditions: Level 3 executor script exists
    Steps:
      1. Read the Level 3 executor script
      2. Search for hardcoded sysfs USB paths (e.g. `/sys/bus/usb/devices/1-1`)
      3. Assert no hardcoded USB path — path must be derived from VID:PID or udev query
    Expected Result: USB path discovery is dynamic and portable
    Failure Indicators: Hardcoded sysfs path found in script
    Evidence: .sisyphus/evidence/task-14-dynamic-path.txt

  Scenario: No host reboot in any executor
    Tool: Bash
    Preconditions: All executor scripts exist
    Steps:
      1. Search all executor scripts for `reboot`, `shutdown -r`, `systemctl reboot`
      2. Assert zero active matches
    Expected Result: Reboot is entirely absent
    Evidence: .sisyphus/evidence/task-14-no-reboot.txt

  Scenario: Level 4 uses AT discovery helper
    Tool: Bash
    Preconditions: Level 4 executor and AT discovery script (Task 8) both exist
    Steps:
      1. Read Level 4 executor
      2. Assert it calls or sources the AT-port discovery helper
      3. Assert it does NOT reference /dev/ttyUSB2 directly
    Expected Result: Level 4 uses dynamic port discovery
    Evidence: .sisyphus/evidence/task-14-level4-at.txt
  ```

  **Commit**: YES (groups with 13)
  - Message: `feat(lte): add staged recovery executors`

---

- [x] 15. Add Ethernet-primary route arbitration via systemd-networkd

  **What to do**:
  - Add `.network` files for `eth0` and `eth1` under `systemd-networkd` with **low metric values** (e.g., `RouteMetric=100`) so Ethernet routes are preferred over LTE.
  - Assign `lte0` a **higher metric** (e.g., `RouteMetric=1000`) so it is strictly fallback.
  - Use `systemd-networkd` carrier-detection behavior: when Ethernet comes up, its default route is installed at the lower metric and naturally preempts LTE; when Ethernet goes down, its routes are withdrawn and LTE route takes over automatically.
  - Add `ConfigureWithoutCarrier=no` (default behavior) so Ethernet interfaces do not inject routes when the cable is unplugged.
  - For `eth1` which is already active at `192.168.1.7/24`: ensure its `.network` config does not conflict with existing static address (use DHCP or match the observed addressing — document as a deployment variable if the address changes).
  - Test that with both Ethernet and LTE active, `ip route` shows Ethernet as the default.
  - Test that unplugging Ethernet causes LTE default route to become active within a few seconds.

  **Must NOT do**:
  - Do not use `ip rule` / policy routing unless `systemd-networkd` metric approach proves insufficient.
  - Do not set Ethernet metric equal to LTE metric.
  - Do not require NetworkManager for any part of this.
  - Do not disable `lte0` when Ethernet is active — LTE must remain available as warm standby.

  **Recommended Agent Profile**:
  - **Category**: `business-logic`
    - Reason: route metric policy is a behavior-correct/deterministic requirement.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3
  - **Blocks**: 17, 22
  - **Blocked By**: 3, 4, 10

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — Ethernet primary / LTE fallback requirement; confirmed active eth1 at `192.168.1.7/24`.
  - **Hardware facts**: `eth0` (no IP, no cable), `eth1` (active: `192.168.1.7/24`). Both need `.network` files with appropriate metrics.
  - systemd-networkd `[Route]` section: `Metric=` (per-route metric) and `[DHCP]` section `RouteMetric=` (for DHCP-assigned default route).
  - Confirmed: `systemd-networkd` is the only network owner — no NetworkManager conflict.

  **Acceptance Criteria**:
  - [ ] `lte0.network` has `RouteMetric=1000` (or equivalent high value).
  - [ ] Ethernet `.network` files have `RouteMetric=100` (or equivalent low value) — lower than LTE.
  - [ ] With both interfaces active, `ip route` shows Ethernet as default gateway.
  - [ ] After Ethernet carrier loss, LTE default route becomes active automatically.

  **QA Scenarios**:
  ```
  Scenario: Ethernet metric is lower than LTE metric
    Tool: Bash
    Preconditions: .network files for lte0, eth0, eth1 exist
    Steps:
      1. Read all .network files
      2. Extract RouteMetric values for each interface
      3. Assert ethernet metric < lte metric
    Expected Result: Ethernet numerically preferred over LTE
    Failure Indicators: Metrics equal or LTE metric lower
    Evidence: .sisyphus/evidence/task-15-metrics.txt

  Scenario: LTE remains available when Ethernet is active (warm standby)
    Tool: Bash
    Preconditions: Hardware connected with both lte0 and eth1 active
    Steps:
      1. Run `ip -4 addr show lte0`
      2. Assert lte0 has an IPv4 address (DHCP active)
      3. Run `ip route`
      4. Assert default via Ethernet (lower metric)
      5. Assert lte0 route is present but with higher metric
    Expected Result: Both interfaces up; Ethernet is default; LTE is warm standby
    Failure Indicators: lte0 has no IP, or only one default route present
    Evidence: .sisyphus/evidence/task-15-warm-standby.txt

  Scenario: Ethernet failover to LTE (hardware test)
    Tool: Bash (+ hardware)
    Preconditions: Both eth1 and lte0 active; eth1 is default gateway
    Steps:
      1. Run `ip route` — assert Ethernet default
      2. Unplug Ethernet cable
      3. Wait 5s
      4. Run `ip route` — assert LTE is now default gateway
      5. Plug Ethernet back in; wait 5s
      6. Run `ip route` — assert Ethernet is default again
    Expected Result: Automatic failover and recovery without manual intervention
    Failure Indicators: Default route does not change after cable unplug/replug
    Evidence: .sisyphus/evidence/task-15-failover.txt
  ```

  **Commit**: YES (groups with 10)
  - Message: `feat(lte): add ethernet-primary route arbitration`

---

- [x] 16. Add telemetry-oriented tuning defaults

  **What to do**:
  - Apply and document the following tuning values for the EC200U-CN in telemetry use cases (bidirectional QUIC in remote/high-latency locations):
  - **MTU**: Set `lte0` MTU to **1400** in the `.network` or `.link` file (`MTUBytes=1400`). This avoids fragmentation given LTE's typical 1450–1500 byte MTU at the radio layer plus GTP encapsulation overhead.
  - **USB autosuspend**: Confirm the udev rule from Task 2 has disabled autosuspend (`power/autosuspend_delay_ms = -1` or `power/control = on`) by reading the actual sysfs path after the modem enumerates. Script must verify this post-enumeration — do not assume the rule was applied.
  - **LTE-only RAT lock**: Add an optional AT command to restrict the modem to LTE-only mode: `AT+QNWPREFMDE=2`. Document that this prevents fallback to WCDMA/GSM (useful in areas with LTE coverage; may cause registration failure if LTE is unavailable — leave as an opt-in deployment parameter).
  - **QUIC keepalive guidance**: Document that the MavlinkRelay app's `idle_timeout_ms` is 60000ms (60s) and `keepalive_ms` is 15000ms (15s). In aggressive NAT environments (particularly Chinese carriers), NAT timeout can be <15s — advise adjusting `keepalive_ms` to **10000ms** (10s) in `relay_params.yaml` if QUIC sessions drop unexpectedly. This is an app-level config change, documented here as telemetry guidance only (not implemented in this module).
  - **Carrier NAT awareness**: Document the 15s→10s keepalive recommendation and the evidence base (carrier NAT < 15s observed pattern).
  - Generate a single tuning reference file that captures all of the above for operator use.

  **Must NOT do**:
  - Do not touch `relay_params.yaml` directly — this plan is OS-level only; app config is guidance only.
  - Do not hardcode the MTU above 1400 without documented rationale.
  - Do not enable RAT lock by default — it must be opt-in.
  - Do not assume autosuspend is disabled without verifying sysfs post-enumeration.

  **Recommended Agent Profile**:
  - **Category**: `precise`
    - Reason: specific numeric values with documented rationale; sysfs verification logic.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3
  - **Blocks**: 17, 21, 22
  - **Blocked By**: 2, 9, 10

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — MTU=1400, autosuspend verification, RAT lock, keepalive guidance.
  - `jetson/mavlink_quic_relay/config/relay_params.yaml` — `keepalive_ms: 15000`, `idle_timeout_ms: 60000`.
  - `jetson/mavlink_quic_relay/src/quic_client.cpp` — `QUIC_EXECUTION_PROFILE_LOW_LATENCY` profile confirms latency-sensitive workload.
  - **AT command**: `AT+QNWPREFMDE=2` — LTE only; `AT+QNWPREFMDE?` — query current mode.
  - **Sysfs autosuspend path** (example): `/sys/bus/usb/devices/1-1/power/control` — must be read post-enumeration; actual USB path derived dynamically (same pattern as Task 14 Level 3).
  - Metis review — "USB autosuspend must be verified post-enumeration by reading sysfs, not just checking udev rule."

  **Acceptance Criteria**:
  - [ ] `lte0` MTU is set to 1400 in `.link` or `.network` config.
  - [ ] Post-enumeration autosuspend verification script/step exists and checks sysfs.
  - [ ] RAT lock is documented as opt-in with the specific AT command and trade-off.
  - [ ] QUIC keepalive guidance (15s→10s for aggressive NAT) is documented with rationale.
  - [ ] All tuning values have documented rationale.

  **QA Scenarios**:
  ```
  Scenario: MTU is set to 1400 in configuration
    Tool: Bash
    Preconditions: .link or .network config for lte0 exists
    Steps:
      1. Read lte0 configuration files
      2. Assert MTUBytes=1400 or equivalent is present
    Expected Result: MTU is configured at 1400
    Failure Indicators: MTU absent or set to 1500
    Evidence: .sisyphus/evidence/task-16-mtu.txt

  Scenario: Autosuspend sysfs verification step exists
    Tool: Bash
    Preconditions: Tuning/verification script exists
    Steps:
      1. Read the autosuspend verification script/function
      2. Assert it reads from `/sys/bus/usb/devices/.../power/control` or equivalent
      3. Assert it fails with a clear message if value is not `on`
    Expected Result: Autosuspend verification is active post-enumeration
    Failure Indicators: Script assumes udev rule applied without checking sysfs
    Evidence: .sisyphus/evidence/task-16-autosuspend-verify.txt

  Scenario: RAT lock is opt-in only
    Tool: Bash
    Preconditions: All scripts and config exist
    Steps:
      1. Search for AT+QNWPREFMDE in active bring-up/bootstrap scripts
      2. Assert it is NOT called automatically without an opt-in flag/parameter
      3. Assert it IS documented in tuning reference
    Expected Result: RAT lock is deployment-configurable, not automatic
    Failure Indicators: RAT lock applied unconditionally on every bring-up
    Evidence: .sisyphus/evidence/task-16-rat-opt-in.txt

  Scenario: Keepalive guidance is documented
    Tool: Bash
    Preconditions: Tuning reference document exists
    Steps:
      1. Read tuning reference file
      2. Assert it mentions keepalive_ms or idle_timeout
      3. Assert 10s recommendation and Chinese carrier NAT context are mentioned
    Expected Result: Operator has actionable keepalive guidance
    Evidence: .sisyphus/evidence/task-16-keepalive-guidance.txt
  ```

  **Commit**: YES (groups with 9 and 10)
  - Message: `feat(lte): add telemetry tuning defaults and guidance`

---

- [x] 17. Build hardware-in-loop smoke runner

  **What to do**:
  - Implement a single entry-point script (`tests/integration/smoke.sh`) that orchestrates all hardware-dependent checks in sequence and emits structured `[PASS]`/`[FAIL]` output.
  - Include checks for (in order):
    1. Modem USB enumeration: `lsusb -d 2c7c:0901` returns a device.
    2. `cdc_ether` driver bound: `lsmod | grep cdc_ether` and `ip link show lte0` exists.
    3. `lte0` interface is UP with IPv4 address (DHCP has run).
    4. `lte0` MTU is 1400 (read from `ip link`).
    5. USB autosuspend is disabled: read `/sys/bus/usb/devices/<modem-path>/power/control` = `on`.
    6. ECM mode confirmed: AT query `AT+QCFG="usbnet"` returns `,1` on the discovered AT port.
    7. SIM inserted and registered: `AT+CPIN?` returns `READY`; `AT+CEREG?` returns stat=1 or 5.
    8. LTE data connectivity: DNS probe (e.g. `nslookup google.com` via `lte0` or `dig @8.8.8.8 google.com`) succeeds.
    9. APN detection: auto/default path yielded data connectivity (pass from step 8 is sufficient evidence).
    10. Default route: `ip route` shows a default via LTE when Ethernet is not connected.
    11. Ethernet metric check (if Ethernet is connected): Ethernet default route has lower metric than LTE.
  - Save all output to `.sisyphus/evidence/smoke-<timestamp>.txt`.
  - Exit 0 only if ALL checks pass; exit 1 with summary of which checks failed.

  **Must NOT do**:
  - Do not require manual operator steps mid-script.
  - Do not skip checks based on unset environment variables — fail explicitly.
  - Do not mix hardware and offline tests in this script (hardware tests only here).

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: multi-layer end-to-end integration script requiring careful AT interaction, network checks, and structured output.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 3
  - **Blocks**: 18, 19, 21, 22
  - **Blocked By**: 5, 7, 9, 10, 11, 13, 14, 15, 16

  **References**:
  - Task 5 (test harness skeleton) — inherit evidence helper and `[PASS]/[FAIL]` conventions.
  - Task 8 (AT discovery) — use discovery helper for AT port.
  - **Hardware-confirmed values**: VID:PID `2c7c:0901`, MAC `02:4b:b3:b9:eb:e5`, driver `cdc_ether`, interface `lte0`.
  - **AT commands**: `AT+QCFG="usbnet"` (expect `,1`), `AT+CPIN?` (expect `+CPIN: READY`), `AT+CEREG?` (expect stat=1 or 5).
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — ordered verification approach and evidence path conventions.

  **Acceptance Criteria**:
  - [ ] All 11 checks are present in the smoke script.
  - [ ] Script exits 0 only when all checks pass.
  - [ ] Output is structured with `[PASS]`/`[FAIL]` per check.
  - [ ] Evidence is saved to `.sisyphus/evidence/smoke-<timestamp>.txt`.

  **QA Scenarios**:
  ```
  Scenario: Smoke runner passes on healthy hardware
    Tool: Bash (hardware required)
    Preconditions: Modem connected with SIM, lte0 has IPv4, Ethernet disconnected
    Steps:
      1. Run `bash tests/integration/smoke.sh`
      2. Assert exit code 0
      3. Assert output contains 11 [PASS] lines, 0 [FAIL] lines
      4. Assert evidence file exists in .sisyphus/evidence/
    Expected Result: All hardware smoke checks pass
    Failure Indicators: Any [FAIL] line or non-zero exit
    Evidence: .sisyphus/evidence/task-17-smoke-pass.txt

  Scenario: Smoke runner reports failures clearly
    Tool: Bash (hardware required)
    Preconditions: Simulate a failure (e.g. disconnect modem mid-run or block DNS)
    Steps:
      1. Induce a failure condition (e.g. `ip link set lte0 down`)
      2. Run `bash tests/integration/smoke.sh`
      3. Assert exit code 1
      4. Assert output contains at least one [FAIL] line identifying the failed check
    Expected Result: Failure is clearly identified, not silently swallowed
    Failure Indicators: Exit 0 despite failed condition; vague error message
    Evidence: .sisyphus/evidence/task-17-smoke-fail.txt
  ```

  **Commit**: YES (groups with 19 and 22)
  - Message: `test(lte): add hardware-in-loop smoke runner`

---

- [x] 18. Add persistent logging and evidence packaging

  **What to do**:
  - Configure the watchdog service (Task 13) to log to a persistent, size-limited log file (e.g. `journald` with forward to `/var/log/lte-watchdog/` using `StandardOutput=append:` in the systemd unit, or a rotating logfile via `logrotate`).
  - Add an `lte-evidence-pack.sh` script that collects a full diagnostic snapshot on demand or on failure:
    - `journalctl -u lte-watchdog -u lte-setup --since "24 hours ago" --no-pager`
    - `ip addr`, `ip route`, `networkctl status`
    - `lsusb`, `udevadm info --query=all --name=lte0`
    - `dmesg | grep -E "(usb|cdc_ether|lte|2c7c)"` (last 200 lines)
    - Current watchdog state file contents
    - All files in `.sisyphus/evidence/`
  - Package the snapshot into a timestamped tarball: `/tmp/lte-diag-<timestamp>.tar.gz`.
  - Log rotation: cap watchdog log at 10MB, keep 3 rotations.

  **Must NOT do**:
  - Do not log sensitive credentials or SIM IMSI in plain text.
  - Do not let logs grow unbounded.

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4
  - **Blocks**: F1, F3
  - **Blocked By**: 13, 17

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — evidence path conventions, journald usage.
  - Task 13 (watchdog) — log output must feed this packaging step.

  **Acceptance Criteria**:
  - [ ] Watchdog logs are persistent across reboots (journald or file).
  - [ ] `lte-evidence-pack.sh` produces a complete tarball with all diagnostic sources.
  - [ ] Log rotation config limits file size.

  **QA Scenarios**:
  ```
  Scenario: Evidence pack script runs and produces tarball
    Tool: Bash
    Preconditions: lte-evidence-pack.sh exists; systemd units exist
    Steps:
      1. Run `bash lte-evidence-pack.sh`
      2. Assert exit 0
      3. Assert a .tar.gz file is created in /tmp/
      4. Assert tarball is non-empty (contains at least 3 files)
    Expected Result: Diagnostic snapshot created successfully
    Failure Indicators: Script errors; empty tarball; no output file
    Evidence: .sisyphus/evidence/task-18-pack.txt

  Scenario: Log rotation is configured
    Tool: Bash
    Preconditions: Log rotation config exists
    Steps:
      1. Read logrotate config or systemd unit log settings
      2. Assert size limit is defined (≤10MB)
      3. Assert rotation count is defined (≥2)
    Expected Result: Logs are capped and rotated
    Evidence: .sisyphus/evidence/task-18-logrotate.txt
  ```

  **Commit**: YES (groups with 13)
  - Message: `feat(lte): add persistent logging and evidence packaging`

---

- [x] 19. Build failure-injection test scripts

  **What to do**:
  - Implement a set of scripted failure scenarios that deliberately induce LTE faults and verify the recovery ladder responds correctly. These scripts are hardware-required but operator-safe — they inject faults programmatically without requiring physical intervention (where possible).
  - **Scenario A — DHCP lease loss**: Clear the IP from `lte0` manually (`ip addr flush dev lte0`) and verify the watchdog detects DEGRADED and Level 1 (DHCP renew) restores the address.
  - **Scenario B — Interface down**: `ip link set lte0 down` and verify watchdog detects and Level 2 (link bounce) restores UP state.
  - **Scenario C — USB rebind** (if safe to test without physically unplugging): Unbind `cdc_ether` via sysfs and verify Level 3 executor re-binds and interface recovers.
  - **Scenario D — No-coverage simulation**: Temporarily block all outbound traffic from `lte0` with an `iptables` DROP rule on the DNS probe target, causing connectivity failure. Simultaneously inject `AT+CEREG?` mock returning stat=0 (not registered). Verify watchdog enters `NO_COVERAGE` state and does NOT escalate to recovery executors.
  - **Scenario E — Full recovery path**: Remove SIM (physical) or force modem into airplane mode (`AT+CFUN=4`) for 30s, then restore. Verify full recovery chain executes in order and modem returns to `HEALTHY`.
  - Each scenario must emit `[PASS]`/`[FAIL]` and save evidence.

  **Must NOT do**:
  - Do not leave the system in a broken state after a test — each scenario must include cleanup/restore.
  - Do not run Scenario C or E automatically without a confirm prompt (they are disruptive).
  - Scenario D must be cleaned up (iptables rule removed) before exit, even on failure.

  **Recommended Agent Profile**:
  - **Category**: `deep`
    - Reason: failure injection requires precise sequencing, cleanup guarantees, and state verification.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4
  - **Blocks**: 22, F3
  - **Blocked By**: 2, 5, 8, 9, 11, 14, 17

  **References**:
  - Task 13 (state machine) — watchdog state transitions to verify.
  - Task 14 (recovery executors) — executor invocations to verify.
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — no-coverage vs hardware failure distinction (critical for Scenario D).
  - **AT command for airplane mode**: `AT+CFUN=4` (minimum functionality, no RF); `AT+CFUN=1` (restore full function).

  **Acceptance Criteria**:
  - [ ] Five distinct failure scenarios implemented (A–E).
  - [ ] Each scenario includes cleanup/restore logic.
  - [ ] Disruptive scenarios (C, E) require a confirm prompt.
  - [ ] Scenario D verifies watchdog does NOT escalate in `NO_COVERAGE`.
  - [ ] All emit structured `[PASS]`/`[FAIL]` output with evidence.

  **QA Scenarios**:
  ```
  Scenario: Scenario A (DHCP loss) passes cleanly
    Tool: Bash (hardware required)
    Preconditions: lte0 active with IPv4; watchdog running
    Steps:
      1. Run `ip addr flush dev lte0`
      2. Wait 30s for watchdog detection + Level 1 recovery
      3. Run `ip -4 addr show lte0`
      4. Assert IPv4 address is restored
    Expected Result: DHCP renew restores IP address
    Failure Indicators: IP not restored after 60s; watchdog log shows no action
    Evidence: .sisyphus/evidence/task-19-scenario-a.txt

  Scenario: Scenario D (no-coverage) does not escalate
    Tool: Bash (hardware required)
    Preconditions: lte0 active; watchdog running; iptables available
    Steps:
      1. Add iptables DROP rule blocking DNS probe
      2. Inject mock AT+CEREG? stat=0 (or confirm modem is unregistered)
      3. Wait 30s for watchdog detection
      4. Read watchdog state
      5. Assert state is NO_COVERAGE
      6. Assert no recovery executor was called (check watchdog log)
      7. Remove iptables rule (cleanup)
    Expected Result: No recovery escalation during no-coverage
    Evidence: .sisyphus/evidence/task-19-scenario-d.txt
  ```

  **Commit**: YES (groups with 17)
  - Message: `test(lte): add failure-injection scenarios`

---

- [x] 20. Build deployment installer and uninstaller

  **What to do**:
  - Implement `install.sh` that deploys the full LTE module to the target Jetson system:
    - Copy udev rules to `/etc/udev/rules.d/`
    - Copy `.link` files to `/etc/systemd/network/`
    - Copy `.network` files to `/etc/systemd/network/`
    - Copy systemd service units to `/etc/systemd/system/`
    - Copy scripts to `/usr/local/lib/lte-module/`
    - Run `udevadm control --reload-rules && udevadm trigger`
    - Run `systemctl daemon-reload`
    - Mask `nv-l4t-usb-device-mode`
    - Enable and start `lte-setup.service` and `lte-watchdog.service`
    - Print a summary of what was installed and next steps.
  - Implement `uninstall.sh` that cleanly reverses all installation steps:
    - Stop and disable services
    - Unmask `nv-l4t-usb-device-mode` (restore to original state)
    - Remove all installed files
    - Reload udev and systemd
    - Print restoration summary.
  - Both scripts must be idempotent (safe to run multiple times).
  - Both scripts must require confirmation before making system-wide changes.

  **Must NOT do**:
  - Do not silently overwrite existing system files without a backup or diff.
  - Do not leave orphaned systemd units after uninstall.
  - Do not require the modem to be connected for install — install is config-only.

  **Recommended Agent Profile**:
  - **Category**: `quick`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4
  - **Blocks**: 22, F2
  - **Blocked By**: 1, 12

  **References**:
  - Task 1 (skeleton) — directory layout to copy from.
  - Task 2 (udev), Task 3 (.link), Task 10 (.network), Task 7 (services) — all artifacts to install.
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — installation target paths and idempotency requirement.

  **Acceptance Criteria**:
  - [ ] `install.sh` deploys all files to correct system paths.
  - [ ] `uninstall.sh` removes all deployed files and restores pre-install state.
  - [ ] Both scripts are idempotent.
  - [ ] Both scripts require a confirmation prompt.
  - [ ] `shellcheck` passes on both scripts.

  **QA Scenarios**:
  ```
  Scenario: Install script deploys all expected files
    Tool: Bash
    Preconditions: Install script exists; run in a test environment or with --dry-run flag
    Steps:
      1. Run `bash install.sh` (with confirmation)
      2. Assert udev rules exist in /etc/udev/rules.d/
      3. Assert .link and .network files exist in /etc/systemd/network/
      4. Assert systemd services are enabled
      5. Assert nv-l4t-usb-device-mode is masked
    Expected Result: Full deployment completed
    Failure Indicators: Any expected file missing; service not enabled
    Evidence: .sisyphus/evidence/task-20-install.txt

  Scenario: Uninstall script restores clean state
    Tool: Bash
    Preconditions: Install has been run; run uninstall
    Steps:
      1. Run `bash uninstall.sh` (with confirmation)
      2. Assert installed udev rule is removed
      3. Assert installed .network/.link files are removed
      4. Assert LTE services are disabled and stopped
      5. Assert nv-l4t-usb-device-mode is unmasked
    Expected Result: System returns to pre-install state
    Failure Indicators: Any installed file remains; service still enabled
    Evidence: .sisyphus/evidence/task-20-uninstall.txt
  ```

  **Commit**: YES (groups with 1 and 12)
  - Message: `feat(lte): add deployment installer and uninstaller`

---

- [x] 21. Write field troubleshooting guide

  **What to do**:
  - Write `docs/troubleshooting.md` as a concise operator-facing reference for diagnosing LTE issues in the field.
  - Cover at minimum:
    - **Modem not enumerating**: Check `lsusb -d 2c7c:0901`; check `dmesg | grep cdc_ether`; verify USB-C cable seated.
    - **lte0 has no IP**: Run `journalctl -u systemd-networkd | grep lte0`; check DHCP; run Level 1 recovery manually.
    - **LTE connected but no data**: Test DNS probe manually; check APN; consider explicit APN parameter.
    - **Watchdog stuck in RECOVERING**: Check AT port; run AT diagnostics (`AT+CPIN?`, `AT+CEREG?`); verify SIM seated.
    - **Watchdog in NO_COVERAGE**: Signal issue, not hardware — wait or change physical location.
    - **Ethernet not preferred**: Check `ip route`; verify `.network` metrics; reload networkd.
    - **QUIC sessions dropping frequently**: Check `keepalive_ms` in `relay_params.yaml`; consider reducing to 10000ms for aggressive carrier NAT.
    - **How to collect diagnostics**: Run `lte-evidence-pack.sh`; share resulting tarball.
  - Include a quick-reference command table for the most common diagnostic commands.
  - Keep language operator-friendly — assume Linux knowledge but not modem/AT expertise.

  **Must NOT do**:
  - Do not document unsupported features (QMI, MBIM, IPv6 on LTE, NetworkManager).
  - Do not recommend host reboot as a troubleshooting step.

  **Recommended Agent Profile**:
  - **Category**: `writing`
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4
  - **Blocks**: F1, F4
  - **Blocked By**: 4, 6, 16, 17

  **References**:
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — all confirmed assumptions, hardware facts, AT commands.
  - Task 16 (tuning) — keepalive guidance to reference in QUIC section.
  - Task 18 (logging) — evidence pack command to document.
  - Task 13 (state machine) — watchdog states to explain to operator.
  - **Hardware-confirmed AT commands**: `AT+CPIN?`, `AT+CEREG?`, `AT+QCFG="usbnet"`.
  - **Hardware facts for reference**: VID:PID `2c7c:0901`, driver `cdc_ether`, interface `lte0`.

  **Acceptance Criteria**:
  - [ ] Document covers all 7 troubleshooting scenarios listed above.
  - [ ] Quick-reference command table is present.
  - [ ] No host reboot recommended anywhere.
  - [ ] Evidence pack command is documented.

  **QA Scenarios**:
  ```
  Scenario: All required troubleshooting scenarios are present
    Tool: Bash
    Preconditions: troubleshooting.md exists
    Steps:
      1. Read docs/troubleshooting.md
      2. Assert each of the 7 scenario headings (or equivalent) is present
      3. Assert quick-reference command table exists
    Expected Result: All troubleshooting scenarios documented
    Failure Indicators: Missing scenario; no command table
    Evidence: .sisyphus/evidence/task-21-troubleshooting.txt

  Scenario: No host reboot is recommended
    Tool: Bash
    Preconditions: troubleshooting.md exists
    Steps:
      1. Search document for `reboot` or `shutdown -r`
      2. Assert zero occurrences as a recommendation (explanatory/guardrail context is OK)
    Expected Result: Reboot not recommended anywhere
    Evidence: .sisyphus/evidence/task-21-no-reboot-rec.txt
  ```

  **Commit**: YES (groups with 6)
  - Message: `docs(lte): add field troubleshooting guide`

---

- [x] 22. Build acceptance test checklist wrapper

  **What to do**:
  - Implement `tests/integration/acceptance.sh` as the final gate-keeping script that orchestrates all verification in sequence and produces a single PASS/FAIL verdict for deployment sign-off.
  - The script runs in order:
    1. Static validation (Task 12): `bash -n` + `shellcheck` on all scripts.
    2. Offline unit tests (Task 5): run unit test runner.
    3. Smoke tests (Task 17): hardware-in-loop smoke runner.
    4. Route arbitration check (Task 15): verify Ethernet-preferred metrics.
    5. Recovery scenario A + B (Task 19): DHCP loss + link bounce (non-disruptive scenarios only, no confirm needed).
    6. Evidence packaging check (Task 18): verify `lte-evidence-pack.sh` runs and produces output.
  - For each step: emit `[PASS]`/`[FAIL]` with elapsed time.
  - Final summary: total pass/fail counts, exit 0 only if all pass.
  - Save full output to `.sisyphus/evidence/acceptance-<timestamp>.txt`.
  - Include a `--skip-hardware` flag that skips the hardware-dependent steps (3, 4, 5) for CI use.

  **Must NOT do**:
  - Do not include disruptive failure-injection scenarios (C, D, E from Task 19) in automatic acceptance — those are manual tests.
  - Do not exit early on first failure — run all steps and report a full summary.
  - Do not require manual intervention mid-run.

  **Recommended Agent Profile**:
  - **Category**: `business-logic`
    - Reason: acceptance gating logic with explicit pass/fail semantics.
  - **Skills**: `[]`

  **Parallelization**:
  - **Can Run In Parallel**: YES
  - **Parallel Group**: Wave 4
  - **Blocks**: F1, F3, F4
  - **Blocked By**: 3, 4, 5, 11, 14, 15, 16, 17, 19, 20

  **References**:
  - Task 5 (test harness) — inherit `[PASS]/[FAIL]` conventions and evidence helper.
  - Task 12 (static validation) — static check runner to invoke.
  - Task 17 (smoke runner) — hardware smoke runner to invoke.
  - Task 19 (failure injection) — Scenario A and B scripts to invoke.
  - `.sisyphus/drafts/ec200u-jetson-ecm.md` — Definition of Done as the acceptance benchmark.

  **Acceptance Criteria**:
  - [ ] Script invokes all 6 verification steps in order.
  - [ ] `--skip-hardware` flag skips steps 3–5 cleanly.
  - [ ] Final summary shows per-step results and overall verdict.
  - [ ] Evidence file is saved to `.sisyphus/evidence/acceptance-<timestamp>.txt`.
  - [ ] Exit 0 only if all steps pass.

  **QA Scenarios**:
  ```
  Scenario: Acceptance script runs offline mode without hardware
    Tool: Bash
    Preconditions: acceptance.sh exists; offline tests and static checks exist
    Steps:
      1. Run `bash tests/integration/acceptance.sh --skip-hardware`
      2. Assert exit 0 (static + unit checks pass)
      3. Assert output contains [PASS] for static validation and unit tests
      4. Assert output contains [SKIP] or equivalent for hardware steps
      5. Assert evidence file created in .sisyphus/evidence/
    Expected Result: Offline acceptance gate works without modem
    Failure Indicators: Exit non-zero on offline-only tests; no evidence file
    Evidence: .sisyphus/evidence/task-22-acceptance-offline.txt

  Scenario: Acceptance script fails clearly on any check failure
    Tool: Bash
    Preconditions: acceptance.sh exists; induce a failure (e.g. introduce a shellcheck error)
    Steps:
      1. Introduce a shellcheck-detectable issue in a script
      2. Run `bash tests/integration/acceptance.sh --skip-hardware`
      3. Assert exit 1
      4. Assert output identifies which step failed with [FAIL]
      5. Assert all subsequent steps still ran (no early exit)
    Expected Result: Failure is visible and complete summary is given
    Failure Indicators: Early exit before all steps; silent failure; exit 0 despite error
    Evidence: .sisyphus/evidence/task-22-acceptance-fail.txt
  ```

  **Commit**: YES (groups with 17 and 19)
  - Message: `test(lte): add acceptance test checklist wrapper`

---

## Final Verification Wave

- [x] F1. **Plan Compliance Audit** — `oracle`
  Verify every Must Have and Must NOT Have against the produced deployment package, configuration files, and evidence artifacts.

- [x] F2. **Code Quality Review** — `precise`
  Run shell syntax checks, `shellcheck`, config inspection, and forbidden-pattern scans (`ttyUSB2`, `reboot`, `NetworkManager`, `qmi`, `mbim`).

- [ ] F3. **Real Hardware QA Replay** — `unspecified-high`
  Re-run the scripted smoke and recovery scenarios on target hardware, capturing evidence into `.sisyphus/evidence/final-qa/`.

- [x] F4. **Scope Fidelity Check** — `deep`
  Confirm Ethernet-preferred routing, ECM-only scope, and no-host-reboot behavior are preserved with no unrelated features added.

---

## Commit Strategy

> Tasks are grouped into logical commits. Each commit groups semantically related deliverables.

- **Commit A** (Tasks 1, 20): `feat(lte): add project skeleton, conventions, and installer`
- **Commit B** (Tasks 2, 3): `feat(lte): add udev rules and persistent lte0 naming`
- **Commit C** (Tasks 7, 9): `feat(lte): add usb enumeration guard and ecm bootstrap`
- **Commit D** (Tasks 8): `feat(lte): add dynamic AT-port discovery`
- **Commit E** (Tasks 10, 11, 15, 16): `feat(lte): add networkd config, route arbitration, and tuning`
- **Commit F** (Tasks 13, 14, 18): `feat(lte): add watchdog state machine, recovery executors, and logging`
- **Commit G** (Tasks 5, 12): `test(lte): add test harness skeleton and static validation`
- **Commit H** (Tasks 17, 19, 22): `test(lte): add smoke runner, failure injection, and acceptance gate`
- **Commit I** (Tasks 4, 6, 21): `docs(lte): add routing policy, scope docs, and troubleshooting guide`

---

## Success Criteria

### Verification Commands
```bash
bash -n scripts/*.sh              # Expected: no syntax errors
shellcheck scripts/*.sh           # Expected: no critical findings
bash tests/unit/run_all.sh        # Expected: all unit tests pass
bash tests/integration/smoke.sh   # Expected: LTE ECM smoke checks pass on hardware
bash tests/integration/routing.sh # Expected: Ethernet preferred when present
```

### Final Checklist
- [ ] ECM mode verified and persisted
- [ ] `lte0` stable across re-enumeration/reboot
- [ ] Ethernet outranks LTE when connected
- [ ] APN auto/default path tested; explicit APN fallback supported
- [ ] Recovery ladder never reboots host
- [ ] Hardware smoke + recovery tests pass
