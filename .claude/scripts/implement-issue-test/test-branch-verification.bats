#!/usr/bin/env bats
#
# test-branch-verification.bats
# Tests for verify_on_feature_branch() — ensures the orchestrator is on
# the expected feature branch before fix stages commit changes.
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

    # Create a fake git repo
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
# verify_on_feature_branch() — correct branch
# =============================================================================

@test "verify_on_feature_branch returns 0 when on expected branch" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature/issue-123

    run verify_on_feature_branch "feature/issue-123"
    [ "$status" -eq 0 ]
}

@test "verify_on_feature_branch returns 0 for arbitrary branch names" {
    cd "$TEST_TMP/repo"
    git checkout -q -b hotfix/urgent-fix

    run verify_on_feature_branch "hotfix/urgent-fix"
    [ "$status" -eq 0 ]
}

# =============================================================================
# verify_on_feature_branch() — wrong branch
# =============================================================================

@test "verify_on_feature_branch returns 1 when on wrong branch" {
    cd "$TEST_TMP/repo"
    # Still on main, not on feature/issue-123

    run verify_on_feature_branch "feature/issue-123"
    [ "$status" -eq 1 ]
}

@test "verify_on_feature_branch logs error when on wrong branch" {
    cd "$TEST_TMP/repo"

    run verify_on_feature_branch "feature/issue-123"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Expected branch"* ]]
}

@test "verify_on_feature_branch includes expected and actual branch in error" {
    cd "$TEST_TMP/repo"

    run verify_on_feature_branch "feature/issue-123"
    [ "$status" -eq 1 ]
    [[ "$output" == *"feature/issue-123"* ]]
    [[ "$output" == *"main"* ]]
}

# =============================================================================
# verify_on_feature_branch() — edge cases
# =============================================================================

@test "verify_on_feature_branch fails when no argument provided" {
    cd "$TEST_TMP/repo"

    run verify_on_feature_branch
    [ "$status" -eq 1 ]
    # Should produce an error explaining the expected vs actual branch
    [ -n "$output" ] || fail "Expected error message when no argument provided"
    [[ "$output" == *"Expected branch"* ]] || [[ "$output" == *"branch"* ]]
}

@test "verify_on_feature_branch fails with empty string argument" {
    cd "$TEST_TMP/repo"

    run verify_on_feature_branch ""
    [ "$status" -eq 1 ]
    # Should produce an error explaining the expected vs actual branch
    [ -n "$output" ] || fail "Expected error message for empty branch name"
    [[ "$output" == *"Expected branch"* ]] || [[ "$output" == *"branch"* ]]
}

# =============================================================================
# Integration: verify_on_feature_branch is called before every fix stage
# =============================================================================

# Helper: count invocations of verify_on_feature_branch (excluding the function
# definition itself).  Invocations are indented calls; the definition starts
# at column 0 ("verify_on_feature_branch() {").
_count_invocations() {
    local c
    c=$(grep -c '^ *verify_on_feature_branch .* || true' "$ORCHESTRATOR_SCRIPT" 2>/dev/null) || c=0
    printf '%d' "$c"
}

@test "orchestrator has at least 4 verify_on_feature_branch invocations (one per fix stage)" {
    local count
    count=$(_count_invocations)
    [ "$count" -ge 4 ]
}

@test "orchestrator calls verify_on_feature_branch within 5 lines before fix-review stage" {
    local src="$ORCHESTRATOR_SCRIPT"

    local fix_line
    fix_line=$(grep -n 'run_stage "fix-review' "$src" | head -1 | cut -d: -f1)
    [ -n "$fix_line" ]

    # Look for an invocation within 5 lines before the fix stage
    local found=false
    local min_line=$(( fix_line - 5 ))
    while IFS=: read -r line_num _; do
        if [ "$line_num" -ge "$min_line" ] && [ "$line_num" -lt "$fix_line" ]; then
            found=true
            break
        fi
    done <<< "$(grep -n '^ *verify_on_feature_branch .* || true' "$src")"
    [ "$found" = true ]
}

@test "orchestrator calls verify_on_feature_branch within 5 lines before fix-tests stage" {
    local src="$ORCHESTRATOR_SCRIPT"

    local fix_line
    fix_line=$(grep -n 'run_stage "fix-tests-iter' "$src" | head -1 | cut -d: -f1)
    [ -n "$fix_line" ]

    local found=false
    local min_line=$(( fix_line - 5 ))
    while IFS=: read -r line_num _; do
        if [ "$line_num" -ge "$min_line" ] && [ "$line_num" -lt "$fix_line" ]; then
            found=true
            break
        fi
    done <<< "$(grep -n '^ *verify_on_feature_branch .* || true' "$src")"
    [ "$found" = true ]
}

@test "orchestrator calls verify_on_feature_branch within 5 lines before fix-test-quality stage" {
    local src="$ORCHESTRATOR_SCRIPT"

    local fix_line
    fix_line=$(grep -n 'run_stage "fix-test-quality' "$src" | head -1 | cut -d: -f1)
    [ -n "$fix_line" ]

    local found=false
    local min_line=$(( fix_line - 5 ))
    while IFS=: read -r line_num _; do
        if [ "$line_num" -ge "$min_line" ] && [ "$line_num" -lt "$fix_line" ]; then
            found=true
            break
        fi
    done <<< "$(grep -n '^ *verify_on_feature_branch .* || true' "$src")"
    [ "$found" = true ]
}

@test "orchestrator calls verify_on_feature_branch within 5 lines before fix-pr-review stage" {
    local src="$ORCHESTRATOR_SCRIPT"

    local fix_line
    fix_line=$(grep -n 'run_stage "fix-pr-review' "$src" | head -1 | cut -d: -f1)
    [ -n "$fix_line" ]

    local found=false
    local min_line=$(( fix_line - 5 ))
    while IFS=: read -r line_num _; do
        if [ "$line_num" -ge "$min_line" ] && [ "$line_num" -lt "$fix_line" ]; then
            found=true
            break
        fi
    done <<< "$(grep -n '^ *verify_on_feature_branch .* || true' "$src")"
    [ "$found" = true ]
}
