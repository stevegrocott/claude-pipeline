#!/usr/bin/env bats
#
# test-pipeline-profile.bats
# Unit tests for compute_pipeline_profile() three-tier classification.
#
# Branches under test:
#   full     — any M or L task present
#   minimal  — single task (any size, M/L caught first) OR diff < 20 lines
#   standard — all S-tasks, multiple tasks, diff >= 20 lines
#

load 'helpers/test-helper.bash'

# =============================================================================
# TEST SETUP / TEARDOWN
# =============================================================================

setup() {
	setup_test_env
	install_mocks

	export ISSUE_NUMBER=123
	export BASE_BRANCH=main
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0
	export SCHEMA_DIR="$TEST_TMP/schemas"

	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
	mkdir -p "$SCHEMA_DIR"

	for schema in \
		implement-issue-implement \
		implement-issue-test \
		implement-issue-review \
		implement-issue-fix \
		implement-issue-simplify; do
		printf '{"type":"object"}\n' > "$SCHEMA_DIR/${schema}.json"
	done

	source_orchestrator_functions
	init_status
}

teardown() {
	teardown_test_env
}

# =============================================================================
# compute_pipeline_profile() — FULL profile
#
# Any M or L task triggers 'full', regardless of task count or diff size.
# =============================================================================

@test "compute_pipeline_profile: single M task returns 'full'" {
	get_diff_line_count() { printf '%s' "5"; }
	local tasks='[{"description":"**(M)** Add auth middleware"}]'
	local result
	result=$(compute_pipeline_profile "$tasks")
	[[ "$result" == "full" ]]
}

@test "compute_pipeline_profile: single L task returns 'full'" {
	get_diff_line_count() { printf '%s' "5"; }
	local tasks='[{"description":"**(L)** Refactor entire data layer"}]'
	local result
	result=$(compute_pipeline_profile "$tasks")
	[[ "$result" == "full" ]]
}

@test "compute_pipeline_profile: M task among multiple S tasks returns 'full'" {
	get_diff_line_count() { printf '%s' "5"; }
	local tasks
	tasks='[
		{"description":"**(S)** Fix typo"},
		{"description":"**(M)** Add rate limiting"},
		{"description":"**(S)** Update README"}
	]'
	local result
	result=$(compute_pipeline_profile "$tasks")
	[[ "$result" == "full" ]]
}

# =============================================================================
# compute_pipeline_profile() — MINIMAL profile (single task)
#
# A single task of any size is minimal (M/L caught by full guard above).
# =============================================================================

@test "compute_pipeline_profile: single S task returns 'minimal'" {
	get_diff_line_count() { printf '%s' "100"; }
	local tasks='[{"description":"**(S)** Fix typo in README"}]'
	local result
	result=$(compute_pipeline_profile "$tasks")
	[[ "$result" == "full" || "$result" == "minimal" ]]
	# A single S-task has ml_count=0 and task_count=1, so must be minimal
	[[ "$result" == "minimal" ]]
}

# =============================================================================
# compute_pipeline_profile() — MINIMAL profile (small diff)
#
# Multiple S-tasks but diff < 20 lines also yields minimal.
# =============================================================================

@test "compute_pipeline_profile: multiple S tasks with diff < 20 lines returns 'minimal'" {
	# 19 is the highest value still below the 20-line threshold
	get_diff_line_count() { printf '%s' "19"; }
	local tasks
	tasks='[
		{"description":"**(S)** Fix typo"},
		{"description":"**(S)** Update constant"}
	]'
	local result
	result=$(compute_pipeline_profile "$tasks")
	[[ "$result" == "minimal" ]]
}

@test "compute_pipeline_profile: multiple S tasks with diff == 0 lines returns 'minimal'" {
	get_diff_line_count() { printf '%s' "0"; }
	local tasks
	tasks='[
		{"description":"**(S)** Adjust config"},
		{"description":"**(S)** Rename variable"}
	]'
	local result
	result=$(compute_pipeline_profile "$tasks")
	[[ "$result" == "minimal" ]]
}

# =============================================================================
# compute_pipeline_profile() — STANDARD profile
#
# Multiple S-tasks and diff >= 20 lines yields standard.
# =============================================================================

@test "compute_pipeline_profile: multiple S tasks with diff >= 20 lines returns 'standard'" {
	# 20 is the exact boundary entering standard territory
	get_diff_line_count() { printf '%s' "20"; }
	local tasks
	tasks='[
		{"description":"**(S)** Fix typo"},
		{"description":"**(S)** Update constant"}
	]'
	local result
	result=$(compute_pipeline_profile "$tasks")
	[[ "$result" == "standard" ]]
}

@test "compute_pipeline_profile: multiple S tasks with large diff returns 'standard'" {
	get_diff_line_count() { printf '%s' "300"; }
	local tasks
	tasks='[
		{"description":"**(S)** Add validation"},
		{"description":"**(S)** Add tests"},
		{"description":"**(S)** Update docs"}
	]'
	local result
	result=$(compute_pipeline_profile "$tasks")
	[[ "$result" == "standard" ]]
}

# =============================================================================
# compute_pipeline_profile() — EMPTY / EDGE CASES
#
# Empty task list has task_count=0 and ml_count=0.  It falls through to
# the diff-size check; with a small diff it should be minimal.
# =============================================================================

@test "compute_pipeline_profile: empty task list with small diff returns 'minimal'" {
	get_diff_line_count() { printf '%s' "0"; }
	local result
	result=$(compute_pipeline_profile "[]")
	[[ "$result" == "minimal" ]]
}

@test "compute_pipeline_profile: empty task list with large diff returns 'standard'" {
	get_diff_line_count() { printf '%s' "50"; }
	local result
	result=$(compute_pipeline_profile "[]")
	[[ "$result" == "standard" ]]
}
