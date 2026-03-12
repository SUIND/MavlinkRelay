#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/evidence.sh"

SCRIPT="$REPO_ROOT/scripts/lte-watchdog.sh"
TMP_ROOT="$(mktemp -d)"

pid1=""
cleanup() {
    if [ -n "$pid1" ] && kill -0 "$pid1" 2>/dev/null; then
        kill "$pid1" 2>/dev/null || true
        wait "$pid1" 2>/dev/null || true
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

lockfile="$TMP_ROOT/lte-watchdog.pid"

state1="$TMP_ROOT/state-1"
log1="$TMP_ROOT/log-1"
LTE_WATCHDOG_MOCK_MODE=1 \
LTE_WATCHDOG_MOCK_IFACE_UP=1 \
LTE_WATCHDOG_MOCK_IP=10.10.10.2 \
LTE_WATCHDOG_MOCK_DNS=1 \
LTE_WATCHDOG_LOCKFILE="$lockfile" \
LTE_WATCHDOG_STATE_FILE="$state1" \
LTE_WATCHDOG_CHECK_INTERVAL_S=1 \
LTE_WATCHDOG_DEGRADED_INTERVAL_S=1 \
LTE_WATCHDOG_LOG_FILE="$log1" \
"$SCRIPT" >/dev/null 2>&1 &
pid1=$!
sleep 1

singleton_exit=0
state2="$TMP_ROOT/state-2"
log2="$TMP_ROOT/log-2"
if LTE_WATCHDOG_MOCK_MODE=1 \
   LTE_WATCHDOG_MOCK_IFACE_UP=1 \
   LTE_WATCHDOG_MOCK_IP=10.10.10.2 \
   LTE_WATCHDOG_MOCK_DNS=1 \
   LTE_WATCHDOG_LOCKFILE="$lockfile" \
   LTE_WATCHDOG_STATE_FILE="$state2" \
   LTE_WATCHDOG_ONE_SHOT=1 \
   LTE_WATCHDOG_LOG_FILE="$log2" \
   "$SCRIPT" >/dev/null 2>&1; then
    singleton_exit=0
else
    singleton_exit=$?
fi

if [ -n "$pid1" ] && kill -0 "$pid1" 2>/dev/null && [ "$singleton_exit" -ne 0 ]; then
    pass "singleton-lockfile" "second instance exits non-zero while first is active"
    save_evidence "task-13-singleton.txt" "PASS singleton lockfile enforced (second exit=$singleton_exit)"
else
    fail "singleton-lockfile" "expected second instance failure with active first process"
    save_evidence "task-13-singleton.txt" "FAIL singleton lockfile test (second exit=$singleton_exit)"
fi

kill "$pid1" 2>/dev/null || true
wait "$pid1" 2>/dev/null || true
pid1=""

state_nc="$TMP_ROOT/state-no-coverage"
log_nc="$TMP_ROOT/log-no-coverage"
recovery_marker="$TMP_ROOT/recovery-called"
recovery_mock="$TMP_ROOT/lte-recovery.sh"
cat > "$recovery_mock" <<EOF
#!/usr/bin/env bash
touch "$recovery_marker"
exit 0
EOF
chmod +x "$recovery_mock"

nc_exit=0
if LTE_WATCHDOG_MOCK_MODE=1 \
   LTE_WATCHDOG_MOCK_IFACE_UP=1 \
   LTE_WATCHDOG_MOCK_IP=10.10.10.2 \
   LTE_WATCHDOG_MOCK_DNS=0 \
   LTE_WATCHDOG_MOCK_REG_STAT=0 \
   LTE_WATCHDOG_LOCKFILE="$TMP_ROOT/nc.pid" \
   LTE_WATCHDOG_STATE_FILE="$state_nc" \
   LTE_WATCHDOG_LOG_FILE="$log_nc" \
   LTE_WATCHDOG_RECOVERY_SCRIPT="$recovery_mock" \
   LTE_WATCHDOG_ONE_SHOT=1 \
   "$SCRIPT" >/dev/null 2>&1; then
    nc_exit=0
else
    nc_exit=$?
fi

state_value_nc=""
if [ -f "$state_nc" ]; then
    state_value_nc="$(cat "$state_nc")"
fi

if [ "$nc_exit" -eq 0 ] && [ "$state_value_nc" = "NO_COVERAGE" ] && [ ! -f "$recovery_marker" ]; then
    pass "no-coverage-no-recovery" "state NO_COVERAGE recorded and recovery hook not called"
    save_evidence "task-13-no-coverage.txt" "PASS NO_COVERAGE path (state=$state_value_nc, recovery_called=0)"
else
    fail "no-coverage-no-recovery" "expected state NO_COVERAGE and no recovery invocation"
    save_evidence "task-13-no-coverage.txt" "FAIL NO_COVERAGE path (exit=$nc_exit, state=$state_value_nc, recovery_called=$([ -f "$recovery_marker" ] && echo 1 || echo 0))"
fi

state_log="$TMP_ROOT/state-log"
log_transition="$TMP_ROOT/log-transition"
st_exit=0
if LTE_WATCHDOG_MOCK_MODE=1 \
   LTE_WATCHDOG_MOCK_IFACE_UP=1 \
   LTE_WATCHDOG_MOCK_IP=10.10.10.2 \
   LTE_WATCHDOG_MOCK_DNS=0 \
   LTE_WATCHDOG_MOCK_REG_STAT=1 \
   LTE_WATCHDOG_LOCKFILE="$TMP_ROOT/st.pid" \
   LTE_WATCHDOG_STATE_FILE="$state_log" \
   LTE_WATCHDOG_LOG_FILE="$log_transition" \
   LTE_WATCHDOG_ONE_SHOT=1 \
   "$SCRIPT" >/dev/null 2>&1; then
    st_exit=0
else
    st_exit=$?
fi

transition_line=""
if [ -f "$log_transition" ]; then
    transition_line="$(grep -m1 'STATE HEALTHY -> DEGRADED' "$log_transition" || true)"
fi

if [ "$st_exit" -eq 0 ] && [ -n "$transition_line" ]; then
    pass "state-transition-log" "logged HEALTHY -> DEGRADED transition"
    save_evidence "task-13-state-log.txt" "$transition_line"
else
    fail "state-transition-log" "missing transition log entry"
    save_evidence "task-13-state-log.txt" "FAIL missing HEALTHY -> DEGRADED log entry"
fi

reboot_hits="$(grep -nE '\breboot\b|shutdown[[:space:]]+-r|systemctl[[:space:]]+reboot' "$REPO_ROOT/scripts/lte-watchdog.sh" "$REPO_ROOT/units/lte-watchdog.service" 2>/dev/null || true)"
if [ -z "$reboot_hits" ]; then
    pass "no-reboot-action" "no reboot/shutdown/systemctl reboot command found"
    save_evidence "task-13-no-reboot.txt" "PASS no reboot command found in watchdog files"
else
    fail "no-reboot-action" "forbidden reboot command found"
    save_evidence "task-13-no-reboot.txt" "FAIL forbidden reboot command found: $reboot_hits"
fi

if bash -n "$SCRIPT" 2>/tmp/bash_n_watchdog_err; then
    pass "watchdog-syntax" "bash -n scripts/lte-watchdog.sh"
else
    err_text="$(cat /tmp/bash_n_watchdog_err)"
    fail "watchdog-syntax" "$err_text"
fi

summary
