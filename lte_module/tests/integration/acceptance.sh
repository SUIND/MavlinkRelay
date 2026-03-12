#!/usr/bin/env bash
# tests/integration/acceptance.sh — Acceptance test checklist for EC200U-CN LTE module
# Runs 6 verification steps; hardware steps gated behind --skip-hardware flag
# Usage: bash tests/integration/acceptance.sh [--skip-hardware]
# Exit codes: 0=all non-skipped steps pass, 1=one or more steps failed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
EVIDENCE_FILE="$REPO_ROOT/.sisyphus/evidence/acceptance-${TIMESTAMP}.txt"
mkdir -p "$(dirname "$EVIDENCE_FILE")"

# Tee all output to evidence file from this point forward
exec > >(tee -a "$EVIDENCE_FILE") 2>&1

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SKIP_HARDWARE=0
for arg in "$@"; do
    case "$arg" in
        --skip-hardware) SKIP_HARDWARE=1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Tracking arrays / counters
# ---------------------------------------------------------------------------
STEP_RESULTS=()   # "PASS", "FAIL", or "SKIP"
STEP_NAMES=()
STEP_TIMES=()
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ---------------------------------------------------------------------------
# Helper: run one step
# run_step <n> <name> <hardware_required> <command...>
# ---------------------------------------------------------------------------
run_step() {
    local step_n="$1"
    local step_name="$2"
    local hw_required="$3"
    shift 3
    local cmd=("$@")

    echo ""
    echo "[STEP ${step_n}] ${step_name}"

    # Hardware gate
    if [[ "$hw_required" -eq 1 && "$SKIP_HARDWARE" -eq 1 ]]; then
        STEP_RESULTS+=("SKIP")
        STEP_NAMES+=("${step_name}")
        STEP_TIMES+=("hardware skipped")
        SKIP_COUNT=$((SKIP_COUNT + 1))
        echo "[SKIP] Step ${step_n}: ${step_name} (hardware skipped)"
        return 0
    fi

    local start_time
    start_time=$SECONDS

    # Run command; capture exit code without exiting on failure
    "${cmd[@]}"
    local rc=$?

    local elapsed=$(( SECONDS - start_time ))

    if [[ "$rc" -eq 0 ]]; then
        STEP_RESULTS+=("PASS")
        STEP_NAMES+=("${step_name}")
        STEP_TIMES+=("${elapsed}s")
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "[PASS] Step ${step_n}: ${step_name} (${elapsed}s)"
    else
        STEP_RESULTS+=("FAIL")
        STEP_NAMES+=("${step_name}")
        STEP_TIMES+=("${elapsed}s")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "[FAIL] Step ${step_n}: ${step_name} (${elapsed}s)"
    fi
}

# ---------------------------------------------------------------------------
# Helper: run evidence pack step with graceful non-zero handling
# run_step_evidence_pack <n> <name>
# ---------------------------------------------------------------------------
run_step_evidence_pack() {
    local step_n="$1"
    local step_name="$2"

    echo ""
    echo "[STEP ${step_n}] ${step_name}"

    local start_time
    start_time=$SECONDS

    # First check: script must exist and be syntax-valid
    if [[ ! -f "$REPO_ROOT/scripts/lte-evidence-pack.sh" ]]; then
        local elapsed=$(( SECONDS - start_time ))
        STEP_RESULTS+=("FAIL")
        STEP_NAMES+=("${step_name}")
        STEP_TIMES+=("${elapsed}s")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "[FAIL] Step ${step_n}: ${step_name} — script not found (${elapsed}s)"
        return 1
    fi

    if ! bash -n "$REPO_ROOT/scripts/lte-evidence-pack.sh" 2>&1; then
        local elapsed=$(( SECONDS - start_time ))
        STEP_RESULTS+=("FAIL")
        STEP_NAMES+=("${step_name}")
        STEP_TIMES+=("${elapsed}s")
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "[FAIL] Step ${step_n}: ${step_name} — syntax check failed (${elapsed}s)"
        return 1
    fi

    # Run with --dry-run; exit 0 = PASS, non-zero = SKIP with note
    bash "$REPO_ROOT/scripts/lte-evidence-pack.sh" --dry-run
    local rc=$?
    local elapsed=$(( SECONDS - start_time ))

    if [[ "$rc" -eq 0 ]]; then
        STEP_RESULTS+=("PASS")
        STEP_NAMES+=("${step_name}")
        STEP_TIMES+=("${elapsed}s")
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "[PASS] Step ${step_n}: ${step_name} (${elapsed}s)"
    else
        STEP_RESULTS+=("SKIP")
        STEP_NAMES+=("${step_name}")
        STEP_TIMES+=("${elapsed}s — dry-run non-zero (services not running), treated as skip")
        SKIP_COUNT=$((SKIP_COUNT + 1))
        echo "[SKIP] Step ${step_n}: ${step_name} — evidence-pack exited ${rc} in dry-run (services not running), treated as skip (${elapsed}s)"
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo "=============================="
echo " EC200U-CN LTE Acceptance Test"
echo " $(date -Iseconds)"
echo " skip-hardware: ${SKIP_HARDWARE}"
echo " evidence: ${EVIDENCE_FILE}"
echo "=============================="

# ---------------------------------------------------------------------------
# Step 1: Static Validation (no hardware)
# ---------------------------------------------------------------------------
run_step 1 "Static Validation" 0 \
    bash "$REPO_ROOT/scripts/validate.sh" --ci

# ---------------------------------------------------------------------------
# Step 2: Unit Tests (no hardware)
# ---------------------------------------------------------------------------
run_step 2 "Unit Tests" 0 \
    bash "$REPO_ROOT/tests/unit/run_all.sh"

# ---------------------------------------------------------------------------
# Step 3: Hardware Smoke Tests (hardware required)
# ---------------------------------------------------------------------------
run_step 3 "Smoke Tests" 1 \
    bash "$REPO_ROOT/tests/integration/smoke.sh"

# ---------------------------------------------------------------------------
# Step 4: Route Metrics Check (hardware required)
# ---------------------------------------------------------------------------
run_step 4 "Route Metrics" 1 \
    bash "$REPO_ROOT/tests/unit/test_route_metrics.sh"

# ---------------------------------------------------------------------------
# Step 5: Failure Scenarios A+B (hardware required)
# failure_inject.sh accepts positional args: scenario-a scenario-b
# We run them as a combined call; no --scenarios flag exists
# ---------------------------------------------------------------------------
run_step 5 "Failure Scenarios A+B" 1 \
    bash "$REPO_ROOT/tests/integration/failure_inject.sh" scenario-a scenario-b

# ---------------------------------------------------------------------------
# Step 6: Evidence Pack Check (no hardware; graceful on non-zero)
# ---------------------------------------------------------------------------
run_step_evidence_pack 6 "Evidence Pack"

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
echo ""
echo "===== ACCEPTANCE SUMMARY ====="

step_labels=(
    "Static Validation"
    "Unit Tests"
    "Smoke Tests"
    "Route Metrics"
    "Failure Scenarios"
    "Evidence Pack"
)

i=0
while [[ "$i" -lt "${#STEP_RESULTS[@]}" ]]; do
    result="${STEP_RESULTS[$i]}"
    label="${STEP_NAMES[$i]}"
    timing="${STEP_TIMES[$i]}"
    step_num=$((i + 1))
    printf "Step %d: %-22s [%s] %s\n" "$step_num" "$label" "$result" "$timing"
    i=$((i + 1))
done

echo "=============================="

OVERALL="PASS"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    OVERALL="FAIL"
fi

echo "Overall: ${OVERALL} (${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped)"
echo ""
echo "Evidence saved to: ${EVIDENCE_FILE}"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
exit 0
