#!/usr/bin/env bats
#
# test-helper-functions.bats
# Dedicated tests for detect_change_scope(), should_run_quality_loop(),
# and get_max_review_attempts() helper functions.
#
# These tests focus on additional edge cases and integration behaviours
# not covered by existing test files.
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=main
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0
    export SCHEMA_DIR="$TEST_TMP/schemas"

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
    mkdir -p "$SCHEMA_DIR"

    # Create required schemas
    for schema in implement-issue-implement implement-issue-test implement-issue-review implement-issue-fix implement-issue-simplify; do
        echo '{"type":"object"}' > "$SCHEMA_DIR/${schema}.json"
    done

    # Create a fake git repo for detect_change_scope to work with
    mkdir -p "$TEST_TMP/repo"
    cd "$TEST_TMP/repo"
    git init -q
    git checkout -q -b main
    echo "initial" > README.md
    git add README.md
    git commit -q -m "initial"

    # Source the orchestrator functions
    source_orchestrator_functions

    # Initialize status
    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# detect_change_scope() — additional extension coverage
# =============================================================================

@test "detect_change_scope returns 'typescript' for .mjs files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-mjs
    echo "export const x = 1;" > util.mjs
    git add util.mjs
    git commit -q -m "add mjs"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for .cjs files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-cjs
    echo "module.exports = {};" > util.cjs
    git add util.cjs
    git commit -q -m "add cjs"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for .jsx files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-jsx
    echo "export default () => null;" > comp.jsx
    git add comp.jsx
    git commit -q -m "add jsx"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'config' for .toml files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-toml
    echo '[package]' > Cargo.toml
    git add Cargo.toml
    git commit -q -m "add toml"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'config' for .env files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-env
    echo "SECRET=abc" > .env
    git add .env
    git commit -q -m "add env"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'config' for .lock files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-lock
    echo "lockfileVersion: 1" > yarn.lock
    git add yarn.lock
    git commit -q -m "add lock"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'config' for .gitignore files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-gitignore
    echo "node_modules/" > .gitignore
    git add .gitignore
    git commit -q -m "add gitignore"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'bash' for .sh files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-bash
    echo "#!/usr/bin/env bash" > deploy.sh
    echo "echo hello" >> deploy.sh
    git add deploy.sh
    git commit -q -m "add sh"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .bats files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-bats
    echo "#!/usr/bin/env bats" > test-foo.bats
    git add test-foo.bats
    git commit -q -m "add bats"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'config' for empty diff (no changed files)" {
    cd "$TEST_TMP/repo"
    # HEAD == base → no changed files
    local scope
    scope=$(detect_change_scope "." "main" 2>/dev/null)
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'typescript' for unknown code files (.py)" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-python
    echo "x = 1" > script.py
    git add script.py
    git commit -q -m "add py"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'mixed' for ts + sh + config files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-mixed-with-config
    echo "export const x = 1;" > app.ts
    echo "#!/bin/bash" > deploy.sh
    echo "# changelog" > CHANGELOG.md
    git add app.ts deploy.sh CHANGELOG.md
    git commit -q -m "add ts sh and md"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "mixed" ]
}

@test "detect_change_scope returns 0 exit status on success" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-exit-status
    echo "export const x = 1;" > app.ts
    git add app.ts
    git commit -q -m "add ts"

    detect_change_scope "." "main"
    [ "$?" -eq 0 ]
}

# =============================================================================
# get_max_review_attempts() — edge cases
# =============================================================================

@test "get_max_review_attempts returns 1 for S-size" {
    local result
    result=$(get_max_review_attempts "S")
    [ "$result" -eq 1 ]
}

@test "get_max_review_attempts returns 2 for M-size" {
    local result
    result=$(get_max_review_attempts "M")
    [ "$result" -eq 2 ]
}

@test "get_max_review_attempts returns 3 for L-size" {
    local result
    result=$(get_max_review_attempts "L")
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for lowercase 's' (safe default)" {
    local result
    result=$(get_max_review_attempts "s" 2>/dev/null)
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for lowercase 'm' (safe default)" {
    local result
    result=$(get_max_review_attempts "m" 2>/dev/null)
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for lowercase 'l' (safe default)" {
    local result
    result=$(get_max_review_attempts "l" 2>/dev/null)
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for numeric string input (safe default)" {
    local result
    result=$(get_max_review_attempts "2" 2>/dev/null)
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts output is numeric (integer-comparable)" {
    local result
    result=$(get_max_review_attempts "M")
    # Arithmetic comparison fails if result is not a number
    [ "$result" -gt 0 ]
}

# =============================================================================
# should_run_quality_loop() — additional behaviours
# =============================================================================

@test "should_run_quality_loop returns 1 for S (same as get_max_review_attempts == 1)" {
    run should_run_quality_loop "S"
    [ "$status" -eq 1 ]
}

@test "should_run_quality_loop returns 0 for M (max_attempts > 1)" {
    run should_run_quality_loop "M"
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop returns 0 for L (max_attempts > 1)" {
    run should_run_quality_loop "L"
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop agrees with get_max_review_attempts for S: both indicate skip" {
    # get_max_review_attempts S == 1 means should_run_quality_loop S returns 1 (skip)
    local max
    max=$(get_max_review_attempts "S")
    run should_run_quality_loop "S"
    [ "$max" -eq 1 ]
    [ "$status" -eq 1 ]
}

@test "should_run_quality_loop agrees with get_max_review_attempts for M: both indicate run" {
    # get_max_review_attempts M == 2 means should_run_quality_loop M returns 0 (run)
    local max
    max=$(get_max_review_attempts "M")
    run should_run_quality_loop "M"
    [ "$max" -gt 1 ]
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop agrees with get_max_review_attempts for L: both indicate run" {
    local max
    max=$(get_max_review_attempts "L")
    run should_run_quality_loop "L"
    [ "$max" -gt 1 ]
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop returns 0 (run) for unrecognised size — safe default" {
    run should_run_quality_loop "XL"
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop returns 0 (run) for empty size — safe default" {
    run should_run_quality_loop ""
    [ "$status" -eq 0 ]
}

# =============================================================================
# is_stage_timeout() — timeout detection helper
# =============================================================================

@test "is_stage_timeout returns 0 (true) for timeout error JSON" {
    run is_stage_timeout '{"status":"error","error":"timeout"}'
    [ "$status" -eq 0 ]
}

@test "is_stage_timeout returns 1 (false) for successful result" {
    run is_stage_timeout '{"status":"success","result":"passed","summary":"All tests passed"}'
    [ "$status" -eq 1 ]
}

@test "is_stage_timeout returns 1 (false) for non-timeout error" {
    run is_stage_timeout '{"status":"error","error":"no structured output"}'
    [ "$status" -eq 1 ]
}

@test "is_stage_timeout returns 1 (false) for empty string" {
    run is_stage_timeout ''
    [ "$status" -eq 1 ]
}

@test "is_stage_timeout returns 1 (false) for schema-not-found error" {
    run is_stage_timeout '{"status":"error","error":"schema not found"}'
    [ "$status" -eq 1 ]
}

