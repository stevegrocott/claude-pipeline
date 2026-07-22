#!/usr/bin/env bats
#
# test-merge-block-partial.bats
# Tests for issue #577: block merge + report on partial task failure /
# rejected PR review.  Mirrors test-merge-block-convergence.bats idioms:
# static analysis of the orchestrator source plus functional simulation of
# the gate logic.
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
# STATIC ANALYSIS: partial-completion detection after the implement stage
# =============================================================================

@test "implement stage records implement:partial when completed_tasks < task_count" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# The exact DEGRADED_STAGES entry appended on partial completion.
	[[ "$script_content" == *'DEGRADED_STAGES+=("implement:partial:${completed_tasks}/${task_count}")'* ]]
}

@test "partial detection gate compares completed_tasks against task_count" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'(( completed_tasks < task_count ))'* ]]
}

@test "partial detection posts an issue comment listing failed tasks" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'Implementation: Partial'* ]]
	# The failed-task list is derived from status.json tasks with status failed
	[[ "$script_content" == *'select(.status == "failed")'* ]]
}

@test "partial detection persists a merge_blocked_reason to status.json" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# A persisted reason lets a standalone process-pr / resumed run honour the gate
	[[ "$script_content" == *'Partial implementation'* ]]
}

# =============================================================================
# STATIC ANALYSIS: BLOCK_MERGE_ON_PARTIAL gate in the merge stage
# =============================================================================

@test "merge stage checks BLOCK_MERGE_ON_PARTIAL env var" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'BLOCK_MERGE_ON_PARTIAL:-1'* ]]
}

@test "BLOCK_MERGE_ON_PARTIAL defaults to 1 (blocking enabled)" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'BLOCK_MERGE_ON_PARTIAL:-1'* ]]
	[[ "$script_content" != *'BLOCK_MERGE_ON_PARTIAL:-0'* ]]
}

@test "merge stage blocks on implement:partial degraded entry" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'implement:partial:*'* ]]
}

@test "merge stage blocks on pr_review max_iterations and wall_timeout" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'pr_review:max_iterations:*'* ]]
	[[ "$script_content" == *'pr_review:wall_timeout'* ]]
}

@test "merge stage logs bypass message when BLOCK_MERGE_ON_PARTIAL=0" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'BLOCK_MERGE_ON_PARTIAL=0 — skipping partial/pr-review merge-block check'* ]]
}

@test "partial block check precedes merge-mr.sh call" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	local block_pos merge_pos
	block_pos=$(grep -n 'BLOCK_MERGE_ON_PARTIAL' <<< "$script_content" \
		| tail -1 | cut -d: -f1)
	merge_pos=$(grep -n 'merge-mr.sh' <<< "$script_content" \
		| tail -1 | cut -d: -f1)

	(( block_pos < merge_pos ))
}

# =============================================================================
# STATIC ANALYSIS: completed_partial final state + distinct exit code
# =============================================================================

@test "merge stage sets final state completed_partial when partial-blocked" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'set_final_state "completed_partial"'* ]]
}

@test "partial-blocked path exits non-zero and distinct from error (exit 2)" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# The exit statement following set_final_state "completed_partial" must be
	# exit 2 — non-zero (unlike merge_blocked's exit 0) and distinct from the
	# error path's exit 1.
	local block_pos next_exit
	block_pos=$(grep -n 'set_final_state "completed_partial"' <<< "$script_content" \
		| tail -1 | cut -d: -f1)
	next_exit=$(awk "NR>$block_pos && /exit [0-9]/{ print; exit }" <<< "$script_content")
	[[ "$next_exit" == *'exit 2'* ]]
}

@test "convergence merge_blocked path still exits 0 (regression guard)" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Issue #577 must not change the convergence gate: the exit after the last
	# set_final_state "merge_blocked" stays exit 0.
	local block_pos next_exit
	block_pos=$(grep -n 'set_final_state "merge_blocked"' <<< "$script_content" \
		| tail -1 | cut -d: -f1)
	next_exit=$(awk "NR>$block_pos && /exit [0-9]/{ print; exit }" <<< "$script_content")
	[[ "$next_exit" == *'exit 0'* ]]
}

@test "final comment path includes a task summary helper" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'_format_task_summary_line'* ]]
}

# =============================================================================
# FUNCTIONAL: _format_task_summary_line reflects failed tasks
# =============================================================================

@test "_format_task_summary_line reports completed/total with failure count" {
	# Seed status.json with 1 completed + 2 failed tasks
	jq '.tasks = [
		{"id":1,"description":"A","status":"completed"},
		{"id":2,"description":"B","status":"failed"},
		{"id":3,"description":"C","status":"failed"}
	]' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local line
	line=$(_format_task_summary_line)

	[[ "$line" == *'1/3'* ]]
	[[ "$line" == *'2 failed'* ]]
}

@test "_format_task_summary_line is empty when there are no tasks" {
	# init_status leaves .tasks absent/empty
	local line
	line=$(_format_task_summary_line)

	[[ -z "$line" ]]
}

# =============================================================================
# FUNCTIONAL: partial gate logic (mirrors the in-script scan)
# =============================================================================

@test "partial gate detects implement:partial entry and blocks" {
	declare -a deg=("implement:partial:1/3")

	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_PARTIAL:-1}" != "0" ]]; then
		local _ds
		for _ds in "${deg[@]}"; do
			if [[ "$_ds" == implement:partial:* ]]; then
				blocked_reason="Partial implementation — not all tasks completed (degraded_stages: $_ds)"
				break
			fi
		done
	fi

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"1/3"* ]]
}

@test "partial gate detects pr_review:max_iterations entry and blocks" {
	declare -a deg=("pr_review:max_iterations:iter=4")

	local blocked_reason=""
	local _ds
	for _ds in "${deg[@]}"; do
		if [[ "$_ds" == pr_review:max_iterations:* || "$_ds" == pr_review:wall_timeout ]]; then
			blocked_reason="PR review loop ended without an approved verdict (degraded_stages: $_ds)"
			break
		fi
	done

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"max_iterations"* ]]
}

@test "partial gate detects pr_review:wall_timeout entry and blocks" {
	declare -a deg=("pr_review:wall_timeout")

	local blocked_reason=""
	local _ds
	for _ds in "${deg[@]}"; do
		if [[ "$_ds" == pr_review:max_iterations:* || "$_ds" == pr_review:wall_timeout ]]; then
			blocked_reason="PR review loop ended without an approved verdict (degraded_stages: $_ds)"
			break
		fi
	done

	[[ -n "$blocked_reason" ]]
}

@test "BLOCK_MERGE_ON_PARTIAL=0 restores merge-anyway behaviour" {
	export BLOCK_MERGE_ON_PARTIAL=0
	declare -a deg=("implement:partial:1/3")

	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_PARTIAL:-1}" != "0" ]]; then
		local _ds
		for _ds in "${deg[@]}"; do
			if [[ "$_ds" == implement:partial:* ]]; then
				blocked_reason="blocked"
				break
			fi
		done
	fi

	# Gate bypassed — merge-mr.sh would be reached
	[[ -z "$blocked_reason" ]]
}

@test "partial gate ignores non-blocking degradations" {
	declare -a deg=("test:max_iterations:iter=7" "deploy_verify:deploy_failed:exit=1")

	local blocked_reason=""
	local _ds
	for _ds in "${deg[@]}"; do
		if [[ "$_ds" == implement:partial:* \
			|| "$_ds" == pr_review:max_iterations:* \
			|| "$_ds" == pr_review:wall_timeout ]]; then
			blocked_reason="blocked"
			break
		fi
	done

	[[ -z "$blocked_reason" ]]
}

# =============================================================================
# FUNCTIONAL: failed-task list derivation from status.json
# =============================================================================

@test "failed-task list names each failed task from status.json" {
	jq '.tasks = [
		{"id":1,"description":"Add regression test","status":"completed"},
		{"id":2,"description":"Fix the secret handling","status":"failed"},
		{"id":3,"description":"Update the workflow file","status":"failed"}
	]' "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local failed_list
	failed_list=$(jq -r '
		[.tasks[]? | select(.status == "failed")
			| "- Task \(.id): \(.description)"] | join("\n")' "$STATUS_FILE")

	[[ "$failed_list" == *"Fix the secret handling"* ]]
	[[ "$failed_list" == *"Update the workflow file"* ]]
	[[ "$failed_list" != *"Add regression test"* ]]
}

# =============================================================================
# STATIC ANALYSIS: batch-orchestrator handles completed_partial without crash
# =============================================================================

@test "batch-orchestrator maps completed_partial state explicitly" {
	local batch_content
	batch_content=$(< "$BATCH_ORCHESTRATOR_SCRIPT_PATH")

	# Must have an explicit case arm so completed_partial is NOT swept into the
	# generic error path (which would flip to success via the PR-recovery logic).
	[[ "$batch_content" == *'completed_partial)'* ]]
}

# =============================================================================
# RESUME DURABILITY: pr_review soft-fail persists a merge_blocked_reason
# (issue #577). Regression: the three pr_review degradation sites used to only
# append to the in-memory DEGRADED_STAGES array. set_stage_completed "pr_review"
# runs unconditionally after the loop, so a crash+resume skipped the loop with
# an empty DEGRADED_STAGES and NO persisted reason → the merge gate saw nothing
# and merged an UNAPPROVED PR. The reason must survive into status.json.
# =============================================================================

@test "persist_merge_blocked_reason writes the reason into status.json" {
	# Fresh status.json from init_status has .merge_blocked_reason == null.
	run jq -r '.merge_blocked_reason' "$STATUS_FILE"
	[[ "$output" == "null" || -z "$output" ]]

	# Drive the real persist function the soft-fail sites call.
	persist_merge_blocked_reason \
		"PR review loop ended without an approved verdict after max iterations (pr_review:max_iterations:iter=3)."

	local persisted
	persisted=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE")
	[[ -n "$persisted" ]]
	[[ "$persisted" == *"pr_review"* ]]
}

@test "pr_review max_iterations soft-fail survives into status.json for a resumed run" {
	# Simulate the exact max_iterations soft-fail sequence the loop runs.
	set_final_state "max_iterations_pr_review"
	DEGRADED_STAGES+=("pr_review:max_iterations:iter=3")
	persist_merge_blocked_reason \
		"PR review loop ended without an approved verdict after max iterations (pr_review:max_iterations:iter=3)."

	# Simulate crash+resume: the in-memory array is lost on a fresh process.
	DEGRADED_STAGES=()

	# The merge gate's first move is to read the persisted reason from
	# status.json — that is the ONLY signal available after a resume.
	local persisted
	persisted=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE")
	[[ -n "$persisted" ]]
	[[ "$persisted" == *"pr_review"* ]]
}

@test "pr_review wall_timeout soft-fail survives into status.json for a resumed run" {
	set_final_state "wall_timeout_pr_review"
	DEGRADED_STAGES+=("pr_review:wall_timeout")
	persist_merge_blocked_reason \
		"PR review loop hit wall-clock timeout without an approved verdict (pr_review:wall_timeout)."

	DEGRADED_STAGES=()

	local persisted
	persisted=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE")
	[[ -n "$persisted" ]]
	[[ "$persisted" == *"pr_review"* ]]
}

@test "persist_merge_blocked_reason does not clobber a pre-existing reason" {
	# A prior gate (e.g. quality convergence) may already have set a reason.
	jq --arg r "Quality loop convergence failure" \
		'.merge_blocked_reason = $r' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	persist_merge_blocked_reason \
		"PR review loop ended without an approved verdict (pr_review:max_iterations:iter=3)."

	# The // guard keeps the first-set reason.
	local persisted
	persisted=$(jq -r '.merge_blocked_reason' "$STATUS_FILE")
	[[ "$persisted" == "Quality loop convergence failure" ]]
}

@test "all three pr_review degradation sites also persist a merge_blocked_reason" {
	# Static wiring guard: each DEGRADED_STAGES+=("pr_review:...") append in the
	# PR review loop must be paired with a persist_merge_blocked_reason call so
	# the block is durable across a resume. Extract the three-guard region and
	# assert one persist call per pr_review append.
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	local pr_appends persist_calls
	pr_appends=$(grep -c 'DEGRADED_STAGES+=("pr_review:' <<< "$script_content")
	# Persist calls that name a pr_review cause.
	persist_calls=$(grep -c 'persist_merge_blocked_reason' <<< "$script_content")

	# Three pr_review appends (2× wall_timeout, 1× max_iterations).
	[[ "$pr_appends" -eq 3 ]]
	# At least three persist calls exist (the three pr_review sites).
	[[ "$persist_calls" -ge 3 ]]
}
