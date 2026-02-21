#!/usr/bin/env bats
#
# test-status-functions.bats
# Tests for status file management functions
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
# INIT_STATUS
# =============================================================================

@test "init_status creates status file with valid JSON" {
    init_status
    [ -f "$STATUS_FILE" ]
    # Verify it's valid JSON, not an empty or corrupt file
    jq -e '.' "$STATUS_FILE" >/dev/null 2>&1 || fail "Status file is not valid JSON"
    # Verify it has the expected top-level structure
    local keys
    keys=$(jq -r 'keys[]' "$STATUS_FILE" | sort | tr '\n' ',')
    [[ "$keys" == *"state,"* ]] || fail "Missing 'state' key in status file"
    [[ "$keys" == *"stages,"* ]] || fail "Missing 'stages' key in status file"
}

@test "init_status sets state to initializing" {
    init_status
    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "initializing" ]
}

@test "init_status sets issue number" {
    init_status
    local issue
    issue=$(jq -r '.issue' "$STATUS_FILE")
    [ "$issue" = "123" ]
}

@test "init_status initializes all stages as pending" {
    init_status
    local parse_issue_status validate_plan_status impl_status quality_status
    local test_loop_status docs_status pr_status pr_review_status complete_status
    parse_issue_status=$(jq -r '.stages.parse_issue.status' "$STATUS_FILE")
    validate_plan_status=$(jq -r '.stages.validate_plan.status' "$STATUS_FILE")
    impl_status=$(jq -r '.stages.implement.status' "$STATUS_FILE")
    quality_status=$(jq -r '.stages.quality_loop.status' "$STATUS_FILE")
    test_loop_status=$(jq -r '.stages.test_loop.status' "$STATUS_FILE")
    docs_status=$(jq -r '.stages.docs.status' "$STATUS_FILE")
    pr_status=$(jq -r '.stages.pr.status' "$STATUS_FILE")
    pr_review_status=$(jq -r '.stages.pr_review.status' "$STATUS_FILE")
    complete_status=$(jq -r '.stages.complete.status' "$STATUS_FILE")

    [ "$parse_issue_status" = "pending" ]
    [ "$validate_plan_status" = "pending" ]
    [ "$impl_status" = "pending" ]
    [ "$quality_status" = "pending" ]
    [ "$test_loop_status" = "pending" ]
    [ "$docs_status" = "pending" ]
    [ "$pr_status" = "pending" ]
    [ "$pr_review_status" = "pending" ]
    [ "$complete_status" = "pending" ]
}

@test "init_status initializes stages with null timestamps" {
    init_status
    local parse_issue_started validate_plan_started parse_issue_completed validate_plan_completed
    parse_issue_started=$(jq -r '.stages.parse_issue.started_at' "$STATUS_FILE")
    validate_plan_started=$(jq -r '.stages.validate_plan.started_at' "$STATUS_FILE")
    parse_issue_completed=$(jq -r '.stages.parse_issue.completed_at' "$STATUS_FILE")
    validate_plan_completed=$(jq -r '.stages.validate_plan.completed_at' "$STATUS_FILE")

    [ "$parse_issue_started" = "null" ]
    [ "$validate_plan_started" = "null" ]
    [ "$parse_issue_completed" = "null" ]
    [ "$validate_plan_completed" = "null" ]
}

@test "init_status sets log_dir" {
    init_status
    local log_dir
    log_dir=$(jq -r '.log_dir' "$STATUS_FILE")
    [ "$log_dir" = "$LOG_BASE" ]
}

@test "init_status initializes empty tasks array" {
    init_status
    local tasks_len
    tasks_len=$(jq '.tasks | length' "$STATUS_FILE")
    [ "$tasks_len" = "0" ]
}

# =============================================================================
# UPDATE_STAGE
# =============================================================================

@test "update_stage changes stage status and updates current_stage" {
    init_status
    update_stage "setup" "in_progress"

    local status
    status=$(jq -r '.stages.setup.status' "$STATUS_FILE")
    [ "$status" = "in_progress" ]

    # Verify current_stage was also updated
    local current
    current=$(jq -r '.current_stage' "$STATUS_FILE")
    [ "$current" = "setup" ]
}

@test "update_stage with extra field" {
    init_status
    update_stage "implement" "in_progress" "task_progress" "2/5"

    local progress
    progress=$(jq -r '.stages.implement.task_progress' "$STATUS_FILE")
    [ "$progress" = "2/5" ]
}

@test "update_stage updates current_stage" {
    init_status
    update_stage "quality_loop" "in_progress"

    local current
    current=$(jq -r '.current_stage' "$STATUS_FILE")
    [ "$current" = "quality_loop" ]
}

@test "update_stage updates last_update timestamp" {
    init_status
    local before
    before=$(jq -r '.last_update' "$STATUS_FILE")

    sleep 1
    update_stage "docs" "completed"

    local after
    after=$(jq -r '.last_update' "$STATUS_FILE")
    [ "$before" != "$after" ]
}

# =============================================================================
# SET_STAGE_STARTED / SET_STAGE_COMPLETED
# =============================================================================

@test "set_stage_started sets status to in_progress" {
    init_status
    set_stage_started "setup"

    local status
    status=$(jq -r '.stages.setup.status' "$STATUS_FILE")
    [ "$status" = "in_progress" ]
}

@test "set_stage_started sets started_at timestamp in ISO format" {
    init_status
    set_stage_started "setup"

    local started_at
    started_at=$(jq -r '.stages.setup.started_at' "$STATUS_FILE")
    [ "$started_at" != "null" ]
    # Verify it looks like a timestamp (starts with a year)
    [[ "$started_at" =~ ^20[0-9]{2}- ]] || fail "started_at should be ISO timestamp, got: $started_at"
}

@test "set_stage_started sets state to running" {
    init_status
    set_stage_started "setup"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "running" ]
}

@test "set_stage_completed sets status to completed" {
    init_status
    set_stage_completed "setup"

    local status
    status=$(jq -r '.stages.setup.status' "$STATUS_FILE")
    [ "$status" = "completed" ]
}

@test "set_stage_completed sets completed_at timestamp in ISO format" {
    init_status
    set_stage_completed "setup"

    local completed_at
    completed_at=$(jq -r '.stages.setup.completed_at' "$STATUS_FILE")
    [ "$completed_at" != "null" ]
    # Verify it looks like a timestamp
    [[ "$completed_at" =~ ^20[0-9]{2}- ]] || fail "completed_at should be ISO timestamp, got: $completed_at"
}

# =============================================================================
# SET_TASKS
# =============================================================================

@test "set_tasks populates tasks array" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test"},{"id":2,"description":"Task 2","agent":"test"}]'
    set_tasks "$tasks"

    local count
    count=$(jq '.tasks | length' "$STATUS_FILE")
    [ "$count" = "2" ]
}

@test "set_tasks updates task_progress" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test"},{"id":2,"description":"Task 2","agent":"test"},{"id":3,"description":"Task 3","agent":"test"}]'
    set_tasks "$tasks"

    local progress
    progress=$(jq -r '.stages.implement.task_progress' "$STATUS_FILE")
    [ "$progress" = "0/3" ]
}

# =============================================================================
# UPDATE_TASK
# =============================================================================

@test "update_task changes task status" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test","status":"pending"}]'
    set_tasks "$tasks"

    update_task 1 "in_progress"

    local status
    status=$(jq -r '.tasks[0].status' "$STATUS_FILE")
    [ "$status" = "in_progress" ]
}

@test "update_task sets review_attempts" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test","status":"pending"}]'
    set_tasks "$tasks"

    update_task 1 "completed" 2

    local attempts
    attempts=$(jq -r '.tasks[0].review_attempts' "$STATUS_FILE")
    [ "$attempts" = "2" ]
}

@test "update_task sets current_task" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test"},{"id":2,"description":"Task 2","agent":"test"}]'
    set_tasks "$tasks"

    update_task 2 "in_progress"

    local current
    current=$(jq -r '.current_task' "$STATUS_FILE")
    [ "$current" = "2" ]
}

# =============================================================================
# SET_FINAL_STATE
# =============================================================================

@test "set_final_state sets state to completed" {
    init_status
    set_final_state "completed"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "completed" ]
}

@test "set_final_state sets state to error" {
    init_status
    set_final_state "error"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "error" ]
}

@test "set_final_state sets state to max_iterations_quality" {
    init_status
    set_final_state "max_iterations_quality"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "max_iterations_quality" ]
}

# =============================================================================
# INCREMENT ITERATION COUNTERS
# =============================================================================

@test "increment_quality_iteration increments counter" {
    init_status
    increment_quality_iteration
    increment_quality_iteration

    local count
    count=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$count" = "2" ]
}

@test "increment_quality_iteration updates stage iteration" {
    init_status
    increment_quality_iteration
    increment_quality_iteration
    increment_quality_iteration

    local iteration
    iteration=$(jq -r '.stages.quality_loop.iteration' "$STATUS_FILE")
    [ "$iteration" = "3" ]
}

@test "increment_pr_review_iteration increments counter" {
    init_status
    increment_pr_review_iteration

    local count
    count=$(jq -r '.pr_review_iterations' "$STATUS_FILE")
    [ "$count" = "1" ]
}

@test "increment_pr_review_iteration updates stage iteration" {
    init_status
    increment_pr_review_iteration
    increment_pr_review_iteration

    local iteration
    iteration=$(jq -r '.stages.pr_review.iteration' "$STATUS_FILE")
    [ "$iteration" = "2" ]
}
