#!/usr/bin/env bash
# Convenience validation runner: static checks + full unit suite
# Supports --ci flag for machine-readable output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CI_MODE=0
for arg in "$@"; do
    case "$arg" in
        --ci) CI_MODE=1 ;;
    esac
done

if [ "$CI_MODE" -eq 1 ]; then
    export TERM=dumb
fi

STATIC_TEST="$REPO_ROOT/tests/unit/test_static_validation.sh"
UNIT_RUNNER="$REPO_ROOT/tests/unit/run_all.sh"

static_exit=0
unit_exit=0

if [ "$CI_MODE" -eq 1 ]; then
    echo "::group::static-validation"
fi
echo "=== Running static validation ==="
bash "$STATIC_TEST" || static_exit=$?
if [ "$CI_MODE" -eq 1 ]; then
    echo "::endgroup::"
fi

if [ "$CI_MODE" -eq 1 ]; then
    echo "::group::unit-tests"
fi
echo ""
echo "=== Running unit tests ==="
bash "$UNIT_RUNNER" || unit_exit=$?
if [ "$CI_MODE" -eq 1 ]; then
    echo "::endgroup::"
fi

echo ""
echo "=== Validate Summary ==="
if [ "$CI_MODE" -eq 1 ]; then
    echo "static_exit=$static_exit"
    echo "unit_exit=$unit_exit"
else
    [ "$static_exit" -eq 0 ] && echo "  static:     PASS" || echo "  static:     FAIL (exit $static_exit)"
    [ "$unit_exit"   -eq 0 ] && echo "  unit tests: PASS" || echo "  unit tests: FAIL (exit $unit_exit)"
fi

overall=$((static_exit + unit_exit))
[ "$overall" -eq 0 ] && echo "  overall:    PASS" || echo "  overall:    FAIL"
exit "$overall"
