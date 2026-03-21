#!/bin/bash
PASS=0
FAIL=0
ERRORS=""
PLUTUZ="./zig-out/bin/plutuz"

for expected_file in $(find conformance/tests -name "*.uplc.expected" | sort); do
    uplc_file="${expected_file%.expected}"
    test_name="${uplc_file#conformance/tests/}"
    expected=$(cat "$expected_file")
    budget_file="${uplc_file}.budget.expected"

    if [ "$expected" = "evaluation failure" ]; then
        actual=$($PLUTUZ "$uplc_file" 2>&1)
        exit_code=$?
        echo "--- $test_name ---"
        echo "  output:   ${actual:-<empty>} (exit $exit_code)"
        echo "  expected: evaluation failure"
        if [ $exit_code -ne 0 ]; then
            echo "  result:   PASS"
            PASS=$((PASS + 1))
        else
            echo "  result:   FAIL"
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}FAIL ${test_name}\n  Expected: evaluation failure\n  Got (exit 0): ${actual}\n\n"
        fi
    elif echo "$expected" | head -1 | grep -q "^parse error"; then
        actual=$($PLUTUZ "$uplc_file" 2>&1)
        exit_code=$?
        echo "--- $test_name ---"
        echo "  output:   ${actual:-<empty>} (exit $exit_code)"
        echo "  expected: parse error"
        if [ $exit_code -ne 0 ]; then
            echo "  result:   PASS"
            PASS=$((PASS + 1))
        else
            echo "  result:   FAIL"
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}FAIL ${test_name}\n  Expected: parse error\n  Got (exit 0): ${actual}\n\n"
        fi
    else
        # Should succeed — compare actual eval output to expected eval output
        full_output=$($PLUTUZ --budget "$uplc_file" 2>&1)
        exit_code=$?

        if [ $exit_code -ne 0 ]; then
            echo "--- $test_name ---"
            echo "  output:   ${full_output:-<empty>} (exit $exit_code)"
            echo "  expected: <success>"
            echo "  result:   FAIL"
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}FAIL ${test_name}\n  Expected success but got exit code ${exit_code}\n  Output: ${full_output}\n\n"
            continue
        fi

        # Split output: first line is the eval result, rest is the budget
        actual=$(echo "$full_output" | head -1)
        actual_budget=$(echo "$full_output" | tail -n +2)

        # Parse+eval the expected file to get its term output
        expected_eval=$($PLUTUZ "$expected_file" 2>&1)
        ee_exit=$?

        if [ $ee_exit -ne 0 ]; then
            echo "--- $test_name ---"
            echo "  output:   $actual"
            echo "  expected: <could not eval expected file>"
            echo "  result:   FAIL"
            FAIL=$((FAIL + 1))
            ERRORS="${ERRORS}FAIL ${test_name}\n  Could not eval expected file (exit ${ee_exit}): ${expected_eval}\n\n"
            continue
        fi

        echo "--- $test_name ---"
        echo "  output:   $actual"
        echo "  expected: $expected_eval"

        # Compare eval results
        result_match=true
        if [ "$actual" != "$expected_eval" ]; then
            result_match=false
        fi

        # Compare budgets
        budget_match=true
        if [ -f "$budget_file" ]; then
            expected_budget=$(cat "$budget_file" | tr -d '[:space:]')
            actual_budget_trimmed=$(echo "$actual_budget" | tr -d '[:space:]')
            echo "  budget:   $(echo "$actual_budget" | tr '\n' ' ')"
            echo "  exp budg: $(cat "$budget_file" | tr '\n' ' ')"
            if [ "$actual_budget_trimmed" != "$expected_budget" ]; then
                budget_match=false
            fi
        fi

        if $result_match && $budget_match; then
            echo "  result:   PASS"
            PASS=$((PASS + 1))
        else
            echo "  result:   FAIL"
            FAIL=$((FAIL + 1))
            if ! $result_match; then
                ERRORS="${ERRORS}FAIL ${test_name}\n  Expected: ${expected_eval}\n  Actual:   ${actual}\n\n"
            fi
            if ! $budget_match; then
                ERRORS="${ERRORS}FAIL ${test_name} (budget)\n  Expected: $(cat "$budget_file" | tr '\n' ' ')\n  Actual:   $(echo "$actual_budget" | tr '\n' ' ')\n\n"
            fi
        fi
    fi
done

echo ""
echo "===== RESULTS ====="
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
echo ""
if [ $FAIL -gt 0 ]; then
    echo "===== FAILURES ====="
    echo -e "$ERRORS"
fi
