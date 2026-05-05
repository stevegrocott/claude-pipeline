#!/usr/bin/env bats
#
# test-batch-events.bats
# Tests for batch-level JSONL event emission in batch-orchestrator.sh
#
# Cases covered:
#
#   emit_event — batch_start:
#     1. creates events.jsonl in LOG_BASE
#     2. event field equals "batch_start"
#     3. event has required base fields: ts and run_id
#     4. event carries total_issues and branch
#
#   emit_event — issue_start / issue_end:
#     1. issue_start has issue_num field
#     2. issue_end with outcome=success has correct fields
#     3. issue_end with outcome=failed has correct fields
#     4. each call appends a new line (JSONL format)
#
#   emit_event — batch_paused (circuit-breaker path):
#     1. batch_paused event emitted with consecutive_failures
#     2. batch_paused event carries max_failures
#
#   schema validation (required fields via jq):
#     1. batch_start event has all required base and specific fields
#     2. issue_start event has all required fields
#     3. issue_end event has all required fields
#     4. batch_paused event has all required fields
#

load 'helpers/test-helper.bash'

# =============================================================================
# LOCAL CONSTANTS
# =============================================================================

# Path to the script-under-test (batch-orchestrator.sh lives alongside
# implement-issue-orchestrator.sh in the same SCRIPT_DIR)
BATCH_ORCHESTRATOR_SCRIPT=""

# =============================================================================
# HELPER: source emit_event from batch-orchestrator.sh
# =============================================================================

# Extract and source just the emit_event function from batch-orchestrator.sh.
# This mirrors the source_orchestrator_functions() pattern in test-helper.bash,
# scoped to the one function we need.
source_batch_emit_event() {
	local func_file="$TEST_TMP/batch_emit_event.bash"

	# Extract emit_event function definition using awk
	awk '
		/^emit_event\(\) \{$/,/^\}$/ { print; next }
	' "$BATCH_ORCHESTRATOR_SCRIPT" > "$func_file"

	# Fail fast if no function was extracted (task 2 not yet merged)
	if ! grep -q "emit_event()" "$func_file" 2>/dev/null; then
		printf 'ERROR: emit_event() not found in %s\n' \
			"$BATCH_ORCHESTRATOR_SCRIPT" >&2
		return 1
	fi

	# Source the extracted function into the current shell
	# shellcheck disable=SC1090
	source "$func_file"
}

# Assert that a JSONL event file contains a line where the given jq expression
# evaluates to the expected string value.
# Usage: assert_event_field <events_file> <jq_expr> <expected>
assert_event_field() {
	local events_file="$1"
	local jq_expr="$2"
	local expected="$3"

	local actual
	actual=$(jq -r "$jq_expr" "$events_file" 2>/dev/null | tail -1)

	if [[ "$actual" != "$expected" ]]; then
		printf 'FAIL: jq(%s) expected "%s", got "%s"\n' \
			"$jq_expr" "$expected" "$actual" >&2
		return 1
	fi
}

# Assert that a field in the last event line is not empty / null.
# Usage: assert_event_field_set <events_file> <jq_expr>
assert_event_field_set() {
	local events_file="$1"
	local jq_expr="$2"

	local actual
	actual=$(jq -r "$jq_expr" "$events_file" 2>/dev/null | tail -1)

	if [[ -z "$actual" || "$actual" == "null" ]]; then
		printf 'FAIL: jq(%s) is empty or null (got "%s")\n' \
			"$jq_expr" "$actual" >&2
		return 1
	fi
}

# Validate that the last event line in a JSONL file satisfies the base schema:
# required fields: event, ts, run_id.
# Returns 0 if all required fields are present and non-null.
validate_event_base_schema() {
	local events_file="$1"

	assert_event_field_set "$events_file" '.event' || return 1
	assert_event_field_set "$events_file" '.ts'    || return 1
	assert_event_field_set "$events_file" '.run_id' || return 1
}

# =============================================================================
# SETUP / TEARDOWN
# =============================================================================

setup() {
	setup_test_env

	# SCRIPT_DIR is set by test-helper.bash to .claude/scripts/
	BATCH_ORCHESTRATOR_SCRIPT="$SCRIPT_DIR/batch-orchestrator.sh"

	export LOG_BASE="$TEST_TMP/logs/batch-20240101-100000"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	mkdir -p "$LOG_BASE"

	source_batch_emit_event
}

teardown() {
	teardown_test_env
}

# =============================================================================
# batch_start — event emitted
# =============================================================================

@test "emit_event writes events.jsonl to LOG_BASE for batch_start" {
	emit_event "batch_start" \
		"total_issues:=3" "branch=main"

	[ -f "$LOG_BASE/events.jsonl" ]
}

@test "emit_event batch_start: event field is 'batch_start'" {
	emit_event "batch_start" \
		"total_issues:=3" "branch=main"

	assert_event_field "$LOG_BASE/events.jsonl" '.event' "batch_start"
}

@test "emit_event batch_start: ts field is present and non-empty" {
	emit_event "batch_start" \
		"total_issues:=3" "branch=main"

	assert_event_field_set "$LOG_BASE/events.jsonl" '.ts'
}

@test "emit_event batch_start: run_id field is present and non-empty" {
	emit_event "batch_start" \
		"total_issues:=3" "branch=main"

	assert_event_field_set "$LOG_BASE/events.jsonl" '.run_id'
}

@test "emit_event batch_start: total_issues field carries numeric value" {
	emit_event "batch_start" \
		"total_issues:=3" "branch=main"

	local val
	val=$(jq -r '.total_issues' "$LOG_BASE/events.jsonl" | tail -1)
	[ "$val" = "3" ]
}

@test "emit_event batch_start: branch field carries string value" {
	emit_event "batch_start" \
		"total_issues:=2" "branch=feature/test"

	assert_event_field "$LOG_BASE/events.jsonl" '.branch' "feature/test"
}

# =============================================================================
# issue_start / issue_end — emitted per issue with correct outcome
# =============================================================================

@test "emit_event issue_start: event field is 'issue_start'" {
	emit_event "issue_start" "issue_num=123"

	assert_event_field "$LOG_BASE/events.jsonl" '.event' "issue_start"
}

@test "emit_event issue_start: issue_num field matches emitted value" {
	emit_event "issue_start" "issue_num=42"

	assert_event_field "$LOG_BASE/events.jsonl" '.issue_num' "42"
}

@test "emit_event issue_end success: event field is 'issue_end'" {
	emit_event "issue_end" "issue_num=123" "outcome=success"

	assert_event_field "$LOG_BASE/events.jsonl" '.event' "issue_end"
}

@test "emit_event issue_end success: outcome field is 'success'" {
	emit_event "issue_end" "issue_num=123" "outcome=success"

	assert_event_field "$LOG_BASE/events.jsonl" '.outcome' "success"
}

@test "emit_event issue_end failed: outcome field is 'failed'" {
	emit_event "issue_end" "issue_num=456" "outcome=failed"

	assert_event_field "$LOG_BASE/events.jsonl" '.outcome' "failed"
}

@test "emit_event issue_end: issue_num field matches emitted value" {
	emit_event "issue_end" "issue_num=789" "outcome=success"

	assert_event_field "$LOG_BASE/events.jsonl" '.issue_num' "789"
}

@test "emit_event appends a new line per call (JSONL format)" {
	emit_event "issue_start" "issue_num=1"
	emit_event "issue_end"   "issue_num=1" "outcome=success"

	local line_count
	line_count=$(wc -l < "$LOG_BASE/events.jsonl")
	[ "$line_count" -eq 2 ]
}

@test "emit_event each line is valid JSON" {
	emit_event "issue_start" "issue_num=10"
	emit_event "issue_end"   "issue_num=10" "outcome=failed"

	# Every line must be parseable by jq
	while IFS= read -r line; do
		printf '%s' "$line" | jq -e '.' >/dev/null 2>&1 \
			|| { printf 'FAIL: invalid JSON line: %s\n' "$line" >&2; return 1; }
	done < "$LOG_BASE/events.jsonl"
}

# =============================================================================
# batch_paused — emitted on circuit-breaker path
# =============================================================================

@test "emit_event batch_paused: event field is 'batch_paused'" {
	emit_event "batch_paused" \
		"consecutive_failures:=3" "max_failures:=3"

	assert_event_field "$LOG_BASE/events.jsonl" '.event' "batch_paused"
}

@test "emit_event batch_paused: consecutive_failures carries numeric value" {
	emit_event "batch_paused" \
		"consecutive_failures:=3" "max_failures:=3"

	local val
	val=$(jq -r '.consecutive_failures' "$LOG_BASE/events.jsonl" | tail -1)
	[ "$val" = "3" ]
}

@test "emit_event batch_paused: max_failures carries numeric value" {
	emit_event "batch_paused" \
		"consecutive_failures:=3" "max_failures:=5"

	local val
	val=$(jq -r '.max_failures' "$LOG_BASE/events.jsonl" | tail -1)
	[ "$val" = "5" ]
}

# =============================================================================
# schema validation — all required fields present (jq field checks)
# =============================================================================

@test "schema: batch_start event has required base fields (event, ts, run_id)" {
	emit_event "batch_start" \
		"total_issues:=1" "branch=main"

	validate_event_base_schema "$LOG_BASE/events.jsonl"
}

@test "schema: batch_start event has required specific fields (total_issues, branch)" {
	emit_event "batch_start" \
		"total_issues:=4" "branch=dev"

	assert_event_field_set "$LOG_BASE/events.jsonl" '.total_issues'
	assert_event_field_set "$LOG_BASE/events.jsonl" '.branch'
}

@test "schema: issue_start event has required base fields (event, ts, run_id)" {
	emit_event "issue_start" "issue_num=99"

	validate_event_base_schema "$LOG_BASE/events.jsonl"
}

@test "schema: issue_start event has required specific field (issue_num)" {
	emit_event "issue_start" "issue_num=99"

	assert_event_field_set "$LOG_BASE/events.jsonl" '.issue_num'
}

@test "schema: issue_end event has required base fields (event, ts, run_id)" {
	emit_event "issue_end" "issue_num=7" "outcome=success"

	validate_event_base_schema "$LOG_BASE/events.jsonl"
}

@test "schema: issue_end event has required specific fields (issue_num, outcome)" {
	emit_event "issue_end" "issue_num=7" "outcome=success"

	assert_event_field_set "$LOG_BASE/events.jsonl" '.issue_num'
	assert_event_field_set "$LOG_BASE/events.jsonl" '.outcome'
}

@test "schema: batch_paused event has required base fields (event, ts, run_id)" {
	emit_event "batch_paused" \
		"consecutive_failures:=3" "max_failures:=3"

	validate_event_base_schema "$LOG_BASE/events.jsonl"
}

@test "schema: batch_paused event has required specific fields (consecutive_failures, max_failures)" {
	emit_event "batch_paused" \
		"consecutive_failures:=2" "max_failures:=3"

	assert_event_field_set "$LOG_BASE/events.jsonl" '.consecutive_failures'
	assert_event_field_set "$LOG_BASE/events.jsonl" '.max_failures'
}

# =============================================================================
# rate_limit_hit — emitted when a 429/quota exhaustion is encountered
# =============================================================================

@test "emit_event rate_limit_hit: event field is 'rate_limit_hit'" {
	emit_event "rate_limit_hit" "retry_after_seconds:=60"

	assert_event_field "$LOG_BASE/events.jsonl" '.event' "rate_limit_hit"
}

@test "emit_event rate_limit_hit: retry_after_seconds carries numeric value" {
	emit_event "rate_limit_hit" "retry_after_seconds:=60"

	local val
	val=$(jq -r '.retry_after_seconds' "$LOG_BASE/events.jsonl" | tail -1)
	[ "$val" = "60" ]
}

# =============================================================================
# batch_end — emitted when the batch finishes all issues
# =============================================================================

@test "emit_event batch_end: event field is 'batch_end'" {
	emit_event "batch_end" "outcome=completed"

	assert_event_field "$LOG_BASE/events.jsonl" '.event' "batch_end"
}

@test "emit_event batch_end: outcome field carries emitted value" {
	emit_event "batch_end" "outcome=completed"

	assert_event_field "$LOG_BASE/events.jsonl" '.outcome' "completed"
}
