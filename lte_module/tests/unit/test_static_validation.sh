#!/usr/bin/env bash
# Unit test: static validation — syntax-checks all shell scripts and scans for forbidden patterns
# HARDWARE_REQUIRED: no

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/../lib/evidence.sh"

EVIDENCE_FILE="task-12-static.txt"
evidence_lines=()

log() {
    local line="$*"
    echo "$line"
    evidence_lines+=("$line")
}

# ── helpers ────────────────────────────────────────────────────────────────────

run_check_pass() {
    pass "$1" "$2"
    evidence_lines+=("[PASS] $1: $2")
}

run_check_fail() {
    fail "$1" "$2"
    evidence_lines+=("[FAIL] $1: $2")
}

run_check_skip() {
    skip "$1" "$2"
    evidence_lines+=("[SKIP] $1: $2")
}

# ── collect shell scripts ──────────────────────────────────────────────────────

log "=== Static Validation ==="
log "Repo root: $REPO_ROOT"
log "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log ""

mapfile -t SHELL_FILES < <(
    find "$REPO_ROOT/scripts" "$REPO_ROOT/tests" -name "*.sh" -type f | sort
)

log "Found ${#SHELL_FILES[@]} shell script(s):"
for f in "${SHELL_FILES[@]}"; do
    log "  ${f#"$REPO_ROOT/"}"
done
log ""

if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
    run_check_skip "bash-syntax-check" "no .sh files found — nothing to check"
    run_check_skip "shellcheck" "no .sh files found — nothing to check"
else

    # ── bash -n syntax check ───────────────────────────────────────────────────
    log "--- bash -n syntax checks ---"
    for f in "${SHELL_FILES[@]}"; do
        rel="${f#"$REPO_ROOT/"}"
        if bash -n "$f" 2>/tmp/bash_n_err; then
            pass "bash-n: $rel" "syntax OK"
            evidence_lines+=("[PASS] bash-n: $rel: syntax OK")
        else
            err=$(cat /tmp/bash_n_err)
            fail "bash-n: $rel" "$err"
            evidence_lines+=("[FAIL] bash-n: $rel: $err")
        fi
    done
    log ""

    # ── shellcheck ────────────────────────────────────────────────────────────
    log "--- shellcheck checks ---"
    if ! command -v shellcheck &>/dev/null; then
        for f in "${SHELL_FILES[@]}"; do
            rel="${f#"$REPO_ROOT/"}"
            skip "shellcheck: $rel" "shellcheck not installed"
            evidence_lines+=("[SKIP] shellcheck: $rel: shellcheck not installed")
        done
    else
        sc_version=$(shellcheck --version | grep 'version:' | awk '{print $2}')
        log "shellcheck version: $sc_version"
        for f in "${SHELL_FILES[@]}"; do
            rel="${f#"$REPO_ROOT/"}"
            if shellcheck -S warning "$f" 2>/tmp/sc_err; then
                pass "shellcheck: $rel" "no warnings/errors"
                evidence_lines+=("[PASS] shellcheck: $rel: no warnings/errors")
            else
                err=$(cat /tmp/sc_err | head -20)
                fail "shellcheck: $rel" "$err"
                evidence_lines+=("[FAIL] shellcheck: $rel: $err")
            fi
        done
    fi
    log ""

fi

log "--- forbidden pattern checks ---"

_active_grep() {
    local pattern="$1"
    local file="$2"
    grep -nP "$pattern" "$file" 2>/dev/null \
        | grep -vP '^\d+:\s*#' \
        || true
}

FORBIDDEN_FILES=()
for _f in "${SHELL_FILES[@]}"; do
    case "$_f" in
        *test_static_validation.sh) ;;
        *test_find_at_port.sh) ;;      # uses /dev/ttyUSBN as mock port values only
        *test_watchdog.sh) ;;          # greps for forbidden patterns as a validator — not active commands
        *test_recovery.sh) ;;          # uses /dev/ttyUSB2 as mock port arg and greps for reboot as a validator
        *) FORBIDDEN_FILES+=("$_f") ;;
    esac
done

# Check 1: hardcoded /dev/ttyUSB2
log "Checking: no hardcoded /dev/ttyUSB2 as active code path"
ttyusb2_hits=0
for f in "${FORBIDDEN_FILES[@]}"; do
    rel="${f#"$REPO_ROOT/"}"
    hits=$(_active_grep '/dev/ttyUSB2' "$f")
    if [ -n "$hits" ]; then
        fail "no-hardcoded-ttyUSB2: $rel" "found: $hits"
        evidence_lines+=("[FAIL] no-hardcoded-ttyUSB2: $rel: found: $hits")
        ttyusb2_hits=$((ttyusb2_hits + 1))
    fi
done
if [ "$ttyusb2_hits" -eq 0 ]; then
    pass "no-hardcoded-ttyUSB2" "no active /dev/ttyUSB2 references found"
    evidence_lines+=("[PASS] no-hardcoded-ttyUSB2: no active /dev/ttyUSB2 references found")
fi

# Check 2: reboot / shutdown -r / systemctl reboot
log "Checking: no reboot/shutdown/systemctl-reboot active commands"
reboot_hits=0
for f in "${FORBIDDEN_FILES[@]}"; do
    rel="${f#"$REPO_ROOT/"}"
    hits=$(_active_grep '\breboot\b|shutdown\s+-r|systemctl\s+reboot' "$f")
    if [ -n "$hits" ]; then
        fail "no-reboot-cmd: $rel" "found: $hits"
        evidence_lines+=("[FAIL] no-reboot-cmd: $rel: found: $hits")
        reboot_hits=$((reboot_hits + 1))
    fi
done
if [ "$reboot_hits" -eq 0 ]; then
    pass "no-reboot-cmd" "no active reboot/shutdown/systemctl-reboot found"
    evidence_lines+=("[PASS] no-reboot-cmd: no active reboot/shutdown/systemctl-reboot found")
fi

# Check 3: OTG role-switch pattern echo host > /sys
log "Checking: no OTG role-switch (echo host > /sys)"
otg_hits=0
for f in "${FORBIDDEN_FILES[@]}"; do
    rel="${f#"$REPO_ROOT/"}"
    hits=$(_active_grep 'echo\s+host\s*>\s*/sys' "$f")
    if [ -n "$hits" ]; then
        fail "no-otg-role-switch: $rel" "found: $hits"
        evidence_lines+=("[FAIL] no-otg-role-switch: $rel: found: $hits")
        otg_hits=$((otg_hits + 1))
    fi
done
if [ "$otg_hits" -eq 0 ]; then
    pass "no-otg-role-switch" "no OTG role-switch pattern found"
    evidence_lines+=("[PASS] no-otg-role-switch: no OTG role-switch pattern found")
fi

log ""

# ── save evidence ──────────────────────────────────────────────────────────────
{
    printf '%s\n' "${evidence_lines[@]}"
    echo "---"
    echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
} > "$EVIDENCE_DIR/$EVIDENCE_FILE"

log "Evidence saved to $EVIDENCE_DIR/$EVIDENCE_FILE"

# ── summary ────────────────────────────────────────────────────────────────────
summary
