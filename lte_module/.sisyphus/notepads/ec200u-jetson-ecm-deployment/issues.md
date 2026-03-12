# Issues and Gotchas

## 2026-03-12 — Session start

### I1: Task 6 references a deleted draft file
Task 6 references `.sisyphus/drafts/ec200u-jetson-ecm.md` as a source. That file has been DELETED.
All required context is now in this notepad (learnings.md + decisions.md).
Agents writing Task 6 should use the notepad content + plan context, not look for the draft file.

### I2: Task 7 does NOT need OTG role-switch
Updated in plan. Task 7 is a USB enumeration guard (lsusb check), not an OTG role-swap.
Do not confuse with the original plan description.

### I3: EC200U-CN AT port discovery
The EC200U-CN in ECM mode exposes multiple ttyUSB ports. The AT command port is typically
ttyUSB2 (index 2) but this is NOT guaranteed. Discovery must probe all candidates.
EC200U ECM composition: ttyUSB0 (DM), ttyUSB1 (NMEA), ttyUSB2 (AT), ttyUSB3 (modem).
Port assignments are by USB interface number, not by kernel assignment order.

### I4: Short DHCP leases
The modem's internal DHCP server (192.168.225.x range typically) hands out short leases.
DHCP renew is the most common recovery action. Plan accordingly in Level 1 executor.

### I5: nslookup may not be available on Jetson
Use `dig` or `curl` for DNS connectivity probe. Fall back to `nslookup` only if others absent.
Prefer: `dig +short +timeout=3 google.com @8.8.8.8`

## 2026-03-12 — F1 compliance issues
- Task 9 acceptance gap: missing explicit post-reset AT+QCFG="usbnet" verification in scripts/ecm-bootstrap.sh.
- Task 18 acceptance gap: scripts/lte-evidence-pack.sh collects watchdog state from non-default filenames, missing actual default watchdog artifacts.
- Task 20 acceptance gap: unit ExecStart paths mismatch installer destination paths; runtime services may fail after install due to path divergence.
- Additional requirement mismatch: expected params.env key names (APN_NAME/LTE_IFACE/ETHERNET_METRIC/LTE_METRIC) differ from implemented names (LTE_APN/LTE_INTERFACE_NAME/ETH_ROUTE_METRIC/LTE_ROUTE_METRIC).
- Additional requirement mismatch: requested MTU=1400 in lte0 .network not satisfied because MTU is configured in .link.
- Verification expectation mismatch: requested explicit "50 passed, 0 failed" cannot be confirmed from current unit runner output format/suite size.


## 2026-03-12 — F4 audit gotchas
- Broad grep across repository roots can incorrectly flag non-deliverable governance artifacts (`.sisyphus/notepads/*`) as scope violations; constrain scans to deliverable trees or classify findings by code vs commentary.
- Pattern scans for `xudc|usb-device-mode` should be interpreted contextually: precautionary service masking strings are not equivalent to forbidden OTG role-switch implementation.
