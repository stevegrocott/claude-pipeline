#!/usr/bin/env bats
#
# test-export-metrics.bats
# Tests for the export_metrics() function
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

    # Initialise a baseline status file with timestamps in two stages
    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# HELPERS
# =============================================================================

# Write a minimal valid status file with known timestamps
_write_status_with_timestamps() {
    jq --arg branch "feature/issue-123" \
       --arg state "completed" \
       '.branch = $branch |
        .state  = $state  |
        .stages.parse_issue.started_at   = "2024-01-01T10:00:00Z" |
        .stages.parse_issue.completed_at = "2024-01-01T10:00:30Z" |
        .stages.parse_issue.status       = "completed"             |
        .stages.parse_issue.model        = "claude-haiku-4-5"      |
        .stages.validate_plan.started_at   = "2024-01-01T10:00:31Z" |
        .stages.validate_plan.completed_at = "2024-01-01T10:01:01Z" |
        .stages.validate_plan.status       = "completed"' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# =============================================================================
# FILE CREATION (AC1)
# =============================================================================

@test "export_metrics creates metrics.json in LOG_BASE" {
    _write_status_with_timestamps
    export_metrics
    [ -f "$LOG_BASE/metrics.json" ]
}

@test "export_metrics writes valid JSON" {
    _write_status_with_timestamps
    export_metrics
    jq -e '.' "$LOG_BASE/metrics.json" >/dev/null 2>&1 || fail "metrics.json is not valid JSON"
}

@test "export_metrics succeeds when STATUS_FILE is missing (no crash)" {
    rm -f "$STATUS_FILE"
    run export_metrics
    [ "$status" -eq 0 ]
}

@test "export_metrics does not create metrics.json when STATUS_FILE is missing" {
    rm -f "$STATUS_FILE"
    export_metrics
    [ ! -f "$LOG_BASE/metrics.json" ]
}

# =============================================================================
# SCHEMA TOP-LEVEL FIELDS (AC2, AC4)
# =============================================================================

@test "metrics.json contains schema_version field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.schema_version' "$LOG_BASE/metrics.json")
    [ "$v" = "1" ]
}

@test "metrics.json contains issue field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.issue' "$LOG_BASE/metrics.json")
    [ "$v" = "123" ]
}

@test "metrics.json contains base_branch field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.base_branch' "$LOG_BASE/metrics.json")
    [ "$v" = "main" ]
}

@test "metrics.json contains branch field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.branch' "$LOG_BASE/metrics.json")
    [ "$v" = "feature/issue-123" ]
}

@test "metrics.json contains state field" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.state' "$LOG_BASE/metrics.json")
    [ "$v" = "completed" ]
}

@test "metrics.json contains stages object" {
    _write_status_with_timestamps
    export_metrics
    local t
    t=$(jq -r '.stages | type' "$LOG_BASE/metrics.json")
    [ "$t" = "object" ]
}

@test "metrics.json contains escalations array" {
    _write_status_with_timestamps
    export_metrics
    local t
    t=$(jq -r '.escalations | type' "$LOG_BASE/metrics.json")
    [ "$t" = "array" ]
}

@test "metrics.json contains iteration_summary object" {
    _write_status_with_timestamps
    export_metrics
    local t
    t=$(jq -r '.iteration_summary | type' "$LOG_BASE/metrics.json")
    [ "$t" = "object" ]
}

# =============================================================================
# DURATION CALCULATION (AC2)
# =============================================================================

@test "metrics.json calculates per-stage duration_seconds" {
    _write_status_with_timestamps
    export_metrics
    local dur
    dur=$(jq -r '.stages.parse_issue.duration_seconds' "$LOG_BASE/metrics.json")
    # 10:00:30 - 10:00:00 = 30 seconds
    [ "$dur" = "30" ]
}

@test "metrics.json duration_seconds is null when timestamps are missing" {
    _write_status_with_timestamps
    # validate_plan has timestamps, but remove them from one stage
    jq '.stages.quality_loop.started_at = null | .stages.quality_loop.completed_at = null' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    export_metrics
    local dur
    dur=$(jq -r '.stages.quality_loop.duration_seconds' "$LOG_BASE/metrics.json")
    [ "$dur" = "null" ]
}

@test "metrics.json calculates total_duration_seconds from earliest to latest stage" {
    _write_status_with_timestamps
    export_metrics
    local total
    total=$(jq -r '.total_duration_seconds' "$LOG_BASE/metrics.json")
    # earliest started: 10:00:00, latest completed: 10:01:01 = 61 seconds
    [ "$total" = "61" ]
}

@test "metrics.json total_duration_seconds is null when no stage timestamps exist" {
    init_status
    export_metrics
    local total
    total=$(jq -r '.total_duration_seconds' "$LOG_BASE/metrics.json")
    [ "$total" = "null" ]
}

# =============================================================================
# MODEL TRACKING (AC2)
# =============================================================================

@test "metrics.json preserves model field per stage" {
    _write_status_with_timestamps
    export_metrics
    local model
    model=$(jq -r '.stages.parse_issue.model' "$LOG_BASE/metrics.json")
    [ "$model" = "claude-haiku-4-5" ]
}

@test "metrics.json model is null for stages without model tracking" {
    _write_status_with_timestamps
    export_metrics
    local model
    model=$(jq -r '.stages.validate_plan.model // "null"' "$LOG_BASE/metrics.json")
    [ "$model" = "null" ]
}

# =============================================================================
# ESCALATION EVENTS (AC2)
# =============================================================================

@test "metrics.json escalations is empty array when no escalations occurred" {
    _write_status_with_timestamps
    export_metrics
    local count
    count=$(jq '.escalations | length' "$LOG_BASE/metrics.json")
    [ "$count" = "0" ]
}

@test "metrics.json escalations contains recorded escalation events" {
    _write_status_with_timestamps
    record_escalation "quality_loop" "claude-haiku-4-5" "claude-sonnet-4-6" "max_turns_exhausted"
    export_metrics

    local count stage from_model to_model reason
    count=$(jq '.escalations | length' "$LOG_BASE/metrics.json")
    stage=$(jq -r '.escalations[0].stage' "$LOG_BASE/metrics.json")
    from_model=$(jq -r '.escalations[0].from_model' "$LOG_BASE/metrics.json")
    to_model=$(jq -r '.escalations[0].to_model' "$LOG_BASE/metrics.json")
    reason=$(jq -r '.escalations[0].reason' "$LOG_BASE/metrics.json")

    [ "$count" = "1" ]
    [ "$stage" = "quality_loop" ]
    [ "$from_model" = "claude-haiku-4-5" ]
    [ "$to_model" = "claude-sonnet-4-6" ]
    [ "$reason" = "max_turns_exhausted" ]
}

@test "metrics.json preserves multiple escalation events" {
    _write_status_with_timestamps
    record_escalation "quality_loop" "claude-haiku-4-5" "claude-sonnet-4-6" "max_turns_exhausted"
    record_escalation "test_loop"    "claude-haiku-4-5" "claude-sonnet-4-6" "max_turns_exhausted"
    export_metrics

    local count
    count=$(jq '.escalations | length' "$LOG_BASE/metrics.json")
    [ "$count" = "2" ]
}

# =============================================================================
# ITERATION SUMMARY (AC3)
# =============================================================================

@test "metrics.json iteration_summary contains quality_iterations" {
    _write_status_with_timestamps
    increment_quality_iteration
    increment_quality_iteration
    export_metrics

    local v
    v=$(jq -r '.iteration_summary.quality_iterations' "$LOG_BASE/metrics.json")
    [ "$v" = "2" ]
}

@test "metrics.json iteration_summary contains test_iterations" {
    _write_status_with_timestamps
    increment_test_iteration
    export_metrics

    local v
    v=$(jq -r '.iteration_summary.test_iterations' "$LOG_BASE/metrics.json")
    [ "$v" = "1" ]
}

@test "metrics.json iteration_summary contains pr_review_iterations" {
    _write_status_with_timestamps
    increment_pr_review_iteration
    increment_pr_review_iteration
    increment_pr_review_iteration
    export_metrics

    local v
    v=$(jq -r '.iteration_summary.pr_review_iterations' "$LOG_BASE/metrics.json")
    [ "$v" = "3" ]
}

@test "metrics.json iteration_summary defaults to zero when no iterations occurred" {
    _write_status_with_timestamps
    export_metrics

    local q t p
    q=$(jq -r '.iteration_summary.quality_iterations'    "$LOG_BASE/metrics.json")
    t=$(jq -r '.iteration_summary.test_iterations'       "$LOG_BASE/metrics.json")
    p=$(jq -r '.iteration_summary.pr_review_iterations'  "$LOG_BASE/metrics.json")

    [ "$q" = "0" ]
    [ "$t" = "0" ]
    [ "$p" = "0" ]
}

# =============================================================================
# STARTED_AT / COMPLETED_AT ROLLUP (AC2)
# =============================================================================

@test "metrics.json started_at is earliest stage started_at" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.started_at' "$LOG_BASE/metrics.json")
    [ "$v" = "2024-01-01T10:00:00Z" ]
}

@test "metrics.json completed_at is latest stage completed_at" {
    _write_status_with_timestamps
    export_metrics
    local v
    v=$(jq -r '.completed_at' "$LOG_BASE/metrics.json")
    [ "$v" = "2024-01-01T10:01:01Z" ]
}
