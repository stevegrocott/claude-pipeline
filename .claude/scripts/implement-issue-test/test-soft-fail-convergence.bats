#!/usr/bin/env bats
#
# test-soft-fail-convergence.bats
# Tests for configurable limits, oscillation detection, wall-clock timeout,
# and soft-fail behavior
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env

	export ISSUE_NUMBER=123
	export BASE_BRANCH=test
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0

	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

	# Wall-clock and soft-fail variables not sourced from platform.sh
	ORCHESTRATOR_START_EPOCH=$(date +%s)
	DEGRADED_STAGES=()

	source_orchestrator_functions
	init_status
}

teardown() {
	teardown_test_env
}

# =============================================================================
# CONFIGURABLE ITERATION LIMITS
# =============================================================================

@test "MAX_QUALITY_ITERATIONS can be overridden by env var" {
	# The ${VAR:-default} pattern means pre-exported env vars win.
	# Verify by setting before sourcing platform.sh in a subshell.
	local result
	result=$(
		export MAX_QUALITY_ITERATIONS=3
		source "$TEST_TMP/.claude/config/platform.sh" 2>/dev/null
		printf '%s' "$MAX_QUALITY_ITERATIONS"
	)
	[ "$result" -eq 3 ]
}

@test "MAX_TEST_ITERATIONS can be overridden by env var" {
	local result
	result=$(
		export MAX_TEST_ITERATIONS=4
		source "$TEST_TMP/.claude/config/platform.sh" 2>/dev/null
		printf '%s' "$MAX_TEST_ITERATIONS"
	)
	[ "$result" -eq 4 ]
}

@test "MAX_PR_REVIEW_ITERATIONS can be overridden by env var" {
	local result
	result=$(
		export MAX_PR_REVIEW_ITERATIONS=1
		source "$TEST_TMP/.claude/config/platform.sh" 2>/dev/null
		printf '%s' "$MAX_PR_REVIEW_ITERATIONS"
	)
	[ "$result" -eq 1 ]
}

@test "MAX_ORCHESTRATOR_WALL_TIME can be overridden by env var" {
	local result
	result=$(
		export MAX_ORCHESTRATOR_WALL_TIME=7200
		source "$TEST_TMP/.claude/config/platform.sh" 2>/dev/null
		printf '%s' "$MAX_ORCHESTRATOR_WALL_TIME"
	)
	[ "$result" -eq 7200 ]
}

@test "defaults are used when env vars not set" {
	# setup() already sourced with no overrides -- check default values
	[ "$MAX_QUALITY_ITERATIONS" -eq 5 ]
	[ "$MAX_TEST_ITERATIONS" -eq 7 ]
	[ "$MAX_PR_REVIEW_ITERATIONS" -eq 2 ]
	[ "$MAX_ORCHESTRATOR_WALL_TIME" -eq 3600 ]
}

@test "iteration limits are not declared readonly in orchestrator" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# These should use the ${VAR:-default} pattern, not readonly
	[[ "$script_content" != *'readonly MAX_QUALITY_ITERATIONS'* ]]
	[[ "$script_content" != *'readonly MAX_TEST_ITERATIONS'* ]]
	[[ "$script_content" != *'readonly MAX_PR_REVIEW_ITERATIONS'* ]]
	[[ "$script_content" != *'readonly MAX_ORCHESTRATOR_WALL_TIME'* ]]
}

@test "iteration limits use env-override pattern in orchestrator" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'MAX_QUALITY_ITERATIONS="${MAX_QUALITY_ITERATIONS:-5}"'* ]]
	[[ "$script_content" == *'MAX_TEST_ITERATIONS="${MAX_TEST_ITERATIONS:-7}"'* ]]
	[[ "$script_content" == *'MAX_PR_REVIEW_ITERATIONS="${MAX_PR_REVIEW_ITERATIONS:-2}"'* ]]
	[[ "$script_content" == *'MAX_ORCHESTRATOR_WALL_TIME="${MAX_ORCHESTRATOR_WALL_TIME:-3600}"'* ]]
}

# =============================================================================
# WALL-CLOCK TIMEOUT
# =============================================================================

@test "check_wall_timeout is defined" {
	[ "$(type -t check_wall_timeout)" = "function" ]
}

@test "check_wall_timeout returns 0 when within time limit" {
	ORCHESTRATOR_START_EPOCH=$(date +%s)
	MAX_ORCHESTRATOR_WALL_TIME=3600
	check_wall_timeout
}

@test "check_wall_timeout returns 1 when time exceeded" {
	ORCHESTRATOR_START_EPOCH=$(( $(date +%s) - 7200 ))
	MAX_ORCHESTRATOR_WALL_TIME=3600
	run check_wall_timeout
	[ "$status" -eq 1 ]
}

@test "check_wall_timeout returns 0 at exact boundary" {
	local now
	now=$(date +%s)
	# Set start to exactly MAX_ORCHESTRATOR_WALL_TIME ago
	# The check is strictly greater-than, so equal should pass
	ORCHESTRATOR_START_EPOCH=$(( now - 3600 ))
	MAX_ORCHESTRATOR_WALL_TIME=3600
	check_wall_timeout
}

@test "check_wall_timeout returns 1 one second past boundary" {
	local now
	now=$(date +%s)
	ORCHESTRATOR_START_EPOCH=$(( now - 3601 ))
	MAX_ORCHESTRATOR_WALL_TIME=3600
	run check_wall_timeout
	[ "$status" -eq 1 ]
}

# =============================================================================
# DEGRADED_STAGES TRACKING
# =============================================================================

@test "DEGRADED_STAGES array is initialized empty" {
	declare -a DEGRADED_STAGES=()
	[ ${#DEGRADED_STAGES[@]} -eq 0 ]
}

@test "DEGRADED_STAGES accumulates entries" {
	declare -a DEGRADED_STAGES=()
	DEGRADED_STAGES+=("quality:max_iterations:main:iter=5")
	DEGRADED_STAGES+=("test:max_iterations:iter=7")
	[ ${#DEGRADED_STAGES[@]} -eq 2 ]
	[[ "${DEGRADED_STAGES[0]}" == "quality:max_iterations:main:iter=5" ]]
	[[ "${DEGRADED_STAGES[1]}" == "test:max_iterations:iter=7" ]]
}

@test "DEGRADED_STAGES is declared as array in orchestrator" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'declare -a DEGRADED_STAGES=()'* ]]
}

@test "quality loop adds to DEGRADED_STAGES on max iterations" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'DEGRADED_STAGES+=("quality:max_iterations:'* ]]
}

@test "test loop adds to DEGRADED_STAGES on max iterations" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'DEGRADED_STAGES+=("test:max_iterations:'* ]]
}

@test "pr review adds to DEGRADED_STAGES on max iterations" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'DEGRADED_STAGES+=("pr_review:max_iterations:'* ]]
}

@test "wall timeout adds to DEGRADED_STAGES in quality loop" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'DEGRADED_STAGES+=("quality:wall_timeout:'* ]]
}

@test "wall timeout adds to DEGRADED_STAGES in test loop" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'DEGRADED_STAGES+=("test:wall_timeout:'* ]]
}

@test "wall timeout adds to DEGRADED_STAGES in pr review" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'DEGRADED_STAGES+=("pr_review:wall_timeout'* ]]
}

# =============================================================================
# NO EXIT 2 IN SCRIPT (soft-fail replaces hard exit)
# =============================================================================

@test "no exit 2 calls remain in orchestrator" {
	local script_path
	script_path="$ORCHESTRATOR_SCRIPT"
	local exit2_count
	exit2_count=$(grep -c 'exit 2' "$script_path" || true)
	[ "$exit2_count" -eq 0 ]
}

@test "orchestrator uses soft-fail pattern instead of exit 2" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Soft-fail means loops break and add to DEGRADED_STAGES
	# rather than calling exit 2
	[[ "$script_content" == *"DEGRADED_STAGES"* ]]
	[[ "$script_content" != *"exit 2"* ]]
}

# =============================================================================
# DEGRADED_STAGES REPORTING
# =============================================================================

@test "main function checks DEGRADED_STAGES length for final reporting" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'${#DEGRADED_STAGES[@]}'* ]]
}

@test "DEGRADED_STAGES are serialised to JSON for status reporting" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# The orchestrator converts DEGRADED_STAGES to JSON array
	[[ "$script_content" == *'DEGRADED_STAGES[@]}'* ]]
	[[ "$script_content" == *'jq'* ]]
}
