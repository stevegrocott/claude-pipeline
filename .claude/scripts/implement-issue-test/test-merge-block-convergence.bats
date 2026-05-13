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
# STATIC ANALYSIS: DEGRADED_STAGES recording at convergence failure
# =============================================================================

@test "convergence-failure handler appends quality:convergence_failure entry to DEGRADED_STAGES" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# The exact DEGRADED_STAGES entry written in the >33% repeats branch
	[[ "$script_content" == *'DEGRADED_STAGES+=("quality:convergence_failure:$stage_prefix:iter=$loop_iteration")'* ]]
}

@test "quality-loop convergence branch calls set_final_state convergence_failure_quality" {
	# AC2: set_final_state "convergence_failure_quality" must be called in the
	# >33%-repeats branch so status.json reflects the convergence failure.
	# The merge stage overwrites it with "merge_blocked" if auto-merge is blocked.
	local conv_block
	conv_block=$(awk \
		'/if \(\( repeat_ratio > 33 \)\); then/,/loop_approved=true/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)
	[[ "$conv_block" == *'set_final_state "convergence_failure_quality"'* ]]
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

	# Blocked merge must exit 0 (leave PR open, not fail the pipeline).
	# Find the line number of set_final_state "merge_blocked", then check
	# that the next exit statement in the same block is exit 0.
	local block_pos next_exit
	block_pos=$(grep -n 'set_final_state "merge_blocked"' <<< "$script_content" \
		| tail -1 | cut -d: -f1)
	next_exit=$(awk "NR>$block_pos && /exit [0-9]/{ print; exit }" <<< "$script_content")
	[[ "$next_exit" == *'exit 0'* ]]
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
# FUNCTIONAL: merge stage skipped when merge_blocked_reason is set
# =============================================================================

@test "merge stage gate returns blocked_reason when merge_blocked_reason in status.json" {
	# Simulate the merge gate: with BLOCK_MERGE_ON_CONVERGENCE_FAILURE=1 (default)
	# and merge_blocked_reason persisted in status.json, the gate must return a
	# non-empty blocked_reason — meaning merge-mr.sh would be skipped.
	jq --arg r "Quality loop convergence failure: 75% of issues repeating at pre-commit (iter=2)" \
		'.merge_blocked_reason = $r' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	unset BLOCK_MERGE_ON_CONVERGENCE_FAILURE  # ensure default (1) is used

	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" != "0" ]]; then
		blocked_reason=$(jq -r '.merge_blocked_reason // empty' \
			"$STATUS_FILE" 2>/dev/null)
	fi

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"pre-commit"* ]]
}

@test "merge stage gate skips merge-mr.sh when DEGRADED_STAGES has convergence entry and no status.json field" {
	# Fallback path: no merge_blocked_reason in status.json but DEGRADED_STAGES
	# has a quality:convergence_failure entry.  The gate must still produce a
	# non-empty blocked_reason so merge-mr.sh is skipped.
	declare -a deg=("quality:convergence_failure:main:iter=3")

	local blocked_reason=""
	local _ds
	for _ds in "${deg[@]}"; do
		if [[ "$_ds" == quality:convergence_failure:* ]]; then
			blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
			break
		fi
	done

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"quality:convergence_failure:main:iter=3"* ]]
}

# =============================================================================
# FUNCTIONAL: BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 restores old merge behavior
# =============================================================================

@test "BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 allows merge even when DEGRADED_STAGES has convergence failure" {
	# Old (pre-fix) behavior: merge proceeds regardless of convergence failure.
	# With =0 the gate is bypassed — merge_blocked_reason must stay empty.
	export BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0
	DEGRADED_STAGES=("quality:convergence_failure:main:iter=2")

	jq '.merge_blocked_reason = "should be bypassed"' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" != "0" ]]; then
		blocked_reason=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null)
		if [[ -z "$blocked_reason" ]]; then
			local _ds
			for _ds in "${DEGRADED_STAGES[@]}"; do
				if [[ "$_ds" == quality:convergence_failure:* ]]; then
					blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
					break
				fi
			done
		fi
	fi

	# Gate bypassed — blocked_reason must be empty so merge-mr.sh is reached
	[[ -z "$blocked_reason" ]]
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

# =============================================================================
# BEHAVIORAL: process-pr SKILL.md contains AC4 merge-block gate logic
# =============================================================================
# SKILL_FILE is derived from ORCHESTRATOR_SCRIPT (set at load time, real path).
# SCRIPT_DIR is re-set by sourced orchestrator functions and points to TEST_TMP.

@test "process-pr SKILL.md reads merge_blocked_reason from status.json before merging" {
	local skill_file
	skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]
	grep -q '\.merge_blocked_reason // empty' "$skill_file"
}

@test "process-pr SKILL.md block check precedes merge-mr.sh invocation" {
	local skill_file
	skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]

	local block_line merge_line
	block_line=$(grep -n 'merge_blocked_reason // empty' "$skill_file" | head -1 | cut -d: -f1)
	# Match the actual invocation line (contains PLATFORM_DIR), not prose references
	merge_line=$(grep -n 'PLATFORM_DIR.*merge-mr\.sh\|merge-mr\.sh.*PR_NUMBER' "$skill_file" | head -1 | cut -d: -f1)

	[[ -n "$block_line" ]]
	[[ -n "$merge_line" ]]
	(( block_line < merge_line ))
}

@test "process-pr SKILL.md exits without merging when MERGE_BLOCKED_REASON is set" {
	local skill_file
	skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]
	# Skill must document a non-merge exit path when the block reason is populated
	grep -q 'MERGE BLOCKED' "$skill_file"
	grep -q 'Leave the PR open' "$skill_file"
}

@test "process-pr SKILL.md supports BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 override" {
	local skill_file
	skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]
	grep -q 'BLOCK_MERGE_ON_CONVERGENCE_FAILURE' "$skill_file"
}

@test "process-pr SKILL.md falls back to degraded_stages scan when merge_blocked_reason absent" {
	local skill_file
	skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]
	# Skill must document the degraded_stages fallback path
	grep -q 'degraded_stages' "$skill_file"
	grep -q 'quality:convergence_failure' "$skill_file"
}
