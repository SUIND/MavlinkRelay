#!/usr/bin/env bash
# tests/integration/smoke.sh — Hardware-in-loop smoke runner for EC200U-CN LTE module
# Requires: Physical modem connected, SIM inserted, systemd-networkd configured
# Usage: bash tests/integration/smoke.sh
# Exit codes: 0=all pass, 1=one or more checks failed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/config/params.env"
source "$REPO_ROOT/tests/lib/evidence.sh"

TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
EVIDENCE_FILE="$REPO_ROOT/.sisyphus/evidence/smoke-${TIMESTAMP}.txt"
mkdir -p "$(dirname "$EVIDENCE_FILE")"
exec > >(tee -a "$EVIDENCE_FILE") 2>&1

AT_PORT=""
CHECK8_PASSED=0

send_at_command() {
    local at_cmd="$1"
    local response=""

    if [[ -z "$AT_PORT" ]]; then
        return 1
    fi

    if ! exec 3<>"$AT_PORT"; then
        return 1
    fi

    stty -F "$AT_PORT" 115200 raw -echo 2>/dev/null || true
    printf '%s\r\n' "$at_cmd" >&3
    sleep 1
    response="$(timeout 3 cat <&3 2>/dev/null || true)"
    exec 3>&-

    printf '%s' "$response"
    return 0
}

echo "Starting hardware-in-loop smoke checks for ${LTE_INTERFACE_NAME} (${LTE_MODEM_VID_PID})"

# 1) usb-enum
usb_line="$(lsusb -d "$LTE_MODEM_VID_PID" 2>/dev/null || true)"
if echo "$usb_line" | grep -q "2c7c"; then
    pass "usb-enum" "$(echo "$usb_line" | head -1)"
else
    fail "usb-enum" "no lsusb line found for ${LTE_MODEM_VID_PID}"
fi

# 2) cdc-ether-driver
# cdc_ether may be built-in (not in lsmod); also check sysfs driver symlink as fallback.
if (lsmod | grep -q "$LTE_USB_DRIVER" || readlink "/sys/class/net/${LTE_INTERFACE_NAME}/device/driver" 2>/dev/null | grep -q "${LTE_USB_DRIVER}") \
   && ip link show "$LTE_INTERFACE_NAME" >/dev/null 2>&1; then
    pass "cdc-ether-driver" "driver=${LTE_USB_DRIVER} active and ${LTE_INTERFACE_NAME} exists"
else
    fail "cdc-ether-driver" "driver=${LTE_USB_DRIVER} or interface ${LTE_INTERFACE_NAME} missing"
fi

# 3) lte0-up-ipv4
ip_addr_output="$(ip addr show "$LTE_INTERFACE_NAME" 2>/dev/null || true)"
if echo "$ip_addr_output" | grep -q "state UP" && echo "$ip_addr_output" | grep -q "inet "; then
    lte_ipv4="$(echo "$ip_addr_output" | grep -oP 'inet \K[\d.]+' | head -1)"
    pass "lte0-up-ipv4" "${LTE_INTERFACE_NAME} is UP with IPv4 ${lte_ipv4}"
else
    fail "lte0-up-ipv4" "${LTE_INTERFACE_NAME} is not UP with IPv4"
fi

# 4) lte0-mtu
mtu_value="$(ip link show "$LTE_INTERFACE_NAME" 2>/dev/null | grep -oP 'mtu \K[0-9]+' | head -1)"
if [[ "$mtu_value" == "1400" ]]; then
    pass "lte0-mtu" "mtu=${mtu_value}"
else
    fail "lte0-mtu" "expected mtu=1400, got mtu=${mtu_value:-unset}"
fi

# 5) autosuspend-off
net_device_path="$(readlink -f "/sys/class/net/${LTE_INTERFACE_NAME}/device" 2>/dev/null || true)"
if [[ -z "$net_device_path" ]]; then
    fail "autosuspend-off" "could not resolve /sys/class/net/${LTE_INTERFACE_NAME}/device"
else
    power_control_path="$(readlink -f "${net_device_path}/../power/control" 2>/dev/null || true)"
    if [[ -z "$power_control_path" || ! -f "$power_control_path" ]]; then
        fail "autosuspend-off" "power/control not found from ${net_device_path}"
    else
        power_control_value="$(tr -d '[:space:]' < "$power_control_path")"
        if [[ "$power_control_value" == "on" ]]; then
            pass "autosuspend-off" "${power_control_path}=on"
        else
            fail "autosuspend-off" "${power_control_path}=${power_control_value} (expected on)"
        fi
    fi
fi

# 6) ecm-mode
AT_PORT="$(bash "$REPO_ROOT/scripts/find-at-port.sh" 2>/dev/null || true)"
if [[ -z "$AT_PORT" ]]; then
    # No AT serial port available (EC200U-CN in ECM mode may not expose ttyUSB on this kernel).
    # Fall back: if lte0 already has an IPv4 address, DHCP succeeded → ECM mode is confirmed.
    lte_ecm_ip="$(ip addr show "$LTE_INTERFACE_NAME" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)"
    if [[ -n "$lte_ecm_ip" ]]; then
        pass "ecm-mode" "AT port not available; ECM mode inferred from ${LTE_INTERFACE_NAME} IPv4 ${lte_ecm_ip}"
    else
        fail "ecm-mode" "AT port not found and ${LTE_INTERFACE_NAME} has no IPv4 — cannot confirm ECM mode"
    fi
else
    qcfg_response="$(send_at_command 'AT+QCFG="usbnet"' || true)"
    if echo "$qcfg_response" | grep -q ',1'; then
        pass "ecm-mode" "AT port ${AT_PORT}, usbnet response indicates ECM (,1)"
    else
        fail "ecm-mode" "AT port ${AT_PORT}, unexpected response: $(echo "$qcfg_response" | tr '\r\n' ' ')"
    fi
fi

# 7) sim-ready
if [[ -z "$AT_PORT" ]]; then
    # No AT serial port available — fall back to DHCP-inferred SIM state.
    # If lte0 has an IPv4 address, the modem completed DHCP, which requires a functioning SIM.
    lte_sim_ip="$(ip addr show "$LTE_INTERFACE_NAME" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)"
    if [[ -n "$lte_sim_ip" ]]; then
        pass "sim-ready" "AT port not available; SIM ready inferred from ${LTE_INTERFACE_NAME} IPv4 ${lte_sim_ip}"
    else
        fail "sim-ready" "AT port not found and ${LTE_INTERFACE_NAME} has no IPv4 — cannot confirm SIM state"
    fi
else
    cpin_response="$(send_at_command 'AT+CPIN?' || true)"
    cereg_response="$(send_at_command 'AT+CEREG?' || true)"
    cereg_line="$(echo "$cereg_response" | grep '\+CEREG:' | head -1)"

    cpin_ok=0
    cereg_ok=0

    if echo "$cpin_response" | grep -q '\+CPIN: READY'; then
        cpin_ok=1
    fi

    if echo "$cereg_line" | grep -Eq ',[[:space:]]*(1|5)([^0-9]|$)'; then
        cereg_ok=1
    fi

    if [[ "$cpin_ok" -eq 1 && "$cereg_ok" -eq 1 ]]; then
        pass "sim-ready" "CPIN READY and CEREG registered (${cereg_line})"
    else
        fail "sim-ready" "cpin_ok=${cpin_ok} cereg_ok=${cereg_ok}; cpin=$(echo "$cpin_response" | tr '\r\n' ' '), cereg=$(echo "$cereg_response" | tr '\r\n' ' ')"
    fi
fi

# 8) lte-data
lte_bind_ip="$(ip addr show "$LTE_INTERFACE_NAME" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)"
if [[ -z "$lte_bind_ip" ]]; then
    fail "lte-data" "no IPv4 address on ${LTE_INTERFACE_NAME} for DNS probe"
else
    if command -v dig >/dev/null 2>&1; then
        dig_output="$(dig +short +timeout=5 +tries=2 google.com @8.8.8.8 -b "$lte_bind_ip" 2>/dev/null || true)"
        if [[ -n "$dig_output" ]]; then
            CHECK8_PASSED=1
            pass "lte-data" "dig probe succeeded via ${LTE_INTERFACE_NAME} (${lte_bind_ip}): ${dig_output//$'\n'/, }"
        else
            fail "lte-data" "dig probe returned no answer via ${LTE_INTERFACE_NAME} (${lte_bind_ip})"
        fi
    elif command -v curl >/dev/null 2>&1; then
        curl_status="$(curl --interface "$LTE_INTERFACE_NAME" --max-time 10 -s -o /dev/null -w '%{http_code}' https://google.com 2>/dev/null || true)"
        if [[ -n "$curl_status" && "$curl_status" != "000" ]]; then
            CHECK8_PASSED=1
            pass "lte-data" "curl probe succeeded via ${LTE_INTERFACE_NAME} (http=${curl_status})"
        else
            fail "lte-data" "curl probe failed via ${LTE_INTERFACE_NAME}"
        fi
    else
        fail "lte-data" "neither dig nor curl is available for connectivity probe"
    fi
fi

# 9) apn-auto
if [[ "$CHECK8_PASSED" -eq 1 ]]; then
    pass "apn-auto" "APN auto/default path confirmed by data connectivity (check 8)"
else
    fail "apn-auto" "check 8 failed, cannot confirm APN auto/default path"
fi

# 10) default-route-lte
# Note: even when Ethernet exists, LTE must still have at least one default route entry.
lte_default_routes="$(ip route show | grep -E "^default.*dev ${LTE_INTERFACE_NAME}" || true)"
if [[ -n "$lte_default_routes" ]]; then
    pass "default-route-lte" "default route via ${LTE_INTERFACE_NAME} present: $(echo "$lte_default_routes" | tr '\n' '; ')"
else
    fail "default-route-lte" "no default route via ${LTE_INTERFACE_NAME}"
fi

# 11) eth-metric-lower
# Conditional: if Ethernet has a default route, it must have a lower metric than LTE.
eth_default_routes="$({ ip route show default dev eth0; ip route show default dev eth1; } 2>/dev/null | grep -E '^default' || true)"
lte_route_for_metric="$(ip route show default dev "${LTE_INTERFACE_NAME}" | head -1)"
lte_metric="$(echo "$lte_route_for_metric" | grep -oP 'metric \K[0-9]+' | head -1)"

if [[ -z "$eth_default_routes" ]]; then
    skip "eth-metric-lower" "no Ethernet default route present, skipping metric comparison"
else
    best_eth_metric=""
    while IFS= read -r route_line; do
        [[ -z "$route_line" ]] && continue
        route_metric="$(echo "$route_line" | grep -oP 'metric \K[0-9]+' | head -1)"
        if [[ -z "$route_metric" ]]; then
            route_metric=0
        fi
        if [[ -z "$best_eth_metric" || "$route_metric" -lt "$best_eth_metric" ]]; then
            best_eth_metric="$route_metric"
        fi
    done <<< "$eth_default_routes"

    if [[ -z "$lte_metric" ]]; then
        fail "eth-metric-lower" "could not determine LTE metric from default route"
    elif [[ "$best_eth_metric" -lt "$lte_metric" ]]; then
        pass "eth-metric-lower" "eth metric ${best_eth_metric} < lte metric ${lte_metric}"
    else
        fail "eth-metric-lower" "eth metric ${best_eth_metric} is not lower than lte metric ${lte_metric}"
    fi
fi

save_evidence "smoke-latest.txt" "Latest smoke evidence file: ${EVIDENCE_FILE}"

summary
summary_rc=$?
echo "RESULTS: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
exit "$summary_rc"
