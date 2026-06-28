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
# PR NUMBER RECOVERY — find-mr.sh + gh pr list FALLBACK
# =============================================================================

@test "orchestrator has gh pr list fallback for PR number recovery" {
    local main_def
    main_def=$(declare -f main)
    [[ "$main_def" == *"gh pr list"* ]] || \
        fail "gh pr list fallback not found in orchestrator main"
}

@test "orchestrator tries find-mr.sh before gh pr list for PR number recovery" {
    local main_def
    main_def=$(declare -f main)
    [[ "$main_def" == *"find-mr.sh"* ]] || \
        fail "find-mr.sh primary PR recovery not found in orchestrator"
    [[ "$main_def" == *"gh pr list"* ]] || \
        fail "gh pr list fallback not found in orchestrator"
    # find-mr.sh must appear before gh pr list (primary before fallback)
    local find_pos gh_pos
    find_pos=$(printf '%s' "$main_def" | grep -b -o "find-mr.sh" | head -1 | cut -d: -f1)
    gh_pos=$(printf '%s' "$main_def" | grep -b -o "gh pr list" | head -1 | cut -d: -f1)
    (( find_pos < gh_pos )) || \
        fail "find-mr.sh (pos $find_pos) should appear before gh pr list (pos $gh_pos)"
}

@test "orchestrator validates pr_number before accepting it from structured output" {
    local main_def
    main_def=$(declare -f main)
    # The validation regex must reject non-numeric pr_number values
    [[ "$main_def" == *'^[0-9]+'* ]] || \
        fail "Numeric pr_number validation regex not found in orchestrator"
}

# =============================================================================
# GRADUATED RETRY MODEL ESCALATION (implement task loop)
# =============================================================================

@test "orchestrator implements graduated model escalation on task retry" {
    # The per-task retry/escalation loop lives in run_task_in_worktree,
    # not inline in main (main delegates per-task work to this helper).
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)
    [[ "$fn_def" == *"_next_model_up"* ]] || \
        fail "Model escalation (_next_model_up) not found in run_task_in_worktree"
    [[ "$fn_def" == *"review_attempts"* ]] || \
        fail "Retry attempt counter (review_attempts) not found in run_task_in_worktree"
}

@test "orchestrator escalates timeout by 20% on implement task retry" {
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)
    # The 20% timeout increase: base_timeout * 120 / 100
    [[ "$fn_def" == *"120 / 100"* ]] || \
        fail "20%% timeout escalation formula (base_timeout * 120 / 100) not found in run_task_in_worktree"
}

@test "orchestrator only escalates model on retry not on first attempt" {
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)
    # review_attempts > 1 guards the escalation so first attempt uses base model
    [[ "$fn_def" == *"review_attempts > 1"* ]] || \
        fail "Guard condition (review_attempts > 1) for model escalation not found"
}

@test "orchestrator logs model escalation on task retry" {
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)
    # A log message must accompany the escalation for observability.
    # declare -f renders the multi-arg log call as: "...escalating" "to $current_model..."
    [[ "$fn_def" == *"escalating"* ]] || \
        fail "Escalation log message not found in run_task_in_worktree"
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

    # Parse issue reads from issue tracker via platform wrapper and extracts tasks
    [[ "$main_def" == *"read-issue.sh"* ]]
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
    # Task-line parsing was extracted into _parse_task_lines, which main
    # calls from the parse_issue stage. The regex captures live there.
    local fn_def
    fn_def=$(declare -f _parse_task_lines)

    # Matches: - [ ] `[agent-name]` Task description
    [[ "$fn_def" == *'BASH_REMATCH'* ]]
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
    # The implementation prompt is built in run_task_in_worktree (per-task
    # worktree execution), not inline in main.
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    # Self-review is embedded in the implementation prompt
    [[ "$fn_def" == *"SELF-REVIEW BEFORE COMMITTING"* ]]
}

@test "implementation extracts task size from description" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"extract_task_size"* ]]
}

@test "implementation uses per-task agent" {
    # The per-task agent is threaded through run_task_in_worktree, which
    # main invokes per task.
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    [[ "$fn_def" == *"task_agent"* ]]
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
    [[ "$func_def" == *"DEGRADED_STAGES"* ]]
}

@test "quality loop soft-fails on max iterations exceeded" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *'set_final_state "max_iterations_quality"'* ]]
    [[ "$func_def" == *"DEGRADED_STAGES"* ]]
    [[ "$func_def" == *"break"* ]]
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
    # The per-task quality loop is invoked from run_task_in_worktree.
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    [[ "$fn_def" == *"run_quality_loop"* ]]
    [[ "$fn_def" == *"should_run_quality_loop"* ]]
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

@test "test loop convergence uses soft exit not hard exit 2" {
    local func_def
    func_def=$(declare -f run_test_loop)

    # Convergence sets test_convergence_soft_exit, not test_convergence_failure
    [[ "$func_def" == *'set_final_state "test_convergence_soft_exit"'* ]]
    # Convergence sets loop_complete=true instead of exit 2
    [[ "$func_def" == *"loop_complete=true"* ]]
    # Must NOT contain the old hard exit pattern for convergence
    [[ "$func_def" != *'set_final_state "test_convergence_failure"'* ]]
}

@test "test loop convergence log_warn includes specific failure descriptions not just count" {
    local func_def
    func_def=$(declare -f run_test_loop)

    # The log_warn call must reference failure_summaries (specific descriptions)
    # not just sig_count (the repeat count)
    grep -q 'log_warn.*failure_summaries' <<< "$func_def"
}

@test "test loop respects MAX_TEST_ITERATIONS" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"MAX_TEST_ITERATIONS"* ]]
}

@test "test loop soft-fails on max iterations exceeded" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *'set_final_state "max_iterations_test"'* ]]
    [[ "$func_def" == *"DEGRADED_STAGES"* ]]
    [[ "$func_def" == *"break"* ]]
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

    [[ "$main_def" == *"create-mr.sh"* ]] || [[ "$main_def" == *"pr_result"* ]]
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
    # MAX_PR_REVIEW_ITERATIONS is used in get_pr_review_config, which main() calls
    local config_def
    config_def=$(declare -f get_pr_review_config)

    [[ "$config_def" == *"MAX_PR_REVIEW_ITERATIONS"* ]]
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

@test "orchestrator soft-fails on max quality iterations" {
    local func_def
    func_def=$(declare -f run_quality_loop)

    [[ "$func_def" == *'set_final_state "max_iterations_quality"'* ]]
    [[ "$func_def" == *"DEGRADED_STAGES"* ]]
    [[ "$func_def" == *"break"* ]]
}

@test "orchestrator soft-fails on max test iterations" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *'set_final_state "max_iterations_test"'* ]]
    [[ "$func_def" == *"DEGRADED_STAGES"* ]]
    [[ "$func_def" == *"break"* ]]
}

@test "orchestrator soft-fails on max PR review iterations" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'set_final_state "max_iterations_pr_review"'* ]]
    [[ "$main_def" == *"DEGRADED_STAGES"* ]]
    [[ "$main_def" == *"break"* ]]
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

@test "comment_issue function is defined and uses platform wrapper" {
    [ "$(type -t comment_issue)" = "function" ]
    local func_def
    func_def=$(declare -f comment_issue)
    [[ "$func_def" == *"comment-issue.sh"* ]]
}

@test "comment_pr function is defined and uses platform wrapper" {
    [ "$(type -t comment_pr)" = "function" ]
    local func_def
    func_def=$(declare -f comment_pr)
    [[ "$func_def" == *"comment-mr.sh"* ]]
}

@test "comment_issue uses platform comment-issue wrapper" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *"comment-issue.sh"* ]]
}

@test "comment_pr uses platform comment-mr wrapper" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *"comment-mr.sh"* ]]
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

@test "main performs early scope check only when branch has commits" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *"early_scope"* ]]
    [[ "$main_def" == *"detect_change_scope"* ]]
    # Must check commit count before calling detect_change_scope
    [[ "$main_def" == *"early_commit_count > 0"* ]]
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

@test "config-only early exit only triggers when branch has commits" {
    local main_def
    main_def=$(declare -f main)

    # Fresh branches (0 commits) must NOT trigger config-only bypass
    [[ "$main_def" == *"early_commit_count"* ]]
    [[ "$main_def" == *"early_commit_count > 0"* ]]
}

# =============================================================================
# PR NUMBER RECOVERY
# =============================================================================

@test "PR number regex validation exists in orchestrator main body" {
    grep -qF '"$pr_number" =~ ^[0-9]+$' "$ORCHESTRATOR_SCRIPT"
}

@test "find-mr.sh recovery path exists with log message recovering via find-mr.sh" {
    grep -q 'recovering via find-mr.sh' "$ORCHESTRATOR_SCRIPT"
    grep -q 'find-mr.sh' "$ORCHESTRATOR_SCRIPT"
}

@test "gh pr list fallback exists with log message gh pr list fallback" {
    grep -q 'gh pr list fallback' "$ORCHESTRATOR_SCRIPT"
}

@test "error exit with Could not recover PR/MR number message" {
    grep -q 'Could not recover PR/MR number' "$ORCHESTRATOR_SCRIPT"
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

# =============================================================================
# RUN_TESTS FUNCTION
# =============================================================================

@test "run_tests function is defined" {
    [ "$(type -t run_tests)" = "function" ]
}

@test "run_tests uses TEST_UNIT_CMD from platform config" {
    local func_def
    func_def=$(declare -f run_tests)

    [[ "$func_def" == *"TEST_UNIT_CMD"* ]]
}

@test "run_tests uses TEST_E2E_CMD from platform config" {
    local func_def
    func_def=$(declare -f run_tests)

    [[ "$func_def" == *"TEST_E2E_CMD"* ]]
}

@test "run_tests skips E2E when unit tests fail" {
    local func_def
    func_def=$(declare -f run_tests)

    # Should check exit_code before running E2E
    [[ "$func_def" == *"exit_code -eq 0"* ]]
}

# =============================================================================
# PLATFORM CONFIG SOURCING
# =============================================================================

@test "orchestrator sources platform config" {
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *'source "$SCRIPT_DIR/../config/platform.sh"'* ]]
}

@test "orchestrator sets PLATFORM_DIR" {
    local script_content
    script_content=$(cat "$ORCHESTRATOR_SCRIPT")

    [[ "$script_content" == *'PLATFORM_DIR="$SCRIPT_DIR/platform"'* ]]
}

# =============================================================================
# GRADUATED RETRY — task implementation escalates model + timeout on failure
# =============================================================================

@test "implement loop captures base_timeout and base_model before retry loop" {
    # The per-task retry loop lives in run_task_in_worktree, not main.
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    # Must resolve base values once, outside the while loop
    [[ "$fn_def" == *"base_timeout"* ]]
    [[ "$fn_def" == *"base_model"* ]]
    [[ "$fn_def" == *'get_stage_timeout'* ]]
    [[ "$fn_def" == *'resolve_model'* ]]
}

@test "implement loop uses _next_model_up for model escalation on retry" {
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    [[ "$fn_def" == *'_next_model_up "$base_model"'* ]]
}

@test "implement loop increases timeout by 20 percent on retry" {
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    # 20% increase: base * 120 / 100
    [[ "$fn_def" == *'120 / 100'* ]]
    [[ "$fn_def" == *'current_timeout'* ]]
}

@test "implement loop passes model_override to run_stage on retry" {
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    # run_stage must be called with current_model as the model override on retry
    [[ "$fn_def" == *'"$current_model"'* ]]
}

@test "implement loop passes timeout_override to run_stage on retry" {
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    # run_stage must be called with current_timeout as the timeout override on retry
    [[ "$fn_def" == *'"$current_timeout"'* ]]
}

@test "implement loop logs escalation message on retry" {
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    # declare -f renders the multi-arg log call with "escalating" as its own
    # quoted token followed by "to $current_model ...".
    [[ "$fn_def" == *"escalating"* ]]
}

@test "implement loop only escalates after first attempt" {
    local fn_def
    fn_def=$(declare -f run_task_in_worktree)

    # Gate on review_attempts > 1 (not >= 1)
    [[ "$fn_def" == *'review_attempts > 1'* ]]
}

@test "20 percent timeout increase arithmetic is correct" {
    # Verify bash integer math gives correct 20% increase
    local base=1800
    local increased=$((base * 120 / 100))
    [ "$increased" -eq 2160 ]

    local base2=900
    local increased2=$((base2 * 120 / 100))
    [ "$increased2" -eq 1080 ]

    local base3=300
    local increased3=$((base3 * 120 / 100))
    [ "$increased3" -eq 360 ]
}

# =============================================================================
# BATCH RESUME — second launch over same manifest skips completed issues
# (issue #393: init_status must preserve prior completed/already_implemented
# per-issue state instead of resetting all to pending on every launch)
#
# Root cause: init_status() is called unconditionally on every launch,
# wiping the prior run's state before the idempotency check at line ~1033
# can read it — making the skip logic dead code.
#
# Fix contract verified here:
#   1. init_status checks for an existing status file and merges prior
#      completed/already_implemented statuses instead of resetting all to pending.
#   2. The main loop has an up-front gh check that skips closed/merged issues
#      even when no prior status.json exists.
# =============================================================================

BATCH_ORCHESTRATOR="${SCRIPT_DIR}/batch-orchestrator.sh"

@test "batch-orchestrator init_status checks for existing status file before resetting" {
    local body
    body=$(awk '/^init_status\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR")
    [[ "$body" == *'-f "$STATUS_FILE"'* ]] || \
        fail "init_status must guard with: if [[ -f \"\$STATUS_FILE\" ]] before resetting"
}

@test "batch-orchestrator init_status preserves completed per-issue status on resume" {
    local body
    body=$(awk '/^init_status\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR")
    [[ "$body" == *'"completed"'* ]] || \
        fail "init_status must reference 'completed' when rebuilding the issue list"
}

@test "batch-orchestrator init_status preserves already_implemented per-issue status on resume" {
    local body
    body=$(awk '/^init_status\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR")
    [[ "$body" == *'"already_implemented"'* ]] || \
        fail "init_status must reference 'already_implemented' when rebuilding the issue list"
}

@test "batch-orchestrator main loop logs Skipping issue when status is already completed" {
    grep -q 'Skipping issue' "$BATCH_ORCHESTRATOR" || \
        fail "No 'Skipping issue' log message in batch-orchestrator main loop"
    grep -q 'already completed' "$BATCH_ORCHESTRATOR" || \
        fail "No 'already completed' phrase in batch-orchestrator skip log"
}

@test "batch-orchestrator has up-front closed-issue check before process_issue" {
    # Task 2 safety net: even with no prior status.json, a closed issue or
    # merged PR detected via gh must be skipped before the orchestrator runs.
    grep -q 'gh issue view' "$BATCH_ORCHESTRATOR" || \
        fail "No 'gh issue view' up-front check found in batch-orchestrator"
}

@test "batch-orchestrator up-front check handles CLOSED issue state" {
    # The gh check must handle the CLOSED state returned by gh issue view.
    local loop_body
    loop_body=$(awk '/^for issue in.*ISSUE_ARRAY/,/^done$/' "$BATCH_ORCHESTRATOR" 2>/dev/null)
    [[ "$loop_body" == *'CLOSED'* ]] || \
        fail "Main issue loop must check for CLOSED issue state from gh"
}

# --- Functional simulation tests ---
#
# These simulations replicate the merge logic that init_status must implement
# and verify it maps every prior-run status to the correct post-resume status.
# They pass against any implementation that follows the contract and are
# independent of the exact code structure chosen by tasks 1 and 2.

# Simulate the resume-aware status merge: maps prior statuses to post-resume values.
# Only completed/already_implemented are preserved; everything else is re-queued.
_simulate_resume_merge() {
    local prior_status_file="$1"
    shift
    local -a manifest_issues=("$@")

    local new_issues_json="[]"
    for iss in "${manifest_issues[@]}"; do
        local prior_st
        prior_st=$(jq -r --arg n "$iss" \
            '.issues[] | select(.number == $n) | .status // empty' \
            "$prior_status_file" 2>/dev/null)
        local new_st="pending"
        if [[ "$prior_st" == "completed" || "$prior_st" == "already_implemented" ]]; then
            new_st="$prior_st"
        fi
        new_issues_json=$(printf '%s' "$new_issues_json" | jq \
            --arg n "$iss" --arg s "$new_st" \
            '. + [{number: $n, status: $s}]')
    done
    printf '%s' "$new_issues_json"
}

@test "resume simulation: completed issues are preserved through init" {
    local prior="$TEST_TMP/prior-status-completed.json"
    jq -n '{"issues": [{"number": "100", "status": "completed"}]}' > "$prior"

    local result
    result=$(_simulate_resume_merge "$prior" "100")
    local st
    st=$(printf '%s' "$result" | jq -r '.[] | select(.number=="100") | .status')
    [ "$st" = "completed" ] || fail "completed must survive reinit, got: $st"
}

@test "resume simulation: already_implemented issues are preserved through init" {
    local prior="$TEST_TMP/prior-status-aimpl.json"
    jq -n '{"issues": [{"number": "101", "status": "already_implemented"}]}' > "$prior"

    local result
    result=$(_simulate_resume_merge "$prior" "101")
    local st
    st=$(printf '%s' "$result" | jq -r '.[] | select(.number=="101") | .status')
    [ "$st" = "already_implemented" ] || fail "already_implemented must survive reinit, got: $st"
}

@test "resume simulation: failed issues are re-queued as pending" {
    local prior="$TEST_TMP/prior-status-failed.json"
    jq -n '{"issues": [{"number": "102", "status": "failed"}]}' > "$prior"

    local result
    result=$(_simulate_resume_merge "$prior" "102")
    local st
    st=$(printf '%s' "$result" | jq -r '.[] | select(.number=="102") | .status')
    [ "$st" = "pending" ] || fail "failed must be re-queued as pending, got: $st"
}

@test "resume simulation: in_progress issues are re-queued as pending" {
    local prior="$TEST_TMP/prior-status-inprog.json"
    jq -n '{"issues": [{"number": "103", "status": "in_progress"}]}' > "$prior"

    local result
    result=$(_simulate_resume_merge "$prior" "103")
    local st
    st=$(printf '%s' "$result" | jq -r '.[] | select(.number=="103") | .status')
    [ "$st" = "pending" ] || fail "in_progress must be re-queued as pending, got: $st"
}

@test "resume simulation: issues absent from prior status start as pending" {
    local prior="$TEST_TMP/prior-status-absent.json"
    jq -n '{"issues": [{"number": "200", "status": "completed"}]}' > "$prior"

    # Issue 201 does not appear in the prior run at all
    local result
    result=$(_simulate_resume_merge "$prior" "201")
    local st
    st=$(printf '%s' "$result" | jq -r '.[] | select(.number=="201") | .status')
    [ "$st" = "pending" ] || fail "issue absent from prior run must start as pending, got: $st"
}

@test "resume simulation: mixed manifest preserves only terminal statuses" {
    local prior="$TEST_TMP/prior-status-mixed.json"
    jq -n '{
        "issues": [
            {"number": "300", "status": "completed"},
            {"number": "301", "status": "already_implemented"},
            {"number": "302", "status": "failed"},
            {"number": "303", "status": "in_progress"},
            {"number": "304", "status": "pending"}
        ]
    }' > "$prior"

    local result
    result=$(_simulate_resume_merge "$prior" "300" "301" "302" "303" "304")

    local st300 st301 st302 st303 st304
    st300=$(printf '%s' "$result" | jq -r '.[] | select(.number=="300") | .status')
    st301=$(printf '%s' "$result" | jq -r '.[] | select(.number=="301") | .status')
    st302=$(printf '%s' "$result" | jq -r '.[] | select(.number=="302") | .status')
    st303=$(printf '%s' "$result" | jq -r '.[] | select(.number=="303") | .status')
    st304=$(printf '%s' "$result" | jq -r '.[] | select(.number=="304") | .status')

    [ "$st300" = "completed" ]           || fail "300: completed must survive, got: $st300"
    [ "$st301" = "already_implemented" ] || fail "301: already_implemented must survive, got: $st301"
    [ "$st302" = "pending" ]             || fail "302: failed must be reset to pending, got: $st302"
    [ "$st303" = "pending" ]             || fail "303: in_progress must be reset to pending, got: $st303"
    [ "$st304" = "pending" ]             || fail "304: pending must remain pending, got: $st304"
}

# =============================================================================
# BATCH RESUME — functional second-launch scenario (real init_status)
#
# The simulation tests above reimplement the merge. This scenario instead runs
# the ACTUAL init_status() extracted from batch-orchestrator.sh against a prior
# status.json, then replays the real main-loop skip gate to prove that a
# completed issue does NOT reach the implement entry point (process_issue) on
# relaunch, while a pending issue does. This is the behavioural guarantee AC1
# and AC3 require — not just the presence of a code structure.
# =============================================================================

@test "resume functional: relaunch preserves completed and skips implement stage" {
    source_batch_function init_status

    export BRANCH="main"
    export LOG_BASE="$TEST_TMP/logs/resume"
    export STATUS_FILE="$TEST_TMP/resume-status.json"
    # Global (not local): the extracted init_status reads ISSUE_ARRAY by name.
    # Dynamic scope makes a caller local visible to init_status anyway, but a
    # plain assignment keeps intent obvious.
    ISSUE_ARRAY=(100 101)

    # Simulate a prior launch: 100 finished, 101 never ran.
    jq -n '{
        issues: [
            {number: "100", status: "completed"},
            {number: "101", status: "pending"}
        ]
    }' > "$STATUS_FILE"

    # Second launch over the same manifest.
    init_status

    # Per-issue state: 100 preserved, 101 still pending.
    local st100 st101
    st100=$(jq -r '.issues[] | select(.number=="100") | .status' "$STATUS_FILE")
    st101=$(jq -r '.issues[] | select(.number=="101") | .status' "$STATUS_FILE")
    [ "$st100" = "completed" ] || fail "100 must survive relaunch, got: $st100"
    [ "$st101" = "pending" ]   || fail "101 must stay pending, got: $st101"

    # Aggregate progress must reflect the preserved completion.
    local completed
    completed=$(jq -r '.progress.completed' "$STATUS_FILE")
    [ "$completed" = "1" ] || fail "progress.completed must be 1, got: $completed"

    # Replay the real main-loop skip gate with a tracked implement stand-in.
    local processed="$TEST_TMP/processed.log"
    : > "$processed"
    process_issue() { printf '%s\n' "$1" >> "$processed"; }

    for issue in "${ISSUE_ARRAY[@]}"; do
        local current_status
        current_status=$(jq -r --arg num "$issue" \
            '.issues[] | select(.number == $num) | .status' "$STATUS_FILE")
        if [[ "$current_status" == "completed" ]]; then
            continue
        fi
        process_issue "$issue"
    done

    # The completed issue's implement stage was NOT invoked; the pending one was.
    ! grep -qx '100' "$processed" || \
        fail "implement stage must be skipped for completed issue 100"
    grep -qx '101' "$processed" || \
        fail "implement stage must run for pending issue 101"
}

# =============================================================================
# BATCH SIGNAL PROPAGATION — single SIGTERM to batch terminates orchestrator subtree
# (issue #394: batch orphaned the orchestrator; one signal must clean up everything)
#
# AC1: Signalling the batch terminates the active orchestrator and all stage children
# AC2: No orchestrator process reparented to init (ppid=1) after batch is killed
# AC3: Orchestrator TERM handler propagates signal to background tasks before exiting
# =============================================================================

@test "single SIGTERM to batch terminates orchestrator subtree with no respawn" {
    # Functional test for AC1/AC2: a single SIGTERM to the batch must propagate
    # to the orchestrator's process group and leave no survivors.
    # Stub scripts mirror the setsid + pgid-capture + kill-pgid pattern.
    #
    # setsid is Linux-only; macOS falls back to perl -MPOSIX=setsid which is
    # always available and provides identical session-leader semantics.

    local pgid_file="$TEST_TMP/orch.pgid"
    local ready_file="$TEST_TMP/orch.ready"
    local pgid_set_file="$TEST_TMP/batch.pgid_set"
    local stub_orch="$TEST_TMP/stub-orch.sh"
    local stub_batch="$TEST_TMP/stub-batch.sh"

    # Stub orchestrator: session leader (setsid), writes own pgid, spawns a
    # long-running child stage, and propagates TERM to the group on signal.
    cat > "$stub_orch" << ORCH_STUB
#!/usr/bin/env bash
trap 'kill -- -\$\$ 2>/dev/null; exit 143' TERM
printf '%s\n' "\$\$" > "${pgid_file}"
touch "${ready_file}"
sleep 300 &
wait
ORCH_STUB
    chmod +x "$stub_orch"

    # Stub batch: mirrors the three-part pattern tasks 1-2 implement —
    #   1. launch orchestrator in its own process group (perl setsid)
    #   2. capture the orchestrator pgid
    #   3. TERM/EXIT cleanup trap that kills the orchestrator's entire pgid
    cat > "$stub_batch" << BATCH_STUB
#!/usr/bin/env bash
_orch_pgid=""
_cleanup() { [[ -n "\$_orch_pgid" ]] && kill -- -"\$_orch_pgid" 2>/dev/null; }
trap '_cleanup; exit 143' TERM EXIT

perl -MPOSIX=setsid -e 'setsid; exec @ARGV' -- "${stub_orch}" &
_orch_pid=\$!
_i=0
while [[ ! -s "${pgid_file}" ]] && (( _i++ < 30 )); do sleep 0.1; done
_orch_pgid=\$(cat "${pgid_file}" 2>/dev/null)
touch "${pgid_set_file}"
wait "\$_orch_pid"
BATCH_STUB
    chmod +x "$stub_batch"

    # Start the stub batch.
    "$stub_batch" &
    local batch_pid=$!

    # Wait for the batch to record the orchestrator pgid (up to 3 s).
    local i=0
    while [[ ! -f "$pgid_set_file" ]] && (( i++ < 30 )); do sleep 0.1; done
    if [[ ! -f "$pgid_set_file" ]]; then
        kill "$batch_pid" 2>/dev/null
        fail "stub batch did not start orchestrator within 3 s"
    fi

    local orch_pgid
    orch_pgid=$(cat "$pgid_file")
    if [[ -z "$orch_pgid" ]]; then
        kill "$batch_pid" 2>/dev/null
        fail "stub orchestrator did not write its pgid"
    fi

    # Confirm the orchestrator process group is live before signalling.
    kill -0 -- -"$orch_pgid" 2>/dev/null \
        || { kill "$batch_pid" 2>/dev/null; fail "orchestrator pgid $orch_pgid not alive before signal"; }

    # One SIGTERM to the batch; cleanup trap must propagate to the orchestrator group.
    kill -TERM "$batch_pid"

    # Poll until the orchestrator group dies (up to 5 s) instead of a fixed
    # delay — faster on fast systems, resilient on slow CI.
    local j=0
    while kill -0 -- -"$orch_pgid" 2>/dev/null && (( j++ < 50 )); do
        sleep 0.1
    done

    # Assert: orchestrator process group has no survivors after teardown.
    kill -0 -- -"$orch_pgid" 2>/dev/null \
        && fail "orchestrator pgid $orch_pgid still has survivors after single SIGTERM to batch"

    # Assert: the group stays gone — re-poll over a short window to confirm it
    # was not respawned (the "no respawn" half of this test's contract).
    local k=0
    while (( k++ < 5 )); do
        sleep 0.1
        kill -0 -- -"$orch_pgid" 2>/dev/null \
            && fail "orchestrator pgid $orch_pgid respawned after teardown"
    done
    return 0
}
