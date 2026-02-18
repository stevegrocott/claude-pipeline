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

# =============================================================================
# CONTEXT PASSING — PRIOR ITERATION FINDINGS
# =============================================================================

@test "review prompt includes PRIOR ITERATION FINDINGS when review history exists" {
    # Create a review history file with prior iteration data
    local history_file="$LOG_BASE/context/review-history-test.json"
    cat > "$history_file" << 'HIST_EOF'
[{"iteration":1,"issues":[{"description":"Missing error handling in parser"}],"result":"changes_requested"}]
HIST_EOF

    # Track the review prompt passed to run_stage
    local prompt_capture="$TEST_TMP/review_prompt_capture"
    export prompt_capture

    run_stage() {
        local stage_name="$1"
        local prompt="$2"

        case "$stage_name" in
            simplify-*)
                echo '{"status":"success","summary":"Simplified"}'
                ;;
            review-*)
                # Capture the prompt for assertion
                printf '%s' "$prompt" > "$prompt_capture"
                echo '{"status":"success","result":"approved","summary":"Approved"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    # Force iteration > 1 by having first review request changes, second approve
    # But simpler: set loop_iteration to start > 1 by having the history file
    # and making the function iterate twice
    local counter_file="$TEST_TMP/ctx_review_count"
    echo "0" > "$counter_file"
    export counter_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"

        case "$stage_name" in
            simplify-*)
                echo '{"status":"success","summary":"Simplified"}'
                ;;
            review-*)
                local count
                count=$(cat "$counter_file")
                count=$((count + 1))
                echo "$count" > "$counter_file"

                # Capture prompt on second iteration (when prior context should appear)
                if (( count >= 2 )); then
                    printf '%s' "$prompt" > "$prompt_capture"
                    echo '{"status":"success","result":"approved","summary":"Approved"}'
                else
                    echo '{"status":"success","result":"changes_requested","comments":"Fix error handling","issues":[{"description":"Missing error handling in parser"}],"summary":"1 issue"}'
                fi
                ;;
            fix-review-*)
                echo '{"status":"success","summary":"Fixed"}'
                ;;
        esac
    }
    export -f run_stage

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    # The captured prompt from the second iteration must include PRIOR ITERATION FINDINGS
    [[ -f "$prompt_capture" ]]
    local captured
    captured=$(< "$prompt_capture")
    [[ "$captured" == *"PRIOR ITERATION FINDINGS"* ]]
}

# =============================================================================
# REVIEW HISTORY ACCUMULATION
# =============================================================================

@test "review history file is created with correct JSON structure after first iteration" {
    local history_file="$LOG_BASE/context/review-history-test.json"

    # Ensure no history file exists before the loop
    rm -f "$history_file"

    run_stage() {
        case "$1" in
            simplify-*)
                echo '{"status":"success","summary":"Simplified"}'
                ;;
            review-*)
                echo '{"status":"success","result":"approved","issues":[{"description":"Minor naming issue"}],"summary":"Approved with notes"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    # History file should exist
    [[ -f "$history_file" ]]

    # Should be valid JSON array
    local entry_count
    entry_count=$(jq 'length' "$history_file")
    [ "$entry_count" -eq 1 ]

    # First entry should have iteration=1
    local iter
    iter=$(jq '.[0].iteration' "$history_file")
    [ "$iter" -eq 1 ]

    # Should have issues array
    local issues_count
    issues_count=$(jq '.[0].issues | length' "$history_file")
    [ "$issues_count" -eq 1 ]

    # Should have result field
    local result
    result=$(jq -r '.[0].result' "$history_file")
    [ "$result" = "approved" ]
}

@test "review history accumulates across multiple iterations" {
    local history_file="$LOG_BASE/context/review-history-test.json"
    rm -f "$history_file"

    local counter_file="$TEST_TMP/accum_review_count"
    echo "0" > "$counter_file"
    export counter_file

    run_stage() {
        case "$1" in
            simplify-*)
                echo '{"status":"success","summary":"Simplified"}'
                ;;
            review-*)
                local count
                count=$(cat "$counter_file")
                count=$((count + 1))
                echo "$count" > "$counter_file"

                if (( count < 2 )); then
                    echo '{"status":"success","result":"changes_requested","issues":[{"description":"Issue A"}],"summary":"Fix needed"}'
                else
                    echo '{"status":"success","result":"approved","issues":[{"description":"Issue B"}],"summary":"Approved"}'
                fi
                ;;
            fix-review-*)
                echo '{"status":"success","summary":"Fixed"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    # History file should have 2 entries (one per iteration)
    [[ -f "$history_file" ]]
    local entry_count
    entry_count=$(jq 'length' "$history_file")
    [ "$entry_count" -eq 2 ]

    # First entry: iteration 1
    [ "$(jq '.[0].iteration' "$history_file")" -eq 1 ]

    # Second entry: iteration 2
    [ "$(jq '.[1].iteration' "$history_file")" -eq 2 ]
}

# =============================================================================
# CONVERGENCE DETECTION
# =============================================================================

@test "convergence detection checks repeat ratio above 50%" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Must compare repeat_ratio against 50
    [[ "$func_def" == *"repeat_ratio > 50"* ]]
}

@test "convergence detection sets loop_approved on repeat detection" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # On convergence, the loop must set loop_approved=true and break
    [[ "$func_def" == *"loop_approved=true"* ]]
}

@test "convergence detection logs warning on early exit" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Must log a convergence failure warning
    [[ "$func_def" == *"convergence failure"* ]]
}

@test "convergence detection only runs after iteration 1" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Convergence check is gated on loop_iteration > 1
    [[ "$func_def" == *"loop_iteration > 1"* ]]
}

@test "convergence detection uses review history file" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    # Must reference the review-history file for convergence comparison
    [[ "$func_def" == *"review-history-\${stage_prefix}.json"* ]] || [[ "$func_def" == *'review-history-${stage_prefix}.json'* ]]
}

# =============================================================================
# SIZE-BASED ITERATION CAPS — get_max_quality_iterations
# =============================================================================

@test "get_max_quality_iterations returns 1 for S-size tasks" {
    local result
    result=$(get_max_quality_iterations "**(S)** Fix a typo")
    [ "$result" -eq 1 ]
}

@test "get_max_quality_iterations returns 2 for M-size tasks" {
    local result
    result=$(get_max_quality_iterations "**(M)** Refactor auth module")
    [ "$result" -eq 2 ]
}

@test "get_max_quality_iterations returns 3 for L-size tasks" {
    local result
    result=$(get_max_quality_iterations "**(L)** Implement new feature")
    [ "$result" -eq 3 ]
}

@test "get_max_quality_iterations returns 3 for unknown size" {
    local result
    result=$(get_max_quality_iterations "No size marker here")
    [ "$result" -eq 3 ]
}

# =============================================================================
# extract_task_size
# =============================================================================

@test "extract_task_size extracts S from description" {
    local result
    result=$(extract_task_size "**(S)** Some task description")
    [ "$result" = "S" ]
}

@test "extract_task_size extracts M from description" {
    local result
    result=$(extract_task_size "**(M)** Some task description")
    [ "$result" = "M" ]
}

@test "extract_task_size extracts L from description" {
    local result
    result=$(extract_task_size "**(L)** Some task description")
    [ "$result" = "L" ]
}

@test "extract_task_size returns empty for descriptions without size markers" {
    local result
    result=$(extract_task_size "A task with no size marker")
    [ -z "$result" ]
}
