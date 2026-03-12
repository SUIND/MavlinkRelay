Purpose

This document defines the explicit scope for the LTE module used to provide drone telemetry over QUIC from a Jetson Xavier NX. The module manages an EC200U-CN modem (Quectel, USB VID:PID 2c7c:0901) operating in ECM mode, configures a persistent lte0 interface via systemd-networkd, and provides robust non-reboot recovery, telemetry tuning, deployment tooling, and troubleshooting documentation.

1. In Scope

- USB enumeration guard specifically for the EC200U-CN modem (VID:PID 2c7c:0901).
- ECM mode enforcement via AT commands (AT+QCFG="usbnet",1) and verification steps.
- Persistent lte0 interface naming via a systemd-networkd .link file (MAC-based match).
- systemd-networkd DHCP configuration for lte0 with IPv4-only configuration and MTU tuning (MTU=1400).
- Ethernet-preferred routing using RouteMetric: eth RouteMetric=100, LTE RouteMetric=1000.
- APN auto/default validation flow; explicit APN provided as a deployment parameter when auto fails.
- Layered recovery watchdog with levels: DHCP renew -> link bounce -> USB rebind -> AT modem reset; recovery stops at modem reset.
- Absolute guardrail: No host reboot as a recovery action (see Non-Goals and guardrail text below).
- Telemetry tuning defaults: MTU=1400, USB autosuspend disabled for the modem, QUIC keepalive and reconnect guidance.
- Deployment installer and uninstaller that install udev rules, systemd .link/.network files, and service units.
- Hardware-in-loop smoke tests and failure-injection tests to validate recovery ladder.
- Field troubleshooting documentation and verification commands for operators.

2. Non-Goals

This module explicitly does NOT implement or support the following. These are firm boundaries, not "future work".

- QMI/MBIM: No libqmi, no ModemManager QMI commands, no MBIM protocol. The module operates in ECM-only mode.
- NetworkManager: All network management is via systemd-networkd. No nmcli, no NetworkManager keyfiles, no NM integration.
- IPv6 on LTE: IPv6 acceptance is disabled on lte0. Only IPv4 is supported for LTE connectivity by this module.
- GPS/NMEA: Although the modem exposes a NMEA/tty port, this module does not read GPS data or provide GPS services.
- Modem firmware update: Firmware flashing or in-field firmware upgrades are out of scope. No qmicli dms-upgrade commands.
- RF band locking: No AT+QNWPREFMDE band-lock scripting by default. RAT lock is opt-in via deployment parameter only.
- Carrier-specific APN hardcoding: No carrier APN is hardcoded. Auto APN flow is preferred; explicit APN is a deployment parameter.
- Host reboot as recovery: THIS IS AN ABSOLUTE GUARDRAIL. The Jetson host MUST NEVER be rebooted due to LTE failures. The recovery ladder terminates at AT modem reset (Level 4). If all recovery levels fail, the watchdog enters a FAILED state, logs the failure, and waits for operator intervention or service restart.
- Video streaming optimization: The module is tuned for low-bandwidth bidirectional telemetry (MAVLink over QUIC), not video streaming optimization.
- Multiple simultaneous modems: The module supports a single EC200U-CN modem only. Multi-modem orchestration is out of scope.

3. Confirmed Deployment Assumptions

- Modem: Quectel EC200U-CN in 7SEMI USB-C form factor (VID:PID 2c7c:0901).
- VID:PID: 2c7c:0901 (confirmed in kernel dmesg and udev tests).
- MAC: 02:4b:b3:b9:eb:e5 (observed stable across re-enumeration; used for .link matching).
- USB host controller: 3610000.xhci (XHCI host) — modem attaches here; it does NOT attach to OTG controller.
- Controller topology: 3610000.xhci is the host bus; 3550000.xudc is the OTG/device controller. These are separate hardware blocks; the modem does not attach to the OTG controller.
- Jetson: NVIDIA Jetson Xavier NX on Connect Tech Quark carrier board (platform tested).
- Kernel: L4T with tegra xhci driver confirmed to bind cdc_ether to the modem.
- Network manager: systemd-networkd is the network stack in use; NetworkManager is not present or is disabled for the modem.
- Active Ethernet example: eth1 at 192.168.1.7/24 when cable connected in test environment.
- Modem enumerates already in ECM mode on this hardware; no usb-modeswitch or QMI mode switching is required.

4. Deployment Variables (Configurable at Installation)

These variables are set in config/params.env at installation time. Default values listed.

- APN: default empty (auto). Set to carrier APN string if auto fails.
- LTE_RAT_LOCK_ENABLED: default false. Set to true to enable RAT lock to LTE-only (AT+QNWPREFMDE=2) if desired.
- LTE_ROUTE_METRIC: default 1000. Increase to de-prioritize LTE further.
- ETH_ROUTE_METRIC: default 100. Can be lowered for stronger Ethernet preference.
- LOG_LEVEL: default INFO. Set to DEBUG for verbose troubleshooting.

5. Compatibility Notes

- Tested on Jetson Xavier NX with L4T kernel. Behavior on other ARM boards is untested and may vary.
- systemd-networkd version: networkd features such as IPv6AcceptRA=no require recent systemd (v244+). Verify with networkctl --version.
- shellcheck is used for static validation of all shell scripts in the deployment installer.

6. Must Not Do

- Do NOT describe QMI/MBIM or NetworkManager integration as "future work" or planned. They are intentionally out of scope and must remain so.
- Do NOT omit the host-reboot guardrail. The host reboot prohibition must appear verbatim in documentation and checks.
- Do NOT leave scope boundaries implicit. All boundaries must be explicit and testable.

7. Context

Why this document exists

This document is the authoritative scope boundary for the LTE module. It prevents scope creep, records the reasoning behind each boundary, and gives operators clear expectations about capabilities and limits.

Notepad and Evidence

- Notepad (read): .sisyphus/notepads/ec200u-jetson-ecm-deployment/learnings.md
- Notepad (read): .sisyphus/notepads/ec200u-jetson-ecm-deployment/decisions.md
- Evidence files created by the installer and CI should be placed under .sisyphus/evidence/ per project conventions.

Appendix: Recovery Ladder (explicit)

Level 0: no-op/normal operation.
Level 1: DHCP renew on lte0.
Level 2: link bounce (systemd-networkd down/up for lte0).
Level 3: USB rebind/unbind sequence for the underlying USB device (udev-triggered re-probe).
Level 4: AT modem reset commands (AT+CFUN=1,1 or AT+QRST...), final recovery action. Stop here; do not reboot the host.
