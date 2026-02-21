#!/usr/bin/env bats
#
# test-integration.bats
# Integration tests for the full orchestrator flow
#
# Tests the current pipeline: parse-issue → implement (self-review) →
# quality-loop → test-loop → docs → pr → pr-review → complete
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

    # Fallback: create minimal schemas if setup_test_env didn't copy real ones
    for schema in implement-issue-parse implement-issue-implement implement-issue-test \
                  implement-issue-review implement-issue-fix implement-issue-task-review \
                  implement-issue-pr implement-issue-complete implement-issue-simplify; do
        if [[ ! -f "$SCHEMA_DIR/${schema}.json" ]]; then
            echo '{"type":"object"}' > "$SCHEMA_DIR/${schema}.json"
        fi
    done

    # Source the orchestrator functions
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# FULL WORKFLOW STRUCTURE — CURRENT STAGES
# =============================================================================

@test "orchestrator has all current stages" {
    local main_def
    main_def=$(declare -f main)

    # Current flow stages (no setup/research/evaluate/plan)
    [[ "$main_def" == *'set_stage_started "parse_issue"'* ]]
    [[ "$main_def" == *'set_stage_started "validate_plan"'* ]]
    [[ "$main_def" == *'set_stage_started "implement"'* ]]
    [[ "$main_def" == *'set_stage_started "test_loop"'* ]]
    [[ "$main_def" == *'set_stage_started "docs"'* ]]
    [[ "$main_def" == *'set_stage_started "pr"'* ]]
    [[ "$main_def" == *'set_stage_started "pr_review"'* ]]
    [[ "$main_def" == *'set_stage_started "complete"'* ]]
}

@test "orchestrator does NOT have removed stages" {
    local main_def
    main_def=$(declare -f main)

    # These stages were removed in the current architecture
    [[ "$main_def" != *'set_stage_started "setup"'* ]]
    [[ "$main_def" != *'set_stage_started "research"'* ]]
    [[ "$main_def" != *'set_stage_started "evaluate"'* ]]
    [[ "$main_def" != *'set_stage_started "plan"'* ]]
}

# =============================================================================
# PARSE-ISSUE SCHEMA
# =============================================================================

@test "init_status sets parse_issue as first stage" {
    init_status

    local current_stage
    current_stage=$(jq -r '.current_stage' "$STATUS_FILE")
    [ "$current_stage" = "parse_issue" ]
}

@test "init_status creates all current stage entries" {
    init_status

    local stages=("parse_issue" "validate_plan" "implement" "quality_loop" "test_loop" "docs" "pr" "pr_review" "complete")
    for stage in "${stages[@]}"; do
        local stage_status
        stage_status=$(jq -r ".stages.${stage}.status" "$STATUS_FILE")
        [ "$stage_status" = "pending" ] || fail "Stage $stage should be pending, got: $stage_status"
    done
}

@test "parse_issue stage extracts tasks from issue body" {
    local main_def
    main_def=$(declare -f main)

    # Parse issue reads from GitHub and extracts tasks
    [[ "$main_def" == *"gh issue view"* ]]
    [[ "$main_def" == *"Implementation Tasks"* ]]
    [[ "$main_def" == *"tasks_json"* ]]
}

@test "parse_issue stage saves context files" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"issue-body.md"* ]]
    [[ "$main_def" == *"tasks.json"* ]]
}

@test "parse_issue creates feature branch" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'feature/issue-'* ]]
    [[ "$main_def" == *"set_branch_info"* ]]
}

@test "parse_issue regex matches unchecked task format" {
    local main_def
    main_def=$(declare -f main)

    # Matches: - [ ] `[agent-name]` Task description
    [[ "$main_def" == *'BASH_REMATCH'* ]]
}

# =============================================================================
# IMPLEMENT-TASK SCHEMA
# =============================================================================

@test "orchestrator uses correct schema for implementation" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"implement-issue-implement.json"* ]]
}

@test "implementation stage loops through tasks" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"task_count"* ]]
    [[ "$main_def" == *'for ((i=0;'* ]]
}

@test "implementation tracks completed tasks" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"completed_tasks"* ]]
}

@test "implementation uses self-review prompt" {
    local main_def
    main_def=$(declare -f main)

    # Self-review is embedded in the implementation prompt
    [[ "$main_def" == *"SELF-REVIEW BEFORE COMMITTING"* ]]
}

@test "implementation extracts task size from description" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"extract_task_size"* ]]
}

@test "implementation uses per-task agent" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"task_agent"* ]]
}

@test "implementation comments on issue after task completion" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"comment_issue"* ]]
}

@test "extract_task_size parses S/M/L markers" {
    local size

    size=$(extract_task_size '**(S)** Small task description')
    [ "$size" = "S" ]

    size=$(extract_task_size '**(M)** Medium task description')
    [ "$size" = "M" ]

    size=$(extract_task_size '**(L)** Large task description')
    [ "$size" = "L" ]
}

@test "extract_task_size returns empty for no marker" {
    local size
    size=$(extract_task_size 'Task with no size marker')
    [ -z "$size" ]
}

@test "extract_task_size returns empty for malformed markers" {
    local size

    # Lowercase markers should not match
    size=$(extract_task_size '**(s)** lowercase task')
    [ -z "$size" ]

    # Missing asterisks
    size=$(extract_task_size '(S) bare parens')
    [ -z "$size" ]

    # Extra spaces inside marker
    size=$(extract_task_size '**( S )** spaced')
    [ -z "$size" ]
}

@test "extract_task_size handles empty input" {
    local size
    size=$(extract_task_size '')
    [ -z "$size" ]
}

# =============================================================================
# QUALITY-LOOP FLOW
# =============================================================================

@test "quality loop function exists and accepts required arguments" {
    [ "$(type -t run_quality_loop)" = "function" ]
    local func_def
    func_def=$(declare -f run_quality_loop)
    # Must accept dir, branch, and stage_prefix arguments
    [[ "$func_def" == *'loop_dir'* ]]
    [[ "$func_def" == *'loop_branch'* ]]
    [[ "$func_def" == *'stage_prefix'* ]]
}

@test "quality loop runs simplify-review-fix cycle" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *"simplify"* ]]
    [[ "$func_def" == *"review"* ]]
    [[ "$func_def" == *"fix"* ]]
}

@test "quality loop uses code-reviewer for reviews" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *"code-reviewer"* ]]
}

@test "quality loop respects max iterations" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *"max_iterations"* ]]
    [[ "$func_def" == *"exit 2"* ]]
}

@test "quality loop exits 2 on max iterations exceeded" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *'set_final_state "max_iterations_quality"'* ]]
    [[ "$func_def" == *"exit 2"* ]]
}

@test "quality loop has convergence detection" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *"repeat_ratio"* ]] || [[ "$func_def" == *"convergence"* ]]
}

@test "quality loop tracks review history" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *"review-history"* ]]
}

@test "implementation runs quality loop per task" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"run_quality_loop"* ]]
    [[ "$main_def" == *"should_run_quality_loop"* ]]
}

@test "S-size tasks skip quality loop" {
    # S-size: max_attempts=1, should_run_quality_loop returns 1 (skip)
    run should_run_quality_loop "S"
    [ "$status" -eq 1 ]
}

@test "M-size tasks run quality loop" {
    run should_run_quality_loop "M"
    [ "$status" -eq 0 ]
}

@test "L-size tasks run quality loop" {
    run should_run_quality_loop "L"
    [ "$status" -eq 0 ]
}

@test "get_max_review_attempts returns correct values for S/M/L" {
    [ "$(get_max_review_attempts "S")" -eq 1 ]
    [ "$(get_max_review_attempts "M")" -eq 2 ]
    [ "$(get_max_review_attempts "L")" -eq 3 ]
}

@test "diff-based max iterations scales by diff size" {
    [ "$(get_diff_based_max_iterations 10)" -eq 1 ]
    [ "$(get_diff_based_max_iterations 50)" -eq 2 ]
    [ "$(get_diff_based_max_iterations 200)" -eq 3 ]
    [ "$(get_diff_based_max_iterations 500)" -eq 5 ]
}

# =============================================================================
# TEST-LOOP FLOW
# =============================================================================

@test "test loop function exists and accepts arguments" {
    [ "$(type -t run_test_loop)" = "function" ]
    local func_def
    func_def=$(declare -f run_test_loop)
    # Must accept dir and branch arguments
    [[ "$func_def" == *'loop_dir'* ]]
    [[ "$func_def" == *'loop_branch'* ]]
}

@test "test loop runs after all tasks complete" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"run_test_loop"* ]]
    [[ "$main_def" == *'set_stage_started "test_loop"'* ]]
}

@test "test loop uses implement-issue-test-validate schema" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"implement-issue-test-validate.json"* ]]
}

@test "test loop detects change scope" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"detect_change_scope"* ]] || [[ "$func_def" == *"change_scope"* ]]
}

@test "test loop skips config-only changes" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"config"* ]]
    [[ "$func_def" == *"skipping test loop"* ]] || [[ "$func_def" == *"Skipping test loop"* ]]
}

@test "test loop has convergence detection for repeated failures" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"convergence"* ]]
    [[ "$func_def" == *"failure_sig"* ]] || [[ "$func_def" == *"sig_count"* ]]
}

@test "test loop respects MAX_TEST_ITERATIONS" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"MAX_TEST_ITERATIONS"* ]]
}

@test "test loop exits 2 on max iterations exceeded" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *'set_final_state "max_iterations_test"'* ]]
    [[ "$func_def" == *"exit 2"* ]]
}

@test "test loop validates test quality after tests pass" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"validate"* ]] || [[ "$func_def" == *"Validate"* ]]
    [[ "$func_def" == *"validation_result"* ]]
}

@test "test loop uses single combined test-iter stage not separate test-validate-iter" {
    local func_def
    func_def=$(declare -f run_test_loop)

    # Combined stage name is test-iter-* (single call per iteration)
    [[ "$func_def" == *'test-iter-'* ]]
    # Must NOT have a separate test-validate-iter stage (old two-call pattern)
    [[ "$func_def" != *'test-validate-iter'* ]]
}

@test "test loop reads validation_result from the same stage output as test result" {
    local func_def
    func_def=$(declare -f run_test_loop)

    # Both fields come from the same test_result variable (combined response)
    [[ "$func_def" == *'test_result'* ]]
    [[ "$func_def" == *'.validation_result'* ]]
    # validate_status is derived from test_result, not a second stage call
    [[ "$func_def" == *"validate_status"* ]]
}

@test "test loop smart targeting routes by scope" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"typescript"* ]]
    [[ "$func_def" == *"bash"* ]]
    [[ "$func_def" == *"mixed"* ]]
}

@test "detect_change_scope function exists and is callable" {
    [ "$(type -t detect_change_scope)" = "function" ]
    local func_def
    func_def=$(declare -f detect_change_scope)
    # Must reference git diff for scope detection
    [[ "$func_def" == *"git"* ]]
}

# =============================================================================
# PR CREATION FLOW
# =============================================================================

@test "orchestrator uses correct schema for PR" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"implement-issue-pr.json"* ]]
}

@test "PR stage creates or updates PR" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"gh pr create"* ]] || [[ "$main_def" == *"pr_result"* ]]
}

@test "PR stage stores PR number in status" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"pr_number"* ]]
    [[ "$main_def" == *"stages.pr.pr_number"* ]]
}

@test "PR stage exits 1 on failure" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"pr_status"* ]]
    [[ "$main_def" == *"exit 1"* ]]
}

# =============================================================================
# PR REVIEW LOOP
# =============================================================================

@test "PR review uses code-reviewer agent" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"code-reviewer"* ]]
}

@test "PR review respects MAX_PR_REVIEW_ITERATIONS" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"MAX_PR_REVIEW_ITERATIONS"* ]]
}

@test "PR review skips quality loop — re-review catches remaining issues" {
    local main_def
    main_def=$(declare -f main)

    # Quality loop was intentionally removed from PR review.
    # The re-review iteration itself catches remaining issues.
    [[ "$main_def" != *'run_quality_loop'*'pr-fix'* ]]
}

@test "PR review uses combined spec + code review" {
    local main_def
    main_def=$(declare -f main)

    # Single review prompt covers both spec and code
    [[ "$main_def" == *"Spec Review"* ]]
    [[ "$main_def" == *"Code Review"* ]]
}

@test "PR review pushes after fixes" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"git push origin"* ]]
}

@test "PR review loop uses comment_pr" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"comment_pr"* ]]
}

# =============================================================================
# COMPLETION STAGE
# =============================================================================

@test "completion stage sets final state" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'set_final_state "completed"'* ]]
}

@test "completion stage copies status to log dir" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'cp "$STATUS_FILE" "$LOG_BASE/status.json"'* ]]
}

@test "completion stage exits with 0" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"exit 0"* ]]
}

@test "completion stage comments on PR" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_pr "$pr_number" "Implementation Complete"'* ]]
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "orchestrator exits 1 on parse_issue failure" {
    local main_def
    main_def=$(declare -f main)

    # Verify the specific parse_issue failure paths exit 1 with error state
    [[ "$main_def" == *'set_final_state "error"'*'exit 1'* ]]
    [[ "$main_def" == *"No tasks to implement"*"exit 1"* ]] || \
    [[ "$main_def" == *"No parseable tasks"*"exit 1"* ]] || \
    [[ "$main_def" == *"Implementation Tasks"*"exit 1"* ]]
}

@test "orchestrator exits 2 on max quality iterations" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *'set_final_state "max_iterations_quality"'* ]]
    [[ "$func_def" == *'set_final_state "max_iterations_quality"'*"exit 2"* ]]
}

@test "orchestrator exits 2 on max test iterations" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *'set_final_state "max_iterations_test"'* ]]
    [[ "$func_def" == *'set_final_state "max_iterations_test"'*"exit 2"* ]]
}

@test "orchestrator exits 2 on max PR review iterations" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'set_final_state "max_iterations_pr_review"'* ]]
    [[ "$main_def" == *'set_final_state "max_iterations_pr_review"'*"exit 2"* ]]
}

# =============================================================================
# LOGGING
# =============================================================================

@test "orchestrator creates log directory structure" {
    init_status

    [ -d "$LOG_BASE/stages" ]
    [ -d "$LOG_BASE/context" ]
}

@test "orchestrator writes to orchestrator.log" {
    init_status
    log "Test log entry"

    [ -f "$LOG_FILE" ]
    grep -q "Test log entry" "$LOG_FILE"
}

# =============================================================================
# BEHAVIORAL TESTS — TASK FAILURE HANDLING
# =============================================================================

@test "task failure updates status correctly" {
    init_status

    local tasks='[{"id":1,"title":"Task 1"},{"id":2,"title":"Task 2"}]'
    set_tasks "$tasks"

    update_task 1 "failed" 3

    local task_status
    task_status=$(jq -r '.tasks[0].status' "$STATUS_FILE")
    [ "$task_status" = "failed" ]

    local review_attempts
    review_attempts=$(jq -r '.tasks[0].review_attempts' "$STATUS_FILE")
    [ "$review_attempts" = "3" ]
}

@test "failed task does not block subsequent tasks" {
    init_status

    local tasks='[{"id":1,"title":"Task 1"},{"id":2,"title":"Task 2"}]'
    set_tasks "$tasks"

    update_task 1 "failed" 3
    update_task 2 "completed" 1

    local task1_status task2_status
    task1_status=$(jq -r '.tasks[0].status' "$STATUS_FILE")
    task2_status=$(jq -r '.tasks[1].status' "$STATUS_FILE")

    [ "$task1_status" = "failed" ]
    [ "$task2_status" = "completed" ]
}

@test "max task review attempts triggers failure" {
    init_status

    local tasks='[{"id":1,"title":"Task 1"}]'
    set_tasks "$tasks"

    # L-size: cap is 3
    local max_l
    max_l=$(get_max_review_attempts "L")
    local attempt
    for attempt in $(seq 1 "$max_l"); do
        update_task 1 "in_progress" "$attempt"
    done

    local review_attempts
    review_attempts=$(jq -r '.tasks[0].review_attempts' "$STATUS_FILE")
    [ "$review_attempts" -eq "$max_l" ]

    # S-size: cap is 1; M-size: cap is 2
    [ "$(get_max_review_attempts "S")" -eq 1 ]
    [ "$(get_max_review_attempts "M")" -eq 2 ]
}

# =============================================================================
# BEHAVIORAL TESTS — PR REVIEW MAX ITERATIONS
# =============================================================================

@test "PR review iteration counter increments correctly" {
    init_status

    increment_pr_review_iteration
    increment_pr_review_iteration

    local iterations
    iterations=$(jq -r '.pr_review_iterations' "$STATUS_FILE")
    [ "$iterations" = "2" ]
}

@test "PR review tracks iteration in stage data" {
    init_status

    set_stage_started "pr_review"
    increment_pr_review_iteration
    increment_pr_review_iteration

    local stage_iteration
    stage_iteration=$(jq -r '.stages.pr_review.iteration' "$STATUS_FILE")
    [ "$stage_iteration" = "2" ]
}

@test "PR review max iterations sets correct exit state" {
    init_status

    local i
    for i in $(seq 1 "$MAX_PR_REVIEW_ITERATIONS"); do
        increment_pr_review_iteration
    done

    set_final_state "max_iterations_pr_review"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "max_iterations_pr_review" ]
}

# =============================================================================
# BEHAVIORAL TESTS — END-TO-END MOCK FLOW
# =============================================================================

@test "complete workflow updates all stage statuses" {
    init_status

    # Current stages only (no setup/research/evaluate/plan)
    local stages=("parse_issue" "validate_plan" "implement" "quality_loop" "test_loop" "docs" "pr" "pr_review" "complete")

    for stage in "${stages[@]}"; do
        set_stage_started "$stage"
        set_stage_completed "$stage"
    done

    for stage in "${stages[@]}"; do
        local stage_status
        stage_status=$(jq -r ".stages.${stage}.status" "$STATUS_FILE")
        [ "$stage_status" = "completed" ] || fail "Stage $stage should be completed, got: $stage_status"
    done
}

@test "workflow tracks timing for each stage" {
    init_status

    set_stage_started "parse_issue"
    sleep 0.1
    set_stage_completed "parse_issue"

    local started_at completed_at
    started_at=$(jq -r '.stages.parse_issue.started_at' "$STATUS_FILE")
    completed_at=$(jq -r '.stages.parse_issue.completed_at' "$STATUS_FILE")

    [ -n "$started_at" ] && [ "$started_at" != "null" ]
    [ -n "$completed_at" ] && [ "$completed_at" != "null" ]
}

# =============================================================================
# COMMENT HELPER FUNCTIONS
# =============================================================================

@test "comment_issue function is defined and uses gh" {
    [ "$(type -t comment_issue)" = "function" ]
    local func_def
    func_def=$(declare -f comment_issue)
    [[ "$func_def" == *"gh issue comment"* ]]
}

@test "comment_pr function is defined and uses gh" {
    [ "$(type -t comment_pr)" = "function" ]
    local func_def
    func_def=$(declare -f comment_pr)
    [[ "$func_def" == *"gh pr comment"* ]]
}

@test "comment_issue uses gh issue comment" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *"gh issue comment"* ]]
}

@test "comment_pr uses gh pr comment" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *"gh pr comment"* ]]
}

@test "validate_plan stage comments on issue" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_issue "Implementation Plan Confirmed"'* ]]
}

# =============================================================================
# DOCS STAGE
# =============================================================================

@test "docs stage checks change scope before running" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"should_run_docs_stage"* ]]
}

@test "should_run_docs_stage skips for bash-only changes" {
    run should_run_docs_stage "bash"
    [ "$status" -eq 1 ]
}

@test "should_run_docs_stage skips for config changes" {
    run should_run_docs_stage "config"
    [ "$status" -eq 1 ]
}

@test "should_run_docs_stage runs for typescript changes" {
    run should_run_docs_stage "typescript"
    [ "$status" -eq 0 ]
}

# =============================================================================
# CONFIG-ONLY EARLY EXIT — PIPELINE BYPASS
#
# When detect_change_scope returns "config" (only .md/.json/.yaml/etc changes),
# the orchestrator skips validate_plan, implement, quality_loop, and test_loop
# stages entirely and jumps directly to PR creation.
# =============================================================================

@test "main performs early scope check and sets early_scope variable" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"early_scope"* ]]
    [[ "$main_def" == *"detect_change_scope"* ]]
}

@test "validate_plan stage is bypassed when early_scope is config" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'Skipping validate_plan stage (config-only scope)'* ]]
}

@test "implement stage is bypassed when early_scope is config" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'Skipping implement stage (config-only scope)'* ]]
}

@test "test_loop stage is bypassed when early_scope is config" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'Skipping test_loop stage (config-only scope)'* ]]
}

@test "config-only early exit posts a GitHub comment about skipping to PR" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"Config-only changes detected"* ]] || \
    [[ "$main_def" == *"Config-Only Changes Detected"* ]]
}

@test "config-only early exit has empty-commit guard before PR creation" {
    local main_def
    main_def=$(declare -f main)

    # Ensures branch has at least one commit vs base before gh pr create
    [[ "$main_def" == *"--allow-empty"* ]]
}

# =============================================================================
# TIMEOUT-AS-SUCCESS BUG — is_stage_timeout() in callers
# =============================================================================

@test "is_stage_timeout helper function is defined" {
    [ "$(type -t is_stage_timeout)" = "function" ]
}

@test "test loop checks for stage timeout before inspecting result" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"is_stage_timeout"* ]]
}

@test "PR review loop checks for stage timeout before inspecting result" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"is_stage_timeout"* ]]
}
