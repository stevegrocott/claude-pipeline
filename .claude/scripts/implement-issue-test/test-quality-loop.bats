#!/usr/bin/env bats
#
# test-quality-loop.bats
# Tests for the quality loop helper function
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
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

    # Source the orchestrator functions
    source_orchestrator_functions

    # Initialize status
    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# MAX_QUALITY_ITERATIONS CONSTANT
# =============================================================================

@test "MAX_QUALITY_ITERATIONS is defined" {
    [ -n "$MAX_QUALITY_ITERATIONS" ]
    [ "$MAX_QUALITY_ITERATIONS" -eq 5 ]
}

# =============================================================================
# QUALITY ITERATION TRACKING
# =============================================================================

@test "quality loop increments iteration counter" {
    # Mock run_stage to return approved immediately (with summary fields)
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*) echo '{"status":"success","result":"approved","summary":"Code looks good"}' ;;
        esac
    }
    export -f run_stage

    # Mock comment_issue to avoid gh calls
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    local iterations
    iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$iterations" = "1" ]
}

@test "quality loop stage iteration matches counter" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"Simplified"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"Tests passed"}' ;;
            review-*) echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage

    # Mock comment_issue to avoid gh calls
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    local stage_iteration
    stage_iteration=$(jq -r '.stages.quality_loop.iteration' "$STATUS_FILE")
    [ "$stage_iteration" = "1" ]
}

# =============================================================================
# TEST FAILURE HANDLING
# =============================================================================

@test "run_quality_loop function is defined" {
    # Validates the function exists and is properly sourced
    [ "$(type -t run_quality_loop)" = "function" ]
}

# =============================================================================
# REVIEW CHANGES REQUESTED HANDLING
# =============================================================================

@test "quality loop handles review changes requested" {
    # Validate function exists and has expected structure
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check for expected patterns in function
    [[ "$func_def" == *"review_verdict"* ]]
    [[ "$func_def" == *"approved"* ]]
    [[ "$func_def" == *"changes_requested"* ]] || [[ "$func_def" == *"review_comments"* ]]
}

# =============================================================================
# MAX ITERATIONS EXIT
# =============================================================================

@test "quality loop structure handles max iterations" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check that function references MAX_QUALITY_ITERATIONS
    [[ "$func_def" == *"MAX_QUALITY_ITERATIONS"* ]]

    # Check that function sets max_iterations state
    [[ "$func_def" == *"max_iterations_quality"* ]]

    # Check that function exits with code 2
    [[ "$func_def" == *"exit 2"* ]]
}

# =============================================================================
# STAGE PREFIX
# =============================================================================

@test "quality loop uses stage prefix in log names" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check for stage prefix usage
    [[ "$func_def" == *'stage_prefix'* ]]
    [[ "$func_def" == *'simplify-${stage_prefix}'* ]] || [[ "$func_def" == *'simplify-$stage_prefix'* ]]
}

# =============================================================================
# LOOP STRUCTURE
# =============================================================================

@test "quality loop has correct stage sequence" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Quality loop runs: simplify → review (tests are handled by run_test_loop separately)
    local simplify_pos review_pos
    simplify_pos=$(echo "$func_def" | grep -n "simplify" | head -1 | cut -d: -f1)
    review_pos=$(echo "$func_def" | grep -n "review-\${stage_prefix}" | head -1 | cut -d: -f1)

    # Both stages must be present
    [ -n "$simplify_pos" ]
    [ -n "$review_pos" ]

    # Simplify comes before review
    [ "$simplify_pos" -lt "$review_pos" ]
}

# =============================================================================
# RETURN VALUE
# =============================================================================

@test "quality loop returns 0 on approval" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check for return 0 at end
    [[ "$func_def" == *"return 0"* ]]
}

@test "quality loop uses implement-issue-simplify schema" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Check for simplify schema usage
    [[ "$func_def" == *"implement-issue-simplify.json"* ]]
}

@test "quality loop does not call comment_issue for intermediate sub-stages" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # No comment_issue calls must appear anywhere in run_quality_loop.
    # Using "comment_issue" as the anchor ensures any future call with any title is caught.
    [[ "$func_def" != *"comment_issue"* ]]
}

# =============================================================================
# BEHAVIORAL TESTS - RETRY LOGIC
# =============================================================================

@test "quality loop retries when review requests changes then approves" {
    # Use a file to track review calls across subshell boundaries
    local counter_file="$TEST_TMP/retry_review_count"
    echo "0" > "$counter_file"
    export counter_file

    # Mock run_stage: review requests changes on first call, approves on second
    run_stage() {
        local stage_name="$1"

        case "$stage_name" in
            simplify-*)
                echo '{"status":"success","summary":"Simplified code"}'
                ;;
            review-*)
                # Read and increment counter
                local count
                count=$(cat "$counter_file")
                count=$((count + 1))
                echo "$count" > "$counter_file"

                if [[ "$count" -le 1 ]]; then
                    # First review requests changes
                    echo '{"status":"success","result":"changes_requested","comments":"Fix naming conventions","summary":"1 issue found"}'
                else
                    # Second review approves
                    echo '{"status":"success","result":"approved","summary":"All issues resolved"}'
                fi
                ;;
            fix-review-*)
                echo '{"status":"success","summary":"Fixed naming conventions"}'
                ;;
        esac
    }
    export -f run_stage

    # Mock comment_issue to avoid gh calls
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"
    local exit_status=$?

    # Should succeed after retry
    [ "$exit_status" -eq 0 ]

    # Should have gone through at least 2 iterations
    local iterations
    iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$iterations" -ge 2 ]
}

@test "quality loop has exit 2 for max iterations" {
    # MAX_QUALITY_ITERATIONS is readonly, so we test the structure instead
    # of behavioral execution. The function must exit with code 2 when
    # max iterations is reached.
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Verify the function checks iteration count against MAX_QUALITY_ITERATIONS
    [[ "$func_def" == *"MAX_QUALITY_ITERATIONS"* ]]

    # Verify the function sets the max_iterations_quality state
    [[ "$func_def" == *"max_iterations_quality"* ]]

    # Verify the function exits with code 2
    [[ "$func_def" == *"exit 2"* ]]
}

@test "quality loop increments iteration on each retry" {
    # Use a file to track review calls across subshell boundaries
    local counter_file="$TEST_TMP/review_call_count"
    echo "0" > "$counter_file"
    export counter_file

    # Mock run_stage: review requests changes on first call, approves on second
    run_stage() {
        local stage_name="$1"

        case "$stage_name" in
            simplify-*)
                echo '{"status":"success","summary":"Simplified"}'
                ;;
            review-*)
                # Read and increment counter
                local count
                count=$(cat "$counter_file")
                count=$((count + 1))
                echo "$count" > "$counter_file"

                if [[ "$count" -lt 2 ]]; then
                    echo '{"status":"success","result":"changes_requested","comments":"Fix issue","summary":"Changes needed"}'
                else
                    echo '{"status":"success","result":"approved","summary":"Approved"}'
                fi
                ;;
            fix-review-*)
                echo '{"status":"success","summary":"Fixed"}'
                ;;
        esac
    }
    export -f run_stage

    # Mock comment_issue to avoid gh calls
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    # Verify we went through multiple review iterations
    local final_count
    final_count=$(cat "$counter_file")
    [ "$final_count" -ge 2 ]
}

# =============================================================================
# should_run_quality_loop() HELPER FUNCTION
# =============================================================================

@test "should_run_quality_loop function is defined" {
    [ "$(type -t should_run_quality_loop)" = "function" ]
}

@test "should_run_quality_loop returns 1 (skip) for S-size tasks" {
    run should_run_quality_loop "S"
    [ "$status" -eq 1 ]
}

@test "should_run_quality_loop returns 0 (run) for M-size tasks" {
    run should_run_quality_loop "M"
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop returns 0 (run) for L-size tasks" {
    run should_run_quality_loop "L"
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop returns 0 (run) for unknown size (safe default)" {
    run should_run_quality_loop "X"
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop returns 0 (run) when size is empty (safe default)" {
    run should_run_quality_loop ""
    [ "$status" -eq 0 ]
}

@test "quality loop is skipped for S-size tasks in implementation loop" {
    local orchestrator_src
    orchestrator_src=$(cat "$BATS_TEST_DIRNAME/../implement-issue-orchestrator.sh" 2>/dev/null || true)

    # Guard must appear as a conditional wrapping run_quality_loop:
    #   if should_run_quality_loop ...; then
    #       run_quality_loop ...
    # Verify:
    #   1. The if-guard line exists
    #   2. A run_quality_loop call appears on the immediately following non-blank line (within 5 lines)
    local guard_line
    guard_line=$(grep -n "if should_run_quality_loop" <<< "$orchestrator_src" | head -1 | cut -d: -f1)

    [[ -n "$guard_line" ]]

    # The then-body (within 5 lines after guard) must contain a run_quality_loop call
    local then_body
    then_body=$(awk "NR>$guard_line && NR<=$((guard_line+5))" <<< "$orchestrator_src")
    grep -q "run_quality_loop" <<< "$then_body"
}

# =============================================================================
# --quiet FLAG: comment_issue suppression
# =============================================================================

@test "comment_issue is suppressed when QUIET=true" {
    # Track whether the mock gh binary was invoked (it records calls via a file)
    local gh_call_file="$TEST_TMP/gh_issue_comment_calls"
    echo "0" > "$gh_call_file"
    export gh_call_file

    # Replace the mock gh with one that records invocations
    cat > "$TEST_TMP/bin/gh" << GHEOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "issue" && "\${2:-}" == "comment" ]]; then
    count=\$(cat "$gh_call_file")
    count=\$((count + 1))
    echo "\$count" > "$gh_call_file"
fi
GHEOF
    chmod +x "$TEST_TMP/bin/gh"

    # Use the real comment_issue from the orchestrator (already sourced via source_orchestrator_functions)
    QUIET=true
    comment_issue "Test Title" "Test body"

    local final_count
    final_count=$(cat "$gh_call_file")
    [ "$final_count" -eq 0 ]
}

@test "comment_issue is not suppressed when QUIET=false" {
    # Track whether the mock gh binary was invoked
    local gh_call_file="$TEST_TMP/gh_issue_comment_calls_unquiet"
    echo "0" > "$gh_call_file"
    export gh_call_file

    cat > "$TEST_TMP/bin/gh" << GHEOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "issue" && "\${2:-}" == "comment" ]]; then
    count=\$(cat "$gh_call_file")
    count=\$((count + 1))
    echo "\$count" > "$gh_call_file"
fi
GHEOF
    chmod +x "$TEST_TMP/bin/gh"

    # Use the real comment_issue from the orchestrator with QUIET=false
    QUIET=false
    comment_issue "Test Title" "Test body"

    local final_count
    final_count=$(cat "$gh_call_file")
    [ "$final_count" -eq 1 ]
}
