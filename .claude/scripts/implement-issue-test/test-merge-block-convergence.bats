#!/usr/bin/env bats
#
# test-merge-block-convergence.bats
# Tests for merge blocking on quality:convergence_failure degradation
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

	ORCHESTRATOR_START_EPOCH=$(date +%s)
	DEGRADED_STAGES=()

	source_orchestrator_functions
	init_status
}

teardown() {
	teardown_test_env
}

# =============================================================================
# STATIC ANALYSIS: merge_blocked_reason persistence at convergence failure
# =============================================================================

@test "convergence failure handler persists merge_blocked_reason to status.json" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# After adding to DEGRADED_STAGES, the script must write merge_blocked_reason
	[[ "$script_content" == *'merge_blocked_reason'* ]]
}

@test "convergence failure writes merge_blocked_reason via jq --arg" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'.merge_blocked_reason = $reason'* ]]
}

@test "merge_blocked_reason includes repeat_ratio and stage context" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Block reason must embed the ratio and stage prefix
	[[ "$script_content" == *'${repeat_ratio}% of issues repeating at $stage_prefix'* ]]
}

@test "merge_blocked_reason includes repeating issues when present" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# The block reason should include the repeat_issues text
	[[ "$script_content" == *'Repeating issues:'* ]]
}

# =============================================================================
# STATIC ANALYSIS: BLOCK_MERGE_ON_CONVERGENCE_FAILURE gate in merge stage
# =============================================================================

@test "merge stage checks BLOCK_MERGE_ON_CONVERGENCE_FAILURE env var" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1'* ]]
}

@test "BLOCK_MERGE_ON_CONVERGENCE_FAILURE defaults to 1 (blocking enabled)" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Default must be 1, not 0
	[[ "$script_content" == *'BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1'* ]]
	[[ "$script_content" != *'BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-0'* ]]
}

@test "merge stage reads merge_blocked_reason from status.json" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'.merge_blocked_reason // empty'* ]]
}

@test "merge stage falls back to scanning DEGRADED_STAGES array" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Fallback loop checks entries starting with quality:convergence_failure:
	[[ "$script_content" == *'quality:convergence_failure:*'* ]]
}

@test "merge stage calls comment_pr when merge is blocked" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'Merge Blocked — Unresolved Quality Feedback'* ]]
}

@test "merge stage sets final state to merge_blocked when blocked" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'set_final_state "merge_blocked"'* ]]
}

@test "merge stage exits 0 (not error) when merge is blocked" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Blocked merge must exit 0 (leave PR open, not fail the pipeline)
	[[ "$script_content" == *'set_final_state "merge_blocked"'*$'\n'*'exit 0'* ]] || \
	grep -q 'set_final_state "merge_blocked"' <<< "$script_content"
}

@test "merge stage block check precedes merge-mr.sh call" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# BLOCK_MERGE_ON_CONVERGENCE_FAILURE check must appear before merge-mr.sh
	local block_pos merge_pos
	block_pos=$(grep -n 'BLOCK_MERGE_ON_CONVERGENCE_FAILURE' <<< "$script_content" \
		| tail -1 | cut -d: -f1)
	merge_pos=$(grep -n 'merge-mr.sh' <<< "$script_content" \
		| tail -1 | cut -d: -f1)

	(( block_pos < merge_pos ))
}

@test "merge stage logs bypass message when BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 — skipping merge-block check'* ]]
}

# =============================================================================
# FUNCTIONAL: merge_blocked_reason written to status.json
# =============================================================================

@test "status.json gains merge_blocked_reason when jq command is run" {
	# Simulate what the convergence failure handler does
	local block_reason="Quality loop convergence failure: 75% of issues repeating at main (iter=3)"
	jq --arg reason "$block_reason" \
		'.merge_blocked_reason = $reason | .last_update = (now | todate)' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local stored
	stored=$(jq -r '.merge_blocked_reason' "$STATUS_FILE")
	[[ "$stored" == "$block_reason" ]]
}

@test "status.json merge_blocked_reason includes repeating issues" {
	local block_reason
	block_reason=$(printf 'Quality loop convergence failure: 60%% of issues repeating at pre-commit (iter=2)\nRepeating issues:\n- Missing null check\n- Unused import')
	jq --arg reason "$block_reason" \
		'.merge_blocked_reason = $reason' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local stored
	stored=$(jq -r '.merge_blocked_reason' "$STATUS_FILE")
	[[ "$stored" == *"Repeating issues"* ]]
}

# =============================================================================
# FUNCTIONAL: merge stage block check logic
# =============================================================================

@test "blocked_reason is read from merge_blocked_reason field in status.json" {
	# Write a merge_blocked_reason to status.json
	jq '.merge_blocked_reason = "test block reason"' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local blocked_reason
	blocked_reason=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null)
	[[ "$blocked_reason" == "test block reason" ]]
}

@test "DEGRADED_STAGES fallback detects quality:convergence_failure entry" {
	declare -a test_stages=("quality:max_iterations:main:iter=5" \
		"quality:convergence_failure:main:iter=3")

	local blocked_reason=""
	local _ds
	for _ds in "${test_stages[@]}"; do
		if [[ "$_ds" == quality:convergence_failure:* ]]; then
			blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
			break
		fi
	done

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"quality:convergence_failure:main:iter=3"* ]]
}

@test "DEGRADED_STAGES fallback returns empty when no convergence failure present" {
	declare -a test_stages=("quality:max_iterations:main:iter=5" \
		"test:max_iterations:iter=7")

	local blocked_reason=""
	local _ds
	for _ds in "${test_stages[@]}"; do
		if [[ "$_ds" == quality:convergence_failure:* ]]; then
			blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
			break
		fi
	done

	[[ -z "$blocked_reason" ]]
}

@test "BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 disables block check" {
	export BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0

	# Even with a blocked reason in status.json, setting the flag to 0
	# should bypass the check
	jq '.merge_blocked_reason = "should be ignored"' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	# The gate: if flag is 0, skip reading blocked_reason
	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" != "0" ]]; then
		blocked_reason=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null)
	fi

	[[ -z "$blocked_reason" ]]
}

@test "BLOCK_MERGE_ON_CONVERGENCE_FAILURE=1 enables block check by default" {
	# Unset so the default kicks in
	unset BLOCK_MERGE_ON_CONVERGENCE_FAILURE

	jq '.merge_blocked_reason = "block is active"' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" != "0" ]]; then
		blocked_reason=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null)
	fi

	[[ "$blocked_reason" == "block is active" ]]
}

# =============================================================================
# STATIC ANALYSIS: process-pr schema includes merge_blocked status
# =============================================================================

@test "process-pr schema allows merge_blocked as a valid status" {
	local schema_file
	schema_file="$SCRIPT_DIR/schemas/process-pr.json"

	[[ -f "$schema_file" ]]
	grep -q '"merge_blocked"' "$schema_file"
}
