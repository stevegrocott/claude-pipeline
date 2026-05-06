#!/usr/bin/env bats
#
# test-task-summary.bats
# Tests for the compute_task_summary() function
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    export ISSUE_NUMBER=123
    export BASE_BRANCH=main
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    source_orchestrator_functions

    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# HELPERS
# =============================================================================

_set_tasks_json() {
    local tasks_json="$1"
    jq --argjson tasks "$tasks_json" '.tasks = $tasks' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# =============================================================================
# BASIC OUTPUT STRUCTURE
# =============================================================================

@test "compute_task_summary returns valid JSON" {
    run compute_task_summary
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.' >/dev/null 2>&1 || fail "output is not valid JSON: $output"
}

@test "compute_task_summary output has completed object" {
    run compute_task_summary
    [ "$status" -eq 0 ]
    local t
    t=$(echo "$output" | jq -r '.completed | type')
    [ "$t" = "object" ]
}

@test "compute_task_summary output has failed object" {
    run compute_task_summary
    [ "$status" -eq 0 ]
    local t
    t=$(echo "$output" | jq -r '.failed | type')
    [ "$t" = "object" ]
}

@test "compute_task_summary output has sp_completed field" {
    run compute_task_summary
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.sp_completed | numbers' >/dev/null 2>&1 || fail "sp_completed is not a number"
}

@test "compute_task_summary output has sp_total field" {
    run compute_task_summary
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.sp_total | numbers' >/dev/null 2>&1 || fail "sp_total is not a number"
}

# =============================================================================
# EMPTY TASKS (edge case)
# =============================================================================

@test "compute_task_summary with empty tasks returns zero sp_completed" {
    run compute_task_summary
    [ "$status" -eq 0 ]
    local v
    v=$(echo "$output" | jq -r '.sp_completed')
    [ "$v" = "0" ]
}

@test "compute_task_summary with empty tasks returns zero sp_total" {
    run compute_task_summary
    [ "$status" -eq 0 ]
    local v
    v=$(echo "$output" | jq -r '.sp_total')
    [ "$v" = "0" ]
}

# =============================================================================
# SIZE EXTRACTION AND FIBONACCI MAPPING
# =============================================================================

@test "compute_task_summary counts S task as 1 point when completed" {
    _set_tasks_json '[{"id":1,"description":"**(S)** Do something small","status":"completed"}]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local s_count sp_completed
    s_count=$(echo "$output" | jq -r '.completed.S')
    sp_completed=$(echo "$output" | jq -r '.sp_completed')
    [ "$s_count" = "1" ]
    [ "$sp_completed" = "1" ]
}

@test "compute_task_summary counts M task as 3 points when completed" {
    _set_tasks_json '[{"id":1,"description":"**(M)** Do something medium","status":"completed"}]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local m_count sp_completed
    m_count=$(echo "$output" | jq -r '.completed.M')
    sp_completed=$(echo "$output" | jq -r '.sp_completed')
    [ "$m_count" = "1" ]
    [ "$sp_completed" = "3" ]
}

@test "compute_task_summary counts L task as 5 points when completed" {
    _set_tasks_json '[{"id":1,"description":"**(L)** Do something large","status":"completed"}]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local l_count sp_completed
    l_count=$(echo "$output" | jq -r '.completed.L')
    sp_completed=$(echo "$output" | jq -r '.sp_completed')
    [ "$l_count" = "1" ]
    [ "$sp_completed" = "5" ]
}

# =============================================================================
# AC2: DEFAULT TO S=1 FOR TASKS WITHOUT SIZE LABEL
# =============================================================================

@test "compute_task_summary defaults unlabelled completed task to S=1 point" {
    _set_tasks_json '[{"id":1,"description":"No size label here","status":"completed"}]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local s_count sp_completed
    s_count=$(echo "$output" | jq -r '.completed.S')
    sp_completed=$(echo "$output" | jq -r '.sp_completed')
    [ "$s_count" = "1" ]
    [ "$sp_completed" = "1" ]
}

@test "compute_task_summary defaults unlabelled failed task to S=1 point" {
    _set_tasks_json '[{"id":1,"description":"No size label here","status":"failed"}]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local s_count sp_completed sp_total
    s_count=$(echo "$output" | jq -r '.failed.S')
    sp_completed=$(echo "$output" | jq -r '.sp_completed')
    sp_total=$(echo "$output" | jq -r '.sp_total')
    [ "$s_count" = "1" ]
    [ "$sp_completed" = "0" ]
    [ "$sp_total" = "1" ]
}

# =============================================================================
# GROUPING BY STATUS
# =============================================================================

@test "compute_task_summary groups completed tasks separately from failed" {
    _set_tasks_json '[
        {"id":1,"description":"**(S)** Task one","status":"completed"},
        {"id":2,"description":"**(M)** Task two","status":"failed"},
        {"id":3,"description":"**(L)** Task three","status":"completed"}
    ]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local c_s c_l f_m
    c_s=$(echo "$output" | jq -r '.completed.S')
    c_l=$(echo "$output" | jq -r '.completed.L')
    f_m=$(echo "$output" | jq -r '.failed.M')
    [ "$c_s" = "1" ]
    [ "$c_l" = "1" ]
    [ "$f_m" = "1" ]
}

@test "compute_task_summary sp_completed sums only completed task points" {
    _set_tasks_json '[
        {"id":1,"description":"**(S)** Task one","status":"completed"},
        {"id":2,"description":"**(M)** Task two","status":"failed"},
        {"id":3,"description":"**(L)** Task three","status":"completed"}
    ]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local sp_completed
    sp_completed=$(echo "$output" | jq -r '.sp_completed')
    # S(1) + L(5) = 6
    [ "$sp_completed" = "6" ]
}

@test "compute_task_summary sp_total includes all task points regardless of status" {
    _set_tasks_json '[
        {"id":1,"description":"**(S)** Task one","status":"completed"},
        {"id":2,"description":"**(M)** Task two","status":"failed"},
        {"id":3,"description":"**(L)** Task three","status":"completed"},
        {"id":4,"description":"**(S)** Task four","status":"pending"}
    ]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local sp_total
    sp_total=$(echo "$output" | jq -r '.sp_total')
    # S(1) + M(3) + L(5) + S(1) = 10
    [ "$sp_total" = "10" ]
}

@test "compute_task_summary pending tasks not counted in completed or failed" {
    _set_tasks_json '[
        {"id":1,"description":"**(M)** Task one","status":"pending"}
    ]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local c_m f_m sp_completed
    c_m=$(echo "$output" | jq -r '.completed.M')
    f_m=$(echo "$output" | jq -r '.failed.M')
    sp_completed=$(echo "$output" | jq -r '.sp_completed')
    [ "$c_m" = "0" ]
    [ "$f_m" = "0" ]
    [ "$sp_completed" = "0" ]
}

# =============================================================================
# MIXED SIZES IN COMPLETED/FAILED
# =============================================================================

@test "compute_task_summary counts multiple sizes correctly per bucket" {
    _set_tasks_json '[
        {"id":1,"description":"**(S)** Task A","status":"completed"},
        {"id":2,"description":"**(S)** Task B","status":"completed"},
        {"id":3,"description":"**(M)** Task C","status":"completed"},
        {"id":4,"description":"**(L)** Task D","status":"failed"},
        {"id":5,"description":"**(S)** Task E","status":"failed"}
    ]'
    run compute_task_summary
    [ "$status" -eq 0 ]
    local c_s c_m c_l f_s f_l sp_completed sp_total
    c_s=$(echo "$output" | jq -r '.completed.S')
    c_m=$(echo "$output" | jq -r '.completed.M')
    c_l=$(echo "$output" | jq -r '.completed.L')
    f_s=$(echo "$output" | jq -r '.failed.S')
    f_l=$(echo "$output" | jq -r '.failed.L')
    sp_completed=$(echo "$output" | jq -r '.sp_completed')
    sp_total=$(echo "$output" | jq -r '.sp_total')
    [ "$c_s" = "2" ]
    [ "$c_m" = "1" ]
    [ "$c_l" = "0" ]
    [ "$f_s" = "1" ]
    [ "$f_l" = "1" ]
    # sp_completed: S+S+M = 1+1+3 = 5
    [ "$sp_completed" = "5" ]
    # sp_total: S+S+M+L+S = 1+1+3+5+1 = 11
    [ "$sp_total" = "11" ]
}

# =============================================================================
# AC2: write_task_summary_to_status() INTEGRATION
# =============================================================================

@test "write_task_summary_to_status writes task_summary field to status.json" {
    _set_tasks_json '[{"id":1,"description":"**(S)** Do something","status":"completed"}]'
    write_task_summary_to_status
    local t
    t=$(jq -r '.task_summary | type' "$STATUS_FILE")
    [ "$t" = "object" ]
}

@test "write_task_summary_to_status task_summary matches compute_task_summary output" {
    _set_tasks_json '[
        {"id":1,"description":"**(M)** Task one","status":"completed"},
        {"id":2,"description":"**(L)** Task two","status":"failed"}
    ]'
    write_task_summary_to_status
    local ts_sp_completed ts_sp_total expected_sp_completed expected_sp_total
    ts_sp_completed=$(jq -r '.task_summary.sp_completed' "$STATUS_FILE")
    ts_sp_total=$(jq -r '.task_summary.sp_total' "$STATUS_FILE")
    expected_sp_completed=$(compute_task_summary | jq -r '.sp_completed')
    expected_sp_total=$(compute_task_summary | jq -r '.sp_total')
    [ "$ts_sp_completed" = "$expected_sp_completed" ]
    [ "$ts_sp_total" = "$expected_sp_total" ]
}

@test "write_task_summary_to_status is a no-op when STATUS_FILE does not exist" {
    local missing="$TEST_TMP/no-such-file.json"
    STATUS_FILE="$missing"
    run write_task_summary_to_status
    [ "$status" -eq 0 ]
    [ ! -f "$missing" ]
}

@test "write_task_summary_to_status syncs task_summary to LOG_BASE/status.json" {
    _set_tasks_json '[
        {"id":1,"description":"**(S)** Task one","status":"completed"},
        {"id":2,"description":"**(M)** Task two","status":"pending"}
    ]'
    write_task_summary_to_status
    local expected actual
    expected=$(jq -r '.task_summary.sp_completed' "$STATUS_FILE")
    actual=$(jq -r '.task_summary.sp_completed' "$LOG_BASE/status.json")
    [ "$actual" = "$expected" ]
}

@test "write_task_summary_to_status LOG_BASE copy has same sp_total as STATUS_FILE" {
    _set_tasks_json '[
        {"id":1,"description":"**(S)** Task one","status":"completed"},
        {"id":2,"description":"**(L)** Task two","status":"pending"}
    ]'
    write_task_summary_to_status
    local status_sp_total log_sp_total
    status_sp_total=$(jq -r '.task_summary.sp_total' "$STATUS_FILE")
    log_sp_total=$(jq -r '.task_summary.sp_total' "$LOG_BASE/status.json")
    [ "$log_sp_total" = "$status_sp_total" ]
}
