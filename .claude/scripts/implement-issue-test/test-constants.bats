#!/usr/bin/env bats
#
# test-constants.bats
# Tests for configuration constants and defaults
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    # Source the orchestrator functions
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# TIMEOUT CONSTANTS
# =============================================================================

@test "STAGE_TIMEOUT is 1 hour" {
    [ "$STAGE_TIMEOUT" -eq 3600 ]
}

# =============================================================================
# RETRY LIMITS
# =============================================================================

@test "MAX_QUALITY_ITERATIONS is 5" {
    [ "$MAX_QUALITY_ITERATIONS" -eq 5 ]
}

@test "MAX_PR_REVIEW_ITERATIONS is 2" {
    [ "$MAX_PR_REVIEW_ITERATIONS" -eq 2 ]
}

# =============================================================================
# RATE LIMIT CONSTANTS
# =============================================================================

@test "RATE_LIMIT_BUFFER is 60 seconds" {
    [ "$RATE_LIMIT_BUFFER" -eq 60 ]
}

@test "RATE_LIMIT_DEFAULT_WAIT is 1 hour" {
    [ "$RATE_LIMIT_DEFAULT_WAIT" -eq 3600 ]
}

# =============================================================================
# SCRIPT PATHS
# =============================================================================

@test "SCRIPT_DIR is defined" {
    [ -n "$SCRIPT_DIR" ]
}

@test "SCHEMA_DIR is under SCRIPT_DIR" {
    [[ "$SCHEMA_DIR" == "$SCRIPT_DIR"* ]] || [[ "$SCHEMA_DIR" == *"/schemas" ]]
}

# =============================================================================
# DEFAULT VALUES
# =============================================================================

@test "default STATUS_FILE is status.json" {
    # Re-source with fresh defaults
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *'STATUS_FILE="status.json"'* ]]
}

@test "AGENT defaults to empty string" {
    # Parse script to verify default
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *'AGENT=""'* ]]
}

# =============================================================================
# READONLY DECLARATIONS
# =============================================================================

@test "timeout constants are readonly" {
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *"readonly STAGE_TIMEOUT"* ]]
    [[ "$script_content" == *"readonly MAX_QUALITY_ITERATIONS"* ]]
    [[ "$script_content" == *"readonly MAX_PR_REVIEW_ITERATIONS"* ]]
    [[ "$script_content" == *"readonly RATE_LIMIT_BUFFER"* ]]
    [[ "$script_content" == *"readonly RATE_LIMIT_DEFAULT_WAIT"* ]]
}

# =============================================================================
# EXIT CODES
# =============================================================================

@test "usage exits with code 3" {
    run bash "$ORCHESTRATOR_SCRIPT" --help 2>&1
    [ "$status" -eq 3 ]
}

@test "script uses documented exit codes" {
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    # Verify script uses the documented exit codes:
    # 0 = success, 1 = error, 2 = max iterations, 3 = usage
    [[ "$script_content" == *"exit 0"* ]]
    [[ "$script_content" == *"exit 1"* ]]
    [[ "$script_content" == *"exit 2"* ]]
    [[ "$script_content" == *"exit 3"* ]]
}

# =============================================================================
# SHELL OPTIONS
# =============================================================================

@test "script uses set -uo pipefail" {
    local script_content
    script_content=$(head -20 "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *"set -uo pipefail"* ]]
}

@test "script does not use set -e (handles errors explicitly)" {
    local script_content
    script_content=$(head -20 "$ORCHESTRATOR_SCRIPT")

    # Should NOT have set -e or set -euo (errexit causes unpredictable behavior)
    # The script should use explicit error handling instead
    if [[ "$script_content" == *"set -e"* ]] && [[ "$script_content" != *"set -uo pipefail"* ]]; then
        fail "Script uses 'set -e' which causes unpredictable error handling. Use explicit checks instead."
    fi
    # Verify it uses the preferred pattern: set -uo pipefail (without -e)
    [[ "$script_content" == *"set -uo pipefail"* ]] || \
        fail "Script should use 'set -uo pipefail' (without -e) for error handling"
}

# =============================================================================
# get_max_review_attempts() - SCALED REVIEW CAPS BY TASK SIZE
# =============================================================================

@test "get_max_review_attempts is defined" {
    [ "$(type -t get_max_review_attempts)" = "function" ]
}

@test "get_max_review_attempts returns 1 for S-size tasks" {
    local result
    result=$(get_max_review_attempts "S")
    [ "$result" -eq 1 ]
}

@test "get_max_review_attempts returns 2 for M-size tasks" {
    local result
    result=$(get_max_review_attempts "M")
    [ "$result" -eq 2 ]
}

@test "get_max_review_attempts returns 3 for L-size tasks" {
    local result
    result=$(get_max_review_attempts "L")
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for unknown size (safe default)" {
    local result
    result=$(get_max_review_attempts "")
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for unrecognised size (safe default)" {
    local result
    result=$(get_max_review_attempts "XL")
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts emits warning to stderr for unrecognised size" {
    # Capture stderr to a temp file; stdout must still be 3
    local stderr_file="$TEST_TMP/warn_stderr.txt"
    local stdout_val
    stdout_val=$(get_max_review_attempts "XL" 2>"$stderr_file")

    [ "$stdout_val" = "3" ]
    grep -q "WARN" "$stderr_file"
}

@test "while loop uses get_max_review_attempts not fixed MAX_TASK_REVIEW_ATTEMPTS" {
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    # Must call the function
    [[ "$script_content" == *"get_max_review_attempts"* ]]

    # max_attempts must be pre-computed from the function before the loop
    [[ "$script_content" == *'max_attempts=$(get_max_review_attempts'* ]]

    # The while loop condition must use the pre-computed variable
    [[ "$script_content" == *'review_attempts < max_attempts'* ]]
}
