#!/usr/bin/env bash
# Unit test: Route metric static verification
# HARDWARE_REQUIRED: no
# Statically verifies RouteMetric values in systemd-networkd .network files.
# No hardware access needed — pure grep on repo files.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/evidence.sh"

LTE_NETWORK="$REPO_ROOT/network/20-lte0.network"
ETH0_NETWORK="$REPO_ROOT/network/10-eth0.network"
ETH1_NETWORK="$REPO_ROOT/network/10-eth1.network"

# ── Test 1: lte0 has RouteMetric=1000 ─────────────────────────────────────────

if grep -qF "RouteMetric=1000" "$LTE_NETWORK"; then
    pass "lte0-metric-1000" "network/20-lte0.network contains RouteMetric=1000"
else
    fail "lte0-metric-1000" "RouteMetric=1000 not found in network/20-lte0.network"
fi

# ── Test 2: eth0 has RouteMetric=100 ──────────────────────────────────────────

if grep -qF "RouteMetric=100" "$ETH0_NETWORK"; then
    pass "eth0-metric-100" "network/10-eth0.network contains RouteMetric=100"
else
    fail "eth0-metric-100" "RouteMetric=100 not found in network/10-eth0.network"
fi

# ── Test 3: eth1 has RouteMetric=100 ──────────────────────────────────────────

if grep -qF "RouteMetric=100" "$ETH1_NETWORK"; then
    pass "eth1-metric-100" "network/10-eth1.network contains RouteMetric=100"
else
    fail "eth1-metric-100" "RouteMetric=100 not found in network/10-eth1.network"
fi

# ── Test 4: Ethernet metric (100) is lower than LTE metric (1000) ─────────────
# Extract numeric values and compare programmatically

lte_metric=$(grep -oE "RouteMetric=[0-9]+" "$LTE_NETWORK" | cut -d= -f2)
eth0_metric=$(grep -oE "RouteMetric=[0-9]+" "$ETH0_NETWORK" | cut -d= -f2)
eth1_metric=$(grep -oE "RouteMetric=[0-9]+" "$ETH1_NETWORK" | cut -d= -f2)

if [ -n "$lte_metric" ] && [ -n "$eth0_metric" ] && [ -n "$eth1_metric" ]; then
    if [ "$eth0_metric" -lt "$lte_metric" ] && [ "$eth1_metric" -lt "$lte_metric" ]; then
        pass "eth-lower-than-lte" "Ethernet metrics ($eth0_metric,$eth1_metric) < LTE metric ($lte_metric)"
    else
        fail "eth-lower-than-lte" "Ethernet metrics ($eth0_metric,$eth1_metric) are NOT lower than LTE ($lte_metric)"
    fi
else
    fail "eth-lower-than-lte" "Could not parse metrics: lte=$lte_metric eth0=$eth0_metric eth1=$eth1_metric"
fi

# ── Test 5: lte0 metric (1000) > eth metrics (100) — double-check ─────────────

if [ -n "$lte_metric" ] && [ -n "$eth0_metric" ] && [ -n "$eth1_metric" ]; then
    if [ "$lte_metric" -gt "$eth0_metric" ] && [ "$lte_metric" -gt "$eth1_metric" ]; then
        pass "lte-higher-than-eth" "LTE metric ($lte_metric) > Ethernet metrics ($eth0_metric,$eth1_metric)"
    else
        fail "lte-higher-than-eth" "LTE metric ($lte_metric) is NOT greater than Ethernet ($eth0_metric,$eth1_metric)"
    fi
else
    fail "lte-higher-than-eth" "Could not parse metrics for comparison"
fi

# ── Test 6: eth0 has ConfigureWithoutCarrier=no ───────────────────────────────

if grep -qF "ConfigureWithoutCarrier=no" "$ETH0_NETWORK"; then
    pass "eth0-no-phantom-routes" "network/10-eth0.network has ConfigureWithoutCarrier=no"
else
    fail "eth0-no-phantom-routes" "ConfigureWithoutCarrier=no missing from network/10-eth0.network"
fi

# ── Test 7: eth1 has ConfigureWithoutCarrier=no ───────────────────────────────

if grep -qF "ConfigureWithoutCarrier=no" "$ETH1_NETWORK"; then
    pass "eth1-no-phantom-routes" "network/10-eth1.network has ConfigureWithoutCarrier=no"
else
    fail "eth1-no-phantom-routes" "ConfigureWithoutCarrier=no missing from network/10-eth1.network"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

summary
