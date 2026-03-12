#!/usr/bin/env bash
# tests/integration/failure_inject.sh — Failure injection test suite for EC200U-CN LTE module
# Requires: Physical modem connected, SIM inserted, systemd-networkd configured
# Usage: bash tests/integration/failure_inject.sh [scenario-a|scenario-b|scenario-c|scenario-d|scenario-e|all|--all]
# Default: runs only non-disruptive scenarios A, B, D (requires --all for C and E)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../../config/params.env
source "$REPO_ROOT/config/params.env"
# shellcheck source=../lib/evidence.sh
source "$REPO_ROOT/tests/lib/evidence.sh"

STATE_FILE_DEFAULT="/tmp/lte-watchdog.state"
STATE_FILE_FALLBACK="/tmp/lte-watchdog-state"
WATCHDOG_UNIT_NAME="lte-watchdog.service"

CURRENT_EVIDENCE_FILE=""
SCENARIO_D_CLEANUP_ARMED=0

scenario_evidence_begin() {
    local scenario_tag="$1"
    CURRENT_EVIDENCE_FILE="$REPO_ROOT/.sisyphus/evidence/task-19-${scenario_tag}.txt"
    mkdir -p "$(dirname "$CURRENT_EVIDENCE_FILE")"
    : > "$CURRENT_EVIDENCE_FILE"
    printf 'Task 19 %s evidence\n' "$scenario_tag" >> "$CURRENT_EVIDENCE_FILE"
    printf 'Timestamp: %s\n' "$(date -Iseconds)" >> "$CURRENT_EVIDENCE_FILE"
    printf 'Interface: %s\n\n' "${LTE_INTERFACE_NAME}" >> "$CURRENT_EVIDENCE_FILE"
}

record_line() {
    local line="$1"
    echo "$line"
    if [[ -n "$CURRENT_EVIDENCE_FILE" ]]; then
        printf '%s\n' "$line" >> "$CURRENT_EVIDENCE_FILE"
    fi
}

record_cmd() {
    local cmd="$1"
    record_line "\$ $cmd"
    local output
    output="$(bash -c "$cmd" 2>&1 || true)"
    if [[ -n "$output" ]]; then
        while IFS= read -r out_line; do
            record_line "$out_line"
        done <<< "$output"
    fi
}

ev_pass() {
    local check_name="$1"
    local detail="${2:-}"
    pass "$check_name" "$detail"
    if [[ -n "$detail" ]]; then
        printf '[PASS] %s: %s\n' "$check_name" "$detail" >> "$CURRENT_EVIDENCE_FILE"
    else
        printf '[PASS] %s\n' "$check_name" >> "$CURRENT_EVIDENCE_FILE"
    fi
}

ev_fail() {
    local check_name="$1"
    local detail="${2:-unknown reason}"
    fail "$check_name" "$detail"
    printf '[FAIL] %s: %s\n' "$check_name" "$detail" >> "$CURRENT_EVIDENCE_FILE"
}

ev_skip() {
    local check_name="$1"
    local reason="${2:-not applicable}"
    skip "$check_name" "$reason"
    printf '[SKIP] %s: %s\n' "$check_name" "$reason" >> "$CURRENT_EVIDENCE_FILE"
}

require_root_for_scenario() {
    local check_name="$1"
    if [[ "$(id -u)" -ne 0 ]]; then
        ev_skip "$check_name" "requires root privileges"
        return 1
    fi
    return 0
}

iface_ipv4() {
    ip -4 -o addr show dev "$LTE_INTERFACE_NAME" scope global 2>/dev/null | awk 'NR==1{print $4}' | cut -d/ -f1
}

iface_has_ipv4() {
    [[ -n "$(iface_ipv4)" ]]
}

iface_is_up() {
    local link_output
    link_output="$(ip link show "$LTE_INTERFACE_NAME" 2>/dev/null || true)"
    [[ -n "$link_output" ]] || return 1
    if [[ "$link_output" == *"state UP"* ]] || printf '%s' "$link_output" | grep -q '<[^>]*UP[^>]*>'; then
        return 0
    fi
    return 1
}

confirm_disruptive() {
    local scenario_name="$1"
    local warning="$2"

    echo "[WARN] ${scenario_name} is disruptive: ${warning}"
    read -r -p "Proceed with ${scenario_name}? [Y/N]: " response
    case "$response" in
        Y|y|YES|yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

wait_for_ipv4_restore() {
    local timeout_s="$1"
    local started
    started="$(date +%s)"

    while true; do
        if iface_has_ipv4; then
            local now elapsed ip
            now="$(date +%s)"
            elapsed=$((now - started))
            ip="$(iface_ipv4)"
            echo "restored:${elapsed}:${ip}"
            return 0
        fi

        local now elapsed
        now="$(date +%s)"
        elapsed=$((now - started))
        if [[ "$elapsed" -ge "$timeout_s" ]]; then
            break
        fi
        sleep 2
    done

    return 1
}

resolve_watchdog_state_file() {
    if [[ -n "${LTE_WATCHDOG_STATE_FILE:-}" ]]; then
        echo "$LTE_WATCHDOG_STATE_FILE"
        return 0
    fi
    if [[ -f "$STATE_FILE_DEFAULT" ]]; then
        echo "$STATE_FILE_DEFAULT"
        return 0
    fi
    echo "$STATE_FILE_FALLBACK"
}

recovery_invoked_since_epoch() {
    local since_epoch="$1"

    if [[ -n "${LTE_WATCHDOG_LOG_FILE:-}" && -f "${LTE_WATCHDOG_LOG_FILE}" ]]; then
        if grep -q "Invoking recovery hook" "${LTE_WATCHDOG_LOG_FILE}"; then
            return 0
        fi
        return 1
    fi

    if command -v journalctl >/dev/null 2>&1; then
        if journalctl -u "$WATCHDOG_UNIT_NAME" --since "@${since_epoch}" --no-pager 2>/dev/null | grep -q "Invoking recovery hook"; then
            return 0
        fi
        return 1
    fi

    return 2
}

send_at_command() {
    local at_port="$1"
    local at_cmd="$2"

    if [[ ! -c "$at_port" ]]; then
        return 1
    fi

    if ! exec 3<>"$at_port"; then
        return 1
    fi

    stty -F "$at_port" 115200 raw -echo 2>/dev/null || true
    printf '%s\r\n' "$at_cmd" >&3
    sleep 1
    local response
    response="$(timeout 4 cat <&3 2>/dev/null || true)"
    exec 3>&-

    printf '%s\n' "$response"
    return 0
}

cleanup_scenario_d() {
    if [[ "$SCENARIO_D_CLEANUP_ARMED" -eq 1 ]]; then
        iptables -D OUTPUT -d 8.8.8.8 -j DROP 2>/dev/null || true
        SCENARIO_D_CLEANUP_ARMED=0
    fi
}

scenario_a() {
    scenario_evidence_begin "scenario-a"
    record_line "Scenario A — DHCP lease loss"

    require_root_for_scenario "scenario-a" || return 0

    if ! ip link show "$LTE_INTERFACE_NAME" >/dev/null 2>&1; then
        ev_fail "scenario-a" "interface ${LTE_INTERFACE_NAME} not found"
        return 1
    fi

    record_cmd "ip -4 addr show dev ${LTE_INTERFACE_NAME}"
    ip addr flush dev "$LTE_INTERFACE_NAME" 2>/dev/null || true
    record_line "Injected fault: flushed IPv4 addresses on ${LTE_INTERFACE_NAME}"

    sleep 35
    local restored
    if restored="$(wait_for_ipv4_restore 25)"; then
        local elapsed ip
        elapsed="$(echo "$restored" | cut -d: -f2)"
        ip="$(echo "$restored" | cut -d: -f3)"
        ev_pass "scenario-a" "IPv4 restored in ${elapsed}s (${ip})"
        record_cmd "ip -4 addr show dev ${LTE_INTERFACE_NAME}"
        return 0
    fi

    record_cmd "ip -4 addr show dev ${LTE_INTERFACE_NAME}"
    ev_fail "scenario-a" "IPv4 not restored within 60s total wait"
    return 1
}

scenario_b() {
    scenario_evidence_begin "scenario-b"
    record_line "Scenario B — Interface down"

    require_root_for_scenario "scenario-b" || return 0

    if ! ip link show "$LTE_INTERFACE_NAME" >/dev/null 2>&1; then
        ev_fail "scenario-b" "interface ${LTE_INTERFACE_NAME} not found"
        return 1
    fi

    record_cmd "ip link show ${LTE_INTERFACE_NAME}"
    ip link set "$LTE_INTERFACE_NAME" down 2>/dev/null || true
    record_line "Injected fault: set ${LTE_INTERFACE_NAME} down"

    sleep 35

    local start now elapsed
    start="$(date +%s)"
    while true; do
        if iface_is_up && iface_has_ipv4; then
            now="$(date +%s)"
            elapsed=$((now - start + 35))
            ev_pass "scenario-b" "${LTE_INTERFACE_NAME} is UP with IPv4 after ${elapsed}s"
            record_cmd "ip link show ${LTE_INTERFACE_NAME}"
            record_cmd "ip -4 addr show dev ${LTE_INTERFACE_NAME}"
            return 0
        fi
        now="$(date +%s)"
        elapsed=$((now - start))
        if [[ "$elapsed" -ge 25 ]]; then
            break
        fi
        sleep 2
    done

    record_cmd "ip link show ${LTE_INTERFACE_NAME}"
    record_cmd "ip -4 addr show dev ${LTE_INTERFACE_NAME}"
    ev_fail "scenario-b" "${LTE_INTERFACE_NAME} not restored to UP+IPv4 within 60s"
    return 1
}

scenario_c() {
    scenario_evidence_begin "scenario-c"
    record_line "Scenario C — USB rebind (DISRUPTIVE)"

    require_root_for_scenario "scenario-c" || return 0

    if ! confirm_disruptive "scenario-c" "temporary USB unbind of cdc_ether"; then
        ev_skip "scenario-c" "operator declined disruptive test"
        return 0
    fi

    local net_dev_path usb_interface_id driver_path
    net_dev_path="$(readlink -f "/sys/class/net/${LTE_INTERFACE_NAME}/device" 2>/dev/null || true)"
    usb_interface_id="$(basename "$net_dev_path")"
    driver_path="/sys/bus/usb/drivers/${LTE_USB_DRIVER}"

    if [[ -z "$net_dev_path" || -z "$usb_interface_id" ]]; then
        ev_fail "scenario-c" "unable to resolve USB interface id for ${LTE_INTERFACE_NAME}"
        return 1
    fi
    if [[ ! -d "$driver_path" ]]; then
        ev_fail "scenario-c" "driver path missing: ${driver_path}"
        return 1
    fi

    cleanup_c() {
        if [[ -n "$usb_interface_id" && -w "${driver_path}/bind" ]]; then
            echo "$usb_interface_id" > "${driver_path}/bind" 2>/dev/null || true
        fi
    }

    trap cleanup_c RETURN

    record_line "USB interface id: ${usb_interface_id}"
    if ! echo "$usb_interface_id" > "${driver_path}/unbind" 2>/dev/null; then
        ev_fail "scenario-c" "failed to unbind ${usb_interface_id}"
        trap - RETURN
        cleanup_c
        return 1
    fi
    record_line "Injected fault: unbound ${usb_interface_id} from ${LTE_USB_DRIVER}"

    sleep 40

    local start now elapsed
    start="$(date +%s)"
    while true; do
        if ip link show "$LTE_INTERFACE_NAME" >/dev/null 2>&1 && iface_has_ipv4; then
            now="$(date +%s)"
            elapsed=$((now - start + 40))
            ev_pass "scenario-c" "${LTE_INTERFACE_NAME} present with IPv4 after ${elapsed}s"
            record_cmd "ip link show ${LTE_INTERFACE_NAME}"
            record_cmd "ip -4 addr show dev ${LTE_INTERFACE_NAME}"
            trap - RETURN
            cleanup_c
            return 0
        fi
        now="$(date +%s)"
        elapsed=$((now - start))
        if [[ "$elapsed" -ge 60 ]]; then
            break
        fi
        sleep 2
    done

    record_cmd "ip link show ${LTE_INTERFACE_NAME}"
    record_cmd "ip -4 addr show dev ${LTE_INTERFACE_NAME}"
    ev_fail "scenario-c" "${LTE_INTERFACE_NAME} not restored with IPv4 after USB rebind fault"
    trap - RETURN
    cleanup_c
    return 1
}

scenario_d() {
    scenario_evidence_begin "scenario-d"
    record_line "Scenario D — No-coverage simulation (iptables drop)"

    require_root_for_scenario "scenario-d" || return 0

    local watchdog_state_file since_epoch state recovery_check_rc
    watchdog_state_file="$(resolve_watchdog_state_file)"
    since_epoch="$(date +%s)"

    trap cleanup_scenario_d EXIT
    iptables -I OUTPUT -d 8.8.8.8 -j DROP
    SCENARIO_D_CLEANUP_ARMED=1
    record_line "Injected fault: iptables DROP rule for 8.8.8.8"
    record_cmd "iptables -S OUTPUT"

    sleep 30

    state=""
    if [[ -f "$watchdog_state_file" ]]; then
        state="$(tr -d '[:space:]' < "$watchdog_state_file")"
    fi

    recovery_invoked_since_epoch "$since_epoch"
    recovery_check_rc=$?

    cleanup_scenario_d
    trap - EXIT

    if [[ "$state" != "NO_COVERAGE" ]]; then
        record_cmd "test -f ${watchdog_state_file} && cat ${watchdog_state_file}"
        ev_fail "scenario-d" "watchdog state is '${state:-missing}', expected NO_COVERAGE"
        return 1
    fi

    if [[ "$recovery_check_rc" -eq 0 ]]; then
        ev_fail "scenario-d" "detected recovery executor invocation during NO_COVERAGE"
        return 1
    fi

    if [[ "$recovery_check_rc" -eq 2 ]]; then
        ev_fail "scenario-d" "unable to verify watchdog logs for recovery invocation"
        return 1
    fi

    ev_pass "scenario-d" "state=NO_COVERAGE and no recovery hook invocation observed"
    return 0
}

scenario_e() {
    scenario_evidence_begin "scenario-e"
    record_line "Scenario E — Full recovery (DISRUPTIVE)"

    require_root_for_scenario "scenario-e" || return 0

    if ! confirm_disruptive "scenario-e" "AT+CFUN airplane mode and modem restore"; then
        ev_skip "scenario-e" "operator declined disruptive test"
        return 0
    fi

    local at_port
    at_port="$(bash "$REPO_ROOT/scripts/find-at-port.sh" 2>/dev/null || true)"
    if [[ -z "$at_port" ]]; then
        ev_fail "scenario-e" "AT port discovery failed"
        return 1
    fi

    record_line "AT port: ${at_port}"

    local cfun4_response cfun1_response
    cfun4_response="$(send_at_command "$at_port" "AT+CFUN=4" || true)"
    record_line "AT+CFUN=4 response: $(echo "$cfun4_response" | tr '\r\n' ' ')"

    sleep 30

    cfun1_response="$(send_at_command "$at_port" "AT+CFUN=1" || true)"
    record_line "AT+CFUN=1 response: $(echo "$cfun1_response" | tr '\r\n' ' ')"

    local start now elapsed ip dns_output
    start="$(date +%s)"

    while true; do
        ip="$(iface_ipv4)"
        if [[ -n "$ip" ]]; then
            dns_output="$(dig +short +timeout=5 -b "$ip" google.com @8.8.8.8 2>/dev/null || true)"
            if [[ -n "$dns_output" ]]; then
                now="$(date +%s)"
                elapsed=$((now - start))
                ev_pass "scenario-e" "IPv4=${ip}; DNS probe ok after ${elapsed}s"
                record_line "DNS output: $(echo "$dns_output" | tr '\n' ',' | sed 's/,$//')"
                return 0
            fi
        fi

        now="$(date +%s)"
        elapsed=$((now - start))
        if [[ "$elapsed" -ge 60 ]]; then
            break
        fi
        sleep 2
    done

    record_cmd "ip -4 addr show dev ${LTE_INTERFACE_NAME}"
    ev_fail "scenario-e" "full recovery did not restore IPv4+DNS within 60s"
    return 1
}

run_named_scenario() {
    local scenario_name="$1"
    case "$scenario_name" in
        scenario-a) scenario_a ;;
        scenario-b) scenario_b ;;
        scenario-c) scenario_c ;;
        scenario-d) scenario_d ;;
        scenario-e) scenario_e ;;
        *)
            echo "Unknown scenario: $scenario_name"
            return 1
            ;;
    esac
}

usage() {
    cat <<'EOF'
Usage: bash tests/integration/failure_inject.sh [scenario-a|scenario-b|scenario-c|scenario-d|scenario-e|all|--all]

Default behavior (no args): runs non-disruptive scenarios only:
  scenario-a, scenario-b, scenario-d

Disruptive scenarios (always prompt for confirmation):
  scenario-c, scenario-e

Use --all or all to include all scenarios.
EOF
}

main() {
    local requested=()

    if [[ "$#" -eq 0 ]]; then
        requested=(scenario-a scenario-b scenario-d)
    else
        local include_all=0
        local arg
        for arg in "$@"; do
            case "$arg" in
                all|--all)
                    include_all=1
                    ;;
                scenario-a|scenario-b|scenario-c|scenario-d|scenario-e)
                    requested+=("$arg")
                    ;;
                -h|--help)
                    usage
                    exit 0
                    ;;
                *)
                    usage
                    exit 2
                    ;;
            esac
        done

        if [[ "$include_all" -eq 1 ]]; then
            requested=(scenario-a scenario-b scenario-c scenario-d scenario-e)
        fi
    fi

    if ! require_hardware; then
        summary
        exit 0
    fi

    local scenario rc=0
    for scenario in "${requested[@]}"; do
        run_named_scenario "$scenario" || rc=1
    done

    summary || rc=1
    exit "$rc"
}

main "$@"
