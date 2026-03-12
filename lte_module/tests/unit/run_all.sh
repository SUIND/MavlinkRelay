#!/usr/bin/env bash
# Unit test runner — runs all offline unit tests
# HARDWARE_REQUIRED: no

source "$(dirname "$0")/../lib/evidence.sh"

tests_dir="$(dirname "$0")"
test_count=0
runner_fail_count=0

# Find and run all unit tests
for test_file in "$tests_dir"/test_*.sh; do
    if [ -f "$test_file" ]; then
        test_count=$((test_count + 1))
        test_name=$(basename "$test_file")
        echo "Running $test_name..."
        
        # Run test in subprocess to prevent failures from aborting runner
        if bash "$test_file"; then
            echo "  ✓ $test_name passed"
        else
            echo "  ✗ $test_name failed"
            runner_fail_count=$((runner_fail_count + 1))
        fi
    fi
done

if [ "$test_count" -eq 0 ]; then
    echo "No unit tests found in $tests_dir"
fi

# Exit with failure if any tests failed
exit "$runner_fail_count"
