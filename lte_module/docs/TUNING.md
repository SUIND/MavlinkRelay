# EC200U-CN LTE Tuning Reference

**Hardware Target:** Quectel EC200U-CN on Jetson Xavier NX  
**Use Case:** Bidirectional QUIC telemetry (MAVLink relay) over 4G/LTE in remote/high-latency environments  
**Last Updated:** 2026-03-12  

---

## Table of Contents

1. [MTU Tuning](#1-mtu-tuning)
2. [USB Autosuspend](#2-usb-autosuspend)
3. [LTE-Only RAT Lock (Opt-In)](#3-lte-only-rat-lock-opt-in)
4. [QUIC Keepalive Guidance](#4-quic-keepalive-guidance)
5. [Carrier NAT Behavior](#5-carrier-nat-behavior)
6. [Deployment Checklist](#6-deployment-checklist)

---

## 1. MTU Tuning

### Setting

```
MTUBytes=1400
```

**File:** `network/10-lte0.link`  
**Installed to:** `/etc/systemd/network/10-lte0.link`

### Rationale

LTE uses GTP (GPRS Tunneling Protocol) as its radio-layer encapsulation. GTP adds approximately 20 bytes of overhead per IP datagram at the radio access network level, reducing the effective host-visible payload from the standard 1500-byte Ethernet MTU.

| Layer              | MTU        |
|--------------------|------------|
| Ethernet (standard)| 1500 bytes |
| LTE GTP overhead   | ~20 bytes  |
| Effective LTE MTU  | ~1480 bytes|
| Deployed setting   | **1400 bytes** |

Setting `MTUBytes=1400` provides a conservative 80-byte margin that:

- **Prevents IP-level fragmentation** on the air interface (fragmentation is expensive in high-latency environments — each retransmit requires re-sending both fragments)
- **Reduces latency variance** — fragmented packets require reassembly at the remote end, introducing jitter unsuitable for real-time telemetry
- **Accommodates additional encapsulation** — when QUIC or other tunneling protocols add their own headers, the application-layer MSS remains below the LTE GTP effective limit
- **Covers MAVLink traffic patterns** — MAVLink messages are typically 8–280 bytes; they fit entirely within 1400-byte datagrams with no fragmentation

### Verification

```bash
# Confirm MTU setting in .link file
grep -i MTUBytes network/10-lte0.link

# Confirm applied at runtime (after deployment)
ip link show lte0 | grep -i mtu
```

Expected output from `.link` file:
```
MTUBytes=1400
```

Expected runtime output:
```
2: lte0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1400 qdisc fq_codel ...
```

### Important Notes

- Do **NOT** set MTU above 1400 without documented carrier-specific rationale
- MTU is set in `network/10-lte0.link` (`[Link]` section) — it is **not** duplicated in `network/20-lte0.network`
- `LTE_MTU=1400` in `config/params.env` is the parameter record; the actual applied value comes from the `.link` file

---

## 2. USB Autosuspend

### Problem

Linux USB autosuspend allows the kernel to power-suspend idle USB devices to save power. When the EC200U-CN modem is suspended mid-flight:

- Telemetry stream drops silently (no error on the host, data just stops)
- AT command port becomes unresponsive
- LTE registration is lost
- Recovery requires physical disconnect/reconnect or a forced USB reset

This is unacceptable for drone operations — loss of telemetry at altitude means loss of command channel.

### Solution: udev Rule

**File:** `rules/99-ec200u-lte.rules`  
**Installed to:** `/etc/udev/rules.d/99-ec200u-lte.rules`

The rule matches the modem by VID:PID (`2c7c:0901`) and sets:

```
ATTR{power/control}="on"
ATTR{power/autosuspend_delay_ms}="-1"
```

- `power/control=on` — forces the device into "always-on" power management mode (overrides the kernel default of `auto`)
- `autosuspend_delay_ms=-1` — sets the autosuspend delay to "never" (the `-1` sentinel value disables autosuspend entirely)

### Post-Enumeration Verification

The udev rule is applied **at device enumeration time**. After deployment, the sysfs state must be verified to confirm the rule applied correctly.

**Verification script:** `scripts/verify-tuning.sh`

**Manual verification:**

```bash
# Find the modem's sysfs USB device path
MODEM_SYSFS=$(udevadm info -q path -n /dev/ec200u-lte 2>/dev/null | sed 's|/ec200u-lte||')
# Or search by VID
MODEM_SYSFS=$(find /sys/bus/usb/devices/ -name "idVendor" -exec grep -rl "2c7c" {} + 2>/dev/null | head -1 | xargs dirname)

# Check power/control
cat /sys/bus/usb/devices/<modem-path>/power/control
# Expected: on

# Check autosuspend delay
cat /sys/bus/usb/devices/<modem-path>/power/autosuspend_delay_ms
# Expected: -1
```

### What to Do If `power/control` Reads `auto`

If the sysfs check shows `auto` instead of `on`, the udev rule did not apply. Common causes:

1. **Rule not installed**: Confirm `/etc/udev/rules.d/99-ec200u-lte.rules` exists
2. **Rules not reloaded**: Run `sudo udevadm control --reload-rules && sudo udevadm trigger`
3. **Device plugged before rules loaded**: Unplug and replug the modem to trigger re-enumeration

---

## 3. LTE-Only RAT Lock (Opt-In)

> **⚠ OPT-IN FEATURE — DEFAULT IS DISABLED**  
> `LTE_RAT_LOCK_ENABLED=0` in `config/params.env`  
> Enabling this will prevent fallback to WCDMA/GSM if LTE is unavailable.

### What It Does

The EC200U-CN supports multiple Radio Access Technologies (RAT): LTE (4G), WCDMA (3G), and GSM (2G). By default, the modem selects the best available RAT automatically.

RAT lock forces LTE-only mode using the AT command:

```
AT+QNWPREFMDE=2
```

To query the current setting:

```
AT+QNWPREFMDE?
```

Expected response when locked to LTE:
```
+QNWPREFMDE: 2

OK
```

Expected response in automatic mode:
```
+QNWPREFMDE: 0

OK
```

### Trade-offs

| | Auto Mode (default) | LTE Lock |
|---|---|---|
| **Coverage** | LTE → WCDMA → GSM fallback | LTE only |
| **Latency** | Varies by RAT (LTE = lowest) | Consistent (LTE only) |
| **Registration risk** | Low (always falls back) | High (fails if LTE unavailable) |
| **Best for** | General deployment, unknown coverage | Confirmed LTE coverage areas |
| **Risk** | WCDMA/GSM fallback introduces higher latency | No connectivity if LTE signal lost |

### When to Enable

Enable LTE lock (`LTE_RAT_LOCK_ENABLED=1`) **only** when:

1. The deployment area has confirmed, stable LTE coverage
2. WCDMA/GSM fallback is known to introduce unacceptable latency for the telemetry use case
3. An operator has explicitly tested and approved LTE-only operation at the deployment site

**Do NOT enable in:**
- Areas with marginal LTE coverage (mountains, deep valleys, remote rural sites)
- Test environments without confirmed LTE signal
- Scenarios where WCDMA is acceptable as a backup

### How to Enable

In `config/params.env`:

```bash
# Change from:
LTE_RAT_LOCK_ENABLED=0

# To:
LTE_RAT_LOCK_ENABLED=1
```

The `scripts/verify-tuning.sh` script will detect this flag and send `AT+QNWPREFMDE?` to confirm the lock is applied. It will also send `AT+QNWPREFMDE=2` if the modem is not yet locked.

### Note on AT Port

The AT command must be sent to the modem's AT command port, discovered dynamically by `scripts/find-at-port.sh`. Never hardcode `/dev/ttyUSB2` or any specific device path — the port number depends on USB enumeration order and can change between reboots.

---

## 4. QUIC Keepalive Guidance

> **Application-level config only** — this section documents OS-invisible parameters.  
> Do NOT modify `relay_params.yaml` as part of OS-level tuning.  
> This guidance is for the **application operator**, not the system administrator.

### Current Configuration

The MavlinkRelay application uses QUIC with the following default keepalive parameters:

```yaml
# relay_params.yaml (application config — do NOT modify from lte_module)
keepalive_ms: 15000       # Send QUIC PING every 15 seconds
idle_timeout_ms: 60000    # Close connection after 60 seconds idle
```

### The NAT Timeout Problem

Chinese mobile carriers (China Mobile, China Unicom, China Telecom) and many international LTE networks maintain NAT state tables for each active UDP flow. When a UDP flow has no traffic for longer than the carrier's NAT timeout:

1. The NAT entry expires silently
2. Subsequent packets from the ground station cannot reach the UAV (the reverse NAT mapping is gone)
3. The QUIC connection appears to hang from the UAV side — no error, just silence
4. Recovery requires a new QUIC handshake, introducing latency

**Observed Chinese carrier NAT timeout: < 15 seconds** for UDP flows.

### Recommendation

Lower `keepalive_ms` to `10000` (10 seconds) for deployment on Chinese carrier networks:

```yaml
# Recommended for aggressive carrier NAT environments
keepalive_ms: 10000       # Send QUIC PING every 10 seconds (was 15000)
idle_timeout_ms: 60000    # Unchanged
```

This ensures a QUIC PING keepalive packet crosses the NAT before the carrier's table entry expires.

### Why This Is App-Level, Not OS-Level

QUIC keepalives are application-layer behavior — they are QUIC protocol PINGs, not TCP keepalives or ICMP echo requests. The OS does not control QUIC keepalive intervals. They must be configured in the QUIC implementation used by MavlinkRelay.

OS-level TCP keepalives (`/proc/sys/net/ipv4/tcp_keepalive_*`) have **no effect** on QUIC connections.

### Summary

| Parameter | Current | Recommended (aggressive NAT) |
|-----------|---------|-------------------------------|
| `keepalive_ms` | 15000 ms | **10000 ms** |
| `idle_timeout_ms` | 60000 ms | 60000 ms (unchanged) |

---

## 5. Carrier NAT Behavior

### Why ICMP Ping Is Unreliable

On Chinese carrier LTE networks (and many other carrier-grade NAT deployments), ICMP echo requests (ping) are filtered or rate-limited at the carrier's NAT gateway. This means:

```bash
# UNRELIABLE on LTE — NAT may block ICMP
ping -c 3 -I lte0 8.8.8.8

# May show: 100% packet loss even when LTE is working
```

Using `ping` to test LTE connectivity produces false negatives — it reports failure when the connection is actually functional for real traffic (UDP/TCP).

### Preferred Connectivity Probe

Use DNS query over UDP port 53, bound to the LTE interface:

```bash
# RELIABLE — tests real UDP transport, not just ICMP
dig +short +timeout=3 google.com @8.8.8.8
```

This probe:
- Uses UDP/53, which passes through carrier NAT
- Binds explicitly to the LTE interface
- Fails with a clear timeout if NAT or routing is broken
- Tests the full stack: LTE → carrier NAT → internet → DNS → response

The `scripts/check-apn.sh` script uses this approach for connectivity verification.

### Carrier NAT Characteristics (Chinese Carriers)

| Carrier | NAT Type | Observed UDP Timeout |
|---------|----------|---------------------|
| China Mobile | Symmetric NAT | ~10-15 seconds |
| China Unicom | Symmetric NAT | ~10-15 seconds |
| China Telecom | Symmetric NAT | ~15 seconds |

> **Note:** These are empirically observed values and may vary by region, tower load, and carrier configuration. Always validate in the target deployment area.

### Implication for QUIC

QUIC uses UDP as its transport. Symmetric NAT means each connection gets a unique NAT mapping. If the connection goes idle longer than the NAT timeout, the mapping expires and the connection is lost from the carrier's perspective.

This is why the `keepalive_ms=10000` recommendation in [Section 4](#4-quic-keepalive-guidance) is important — it keeps the NAT mapping alive by sending a QUIC PING before the carrier's timeout expires.

---

## 6. Deployment Checklist

Before declaring a deployment ready for flight operations, verify all of the following:

### Hardware & OS Layer

- [ ] **MTU verified**: `grep -i MTUBytes network/10-lte0.link` shows `MTUBytes=1400`
- [ ] **Interface renamed**: `ip link show lte0` shows MTU 1400, `usb0` does NOT exist
- [ ] **Autosuspend disabled**: `cat /sys/bus/usb/devices/<modem-path>/power/control` shows `on`
- [ ] **Autosuspend delay**: `cat /sys/bus/usb/devices/<modem-path>/power/autosuspend_delay_ms` shows `-1`
- [ ] **udev rule installed**: `/etc/udev/rules.d/99-ec200u-lte.rules` present
- [ ] **systemd-networkd active**: `systemctl is-active systemd-networkd` returns `active`

### Network Layer

- [ ] **LTE interface DHCP**: `networkctl status lte0` shows DHCP lease acquired
- [ ] **Route metrics correct**: `ip -4 route show default` shows lte0 at metric 1000, eth* at metric 100
- [ ] **Connectivity probe passes**: `dig +short +timeout=3 google.com @8.8.8.8` returns an IP address
- [ ] **IPv6 disabled on LTE**: `ip -6 addr show lte0` returns no global addresses

### AT Layer

- [ ] **ECM mode active**: `scripts/ecm-bootstrap.sh --dry-run` shows ECM already active (or run live to enforce)
- [ ] **SIM ready**: `AT+CPIN?` returns `+CPIN: READY`
- [ ] **LTE registered**: `AT+CEREG?` returns stat=1 (home) or stat=5 (roaming)
- [ ] **RAT lock (if enabled)**: `AT+QNWPREFMDE?` returns `+QNWPREFMDE: 2` when `LTE_RAT_LOCK_ENABLED=1`

### Application Layer

- [ ] **QUIC keepalive review**: Confirm `keepalive_ms` in `relay_params.yaml` — consider 10000ms for aggressive NAT
- [ ] **Idle timeout review**: Confirm `idle_timeout_ms=60000` is appropriate for deployment

### Run Verification Script

```bash
# Full tuning verification (dry-run — no hardware state changes)
bash scripts/verify-tuning.sh --dry-run

# Live verification (requires modem connected)
sudo bash scripts/verify-tuning.sh
```

---

*Reference: [CONVENTIONS.md](CONVENTIONS.md) — log format, naming conventions, forbidden technologies*  
*Reference: [ROUTING-POLICY.md](ROUTING-POLICY.md) — route metric policy and failover behavior*
