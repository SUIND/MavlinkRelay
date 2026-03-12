# Routing Policy: Ethernet-Preferred / LTE-Fallback

**System:** Jetson Xavier NX — MavlinkRelay telemetry gateway  
**Network manager:** `systemd-networkd` (NetworkManager is NOT used)  
**Date:** 2026-03-12  

---

## Policy Summary

| Principle | Description |
|-----------|-------------|
| **Ethernet preferred** | When Ethernet carrier is active (cable plugged in, link up), all default-route traffic uses Ethernet |
| **LTE warm standby** | LTE (`lte0`) is **always-on and always connected** — it holds a DHCP lease and a default route at all times, including when Ethernet is active |
| **Zero-operator failover** | No manual intervention is ever required to switch between uplinks |
| **Mechanism** | `systemd-networkd` route metrics — lower metric = higher priority |

### Golden Rule

**LTE is NEVER disabled when Ethernet is active.**  
It stays connected, holds its DHCP lease, and keeps its default route in the kernel routing table.  
The kernel ignores it only because Ethernet's route metric is lower.  
The moment Ethernet drops, LTE's route is already there.

---

## Implementation Details

### 1. Route Metrics

The Linux kernel selects the best default route by choosing the one with the **lowest metric**.

| Interface | Role | RouteMetric |
|-----------|------|-------------|
| `eth0`    | Secondary Ethernet | `100` |
| `eth1`    | Primary Ethernet | `100` |
| `lte0`    | LTE uplink (EC200U-CN, ECM mode) | `1000` |

When both `eth1` and `lte0` have a default gateway route in the kernel table, the kernel uses `eth1`
because `100 < 1000`. The LTE route exists but is inactive (a "shadow" default route).

### 2. systemd-networkd `.network` Files

Each interface gets its own `.network` file. The metric is set in **both** the `[DHCP]` section
(so DHCP-assigned routes inherit it) and optionally in a `[Route]` section for static routes.

**Ethernet example (`/etc/systemd/network/10-eth1.network`):**
```ini
[Match]
Name=eth1

[Network]
DHCP=yes

[DHCP]
RouteMetric=100
```

**LTE example (`/etc/systemd/network/20-lte0.network`):**
```ini
[Match]
Name=lte0

[Network]
DHCP=yes
IPv6AcceptRA=no

[DHCP]
RouteMetric=1000

[Link]
MTUBytes=1400
```

> **Note on `IPv6AcceptRA=no`:** IPv6 routing on LTE is out of scope for this module. The LTE modem
> typically advertises an IPv6 prefix but we suppress it to avoid routing complexity.

### 3. Carrier Detection and Route Withdrawal

`systemd-networkd` monitors every interface's **carrier state** (the kernel link layer, not
application-level reachability). When the link goes:

- **carrier DOWN** (e.g. Ethernet cable unplugged): networkd receives a `RTM_NEWLINK` kernel
  event with `IFF_RUNNING` cleared. networkd then **withdraws all routes** associated with that
  interface — including its default gateway route.
- **carrier UP** (cable plugged back in): networkd runs DHCP, gets an address, and **reinstalls**
  the routes with the configured metric.

This is purely kernel/driver-driven. No polling. No timers.

### 4. Failover Timing

Failover is **nearly instantaneous** (< 5 seconds in practice, typically < 1 second):

1. Kernel detects carrier loss → generates `RTM_NEWLINK` event (~0 ms)
2. networkd processes event, withdraws Ethernet routes (~10–100 ms)
3. Kernel now has only the LTE default route (metric 1000) → traffic flows via LTE

No conntrack flushing, no routing daemon convergence, no STP. The route is already in the table.

### 5. Recovery (Ethernet Returns)

1. Ethernet cable plugged in → kernel raises carrier
2. networkd runs DHCP on `eth1` → gets IP + gateway
3. networkd installs default route with metric `100`
4. Kernel now has two default routes. It selects metric `100` (Ethernet)
5. Traffic automatically shifts back to Ethernet

LTE route **remains in the table** throughout — it reverts to shadow standby.

---

## Hardware Context

### Confirmed Interface Inventory

| Interface | Description | IP (confirmed) | RouteMetric |
|-----------|-------------|----------------|-------------|
| `eth0` | Secondary Ethernet (NIC 1) | None — cable not plugged | `100` |
| `eth1` | Primary Ethernet (NIC 2) | `192.168.1.7/24` (confirmed active) | `100` |
| `lte0` | EC200U-CN via `cdc_ether` (ECM mode) | DHCP from modem (`192.168.225.x` typical) | `1000` |

> Both `eth0` and `eth1` are assigned the same metric `100`. Whichever interface acquires a
> DHCP default gateway first wins. In practice, only `eth1` is cabled, so it will be the sole
> Ethernet default route during normal operation.

### Modem Interface Details

- **Hardware:** Quectel EC200U-CN, VID:PID `2c7c:0901`
- **USB mode:** ECM (`cdc_ether` driver) — no modeswitching required
- **Logical name:** `lte0` (renamed from `usb0` via udev `.link` file using MAC `02:4b:b3:b9:eb:e5`)
- **MTU:** 1400 bytes (set in `.network` file to accommodate LTE encapsulation overhead)
- **DHCP server:** Internal modem router at `192.168.225.1` (Quectel default)

---

## Telemetry Impact

### QUIC Session Behavior During Failover

The MavlinkRelay application uses QUIC with the following parameters:

| Parameter | Value |
|-----------|-------|
| Keepalive interval | 15 s (current) → **10 s recommended** |
| Idle timeout | 60 s |
| Reconnect backoff | 1 → 2 → 4 → 8 → 16 → 30 s (cap) |
| Execution profile | `QUIC_EXECUTION_PROFILE_LOW_LATENCY` |

### Failover Sequence (Ethernet → LTE)

1. Ethernet carrier drops → routing fails over to LTE in < 5 s
2. Existing QUIC connections use the old 5-tuple — packets now egress via `lte0` with a different
   source IP (`192.168.225.x` instead of `192.168.1.7`)
3. The remote end sees a new source IP → QUIC path migration triggers (or connection resets)
4. Application reconnects using the backoff schedule: `1 → 2 → 4 → 8 → 16 → 30 s`
5. **Worst-case reconnect time:** ~63 s (if all retries fail — extremely unlikely in LTE coverage)
6. **Typical reconnect time:** 1–4 s (first or second retry succeeds)

### Recommendation

Reduce `keepalive_ms` from `15000` to `10000` in `relay_params.yaml`:

```yaml
# relay_params.yaml
keepalive_ms: 10000   # was 15000 — more aggressive for carrier NAT environments
```

**Rationale:** Aggressive carrier NAT (common with LTE) may drop UDP state after 30 s of
inactivity. A 10 s keepalive keeps NAT state alive with comfortable margin.

---

## Verification Commands

Run these on the Jetson to confirm the policy is active and working:

```bash
# ── 1. Check current default route and metrics ────────────────────────────────
ip route show
ip -4 route show default

# Expected (Ethernet active):
#   default via <eth1-gw> dev eth1 proto dhcp src 192.168.1.7 metric 100
#   default via <lte-gw>  dev lte0 proto dhcp src 192.168.225.x metric 1000

# ── 2. Check per-interface routes ─────────────────────────────────────────────
ip route show dev lte0
ip route show dev eth1

# ── 3. Verify LTE is warm standby (has IP even when Ethernet is default) ──────
ip -4 addr show lte0
# Expected: inet 192.168.225.x/24 scope global lte0  (IP present = warm standby active)

# ── 4. Simulate Ethernet failover ─────────────────────────────────────────────
# Unplug eth1 cable, then:
ip -4 route show default
# Expected: only LTE default route remains (metric 1000)

# ── 5. Confirm networkd service state ─────────────────────────────────────────
systemctl status systemd-networkd
networkctl list
networkctl status lte0
networkctl status eth1
```

### What "Healthy" Looks Like

```
# ip -4 route show default  (Ethernet active, LTE warm standby)
default via 192.168.1.1   dev eth1 proto dhcp src 192.168.1.7   metric 100
default via 192.168.225.1 dev lte0 proto dhcp src 192.168.225.3 metric 1000

# networkctl list
IDX LINK       TYPE     OPERATIONAL SETUP
  2 eth0       ether    no-carrier  configured
  3 eth1       ether    routable    configured
  4 lte0       ether    routable    configured     ← both routable = warm standby working
```

---

## Non-Goals

The following are **explicitly out of scope** for this routing policy:

| Not in scope | Why |
|--------------|-----|
| Per-application routing (iptables marks, `ip rule`) | Not needed — metric-based policy covers the drone telemetry use case |
| Health-based routing (reachability probes, ping tests) | That is the watchdog module's responsibility |
| IPv6 routing on LTE | Suppressed via `IPv6AcceptRA=no`; out of scope |
| NetworkManager commands | NetworkManager is not present on this system |
| Manual `ip route` manipulation | Not persistent across reboots; not the solution |
| Disabling LTE when Ethernet is active | **Explicitly forbidden** — LTE must remain warm standby |

---

## Why Not Disable LTE on Ethernet Active?

A common but **wrong** approach is to bring down `lte0` when `eth1` is active. This is rejected:

1. **Cold start penalty:** Reconnecting LTE from scratch takes 5–30 s (DHCP, registration, data bearer).
   During airborne → landing transition this window is unacceptable.
2. **Race conditions:** Detecting "Ethernet is healthy enough to shut down LTE" requires a health probe,
   not just carrier state. Adding that logic couples the routing module to the watchdog.
3. **No upside:** A shadow route with metric 1000 costs nothing. The kernel ignores it.
   There is no bandwidth or battery penalty for keeping LTE connected.

**Decision (D4 from architectural log):** Use `RouteMetric=100/1000` — pure networkd configuration,
no `ip rule`, no `ip route` manipulation, no application-level glue.

---

*This document describes the routing architecture only. For modem bringup, AT command bootstrap,
and udev configuration, see the deployment runbook.*
