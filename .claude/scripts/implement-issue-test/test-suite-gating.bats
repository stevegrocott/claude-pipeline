#!/usr/bin/env bats
#
# test-suite-gating.bats
# Issue #1018: run-tests.sh discovers suites with `test-*.bats`, so a .bats file
# named any other way is run by nothing. Guard: every *.bats in this directory
# must be gated by that glob or listed in UNGATED_SUITES.

RUNNER="$(cd "$BATS_TEST_DIRNAME" && pwd)/run-tests.sh"

@test "every .bats file is gated or explicitly excluded" {
    run "$RUNNER" --check-gating
    [ "$status" -eq 0 ]
}

@test "guard fails on an unlisted, ungated .bats file" {
    local stray="$BATS_TEST_DIRNAME/zz-stray-ungated.bats"
    : > "$stray"
    run "$RUNNER" --check-gating
    rm -f "$stray"
    [ "$status" -eq 1 ]
    [[ "$output" == *"zz-stray-ungated.bats"* ]]
}
