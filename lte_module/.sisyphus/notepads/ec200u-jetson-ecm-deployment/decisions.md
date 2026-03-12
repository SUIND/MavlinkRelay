# Architectural Decisions

## 2026-03-12 — Session start

### D1: No OTG role-switch code
Hardware dmesg confirms modem enumerates on `3610000.xhci` (host bus), not `3550000.xudc` (OTG bus).
Decision: NEVER write `echo host > /sys/...` OTG switch code. It is wrong for this hardware.

### D2: systemd-networkd only
NetworkManager is explicitly forbidden. All network config via `.link` + `.network` files.

### D3: ECM mode only
No QMI/MBIM. No modeswitching tool (usb-modeswitch). Modem already enumerates in ECM mode.

### D4: Route metrics for Ethernet preference
Use `RouteMetric=100` for eth0/eth1 and `RouteMetric=1000` for lte0.
This is pure networkd configuration — no ip rule / policy routing needed.

### D5: MAC-based .link file
MAC `02:4b:b3:b9:eb:e5` confirmed stable across re-enumeration. Use MAC match in `.link` file.
Document verification expectation in the file.

### D6: No host reboot — ever
Hard guardrail. Recovery ladder stops at Level 4 (AT modem reset). FAILED state logs and alerts only.

### D7: APN auto first
Do not hardcode any carrier APN. Try auto/default first. Explicit APN is a deployment parameter.

## 2026-03-12 — F1 compliance audit decisions
- D8: Compliance verdict for current package is REJECT until blocking acceptance gaps are remediated.
- D9: Treat post-change/re-enumeration AT mode re-query as mandatory proof step for ECM idempotence acceptance.
- D10: Treat installer/unit path consistency as a hard deployment integrity requirement.
- D11: Treat watchdog/evidence state filename contract as a hard observability interface that must remain synchronized.


## 2026-03-12 — F4 scope fidelity decision
- D12: Scope fidelity verdict set to APPROVE because in-scope deliverables are present, forbidden out-of-scope implementations are absent from active code, and critical constraints (Ethernet-primary routing + no host reboot for LTE failures) are implemented and test-backed.
