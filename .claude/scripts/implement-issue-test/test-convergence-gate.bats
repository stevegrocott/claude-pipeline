#!/usr/bin/env bats
#
# test-convergence-gate.bats
# Regression coverage for issue #616 (surfaced via #620): the merge-block
# gate must not treat a task as incomplete when its declared deliverable
# files are present on the feature branch, even though the task's *recorded*
# stage status is "failed" (a later stage, e.g. fix-pr-review-iter-1,
# completed the abandoned work but never updated the task's own status in
# status.json).
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env

	export ISSUE_NUMBER=616
	export BASE_BRANCH=base
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0

	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

	ORCHESTRATOR_START_EPOCH=$(date +%s)
	DEGRADED_STAGES=()

	source_orchestrator_functions
	init_status

	# Real git repo standing in for the feature/base branch pair the fix
	# (#620 tasks 1-3) must diff against. Uses the same $base...HEAD idiom
	# already relied on by detect_change_scope() in the orchestrator.
	git init -q .
	git config user.email test@example.com
	git config user.name "Test"
	git commit -q --allow-empty -m "base"
	git branch -q "$BASE_BRANCH"
	git checkout -q -b feature
}

teardown() {
	teardown_test_env
}

# Re-implements the file-evidence check proposed in #620 task 1: a task's
# declared paths are "on the branch" when they differ between BASE_BRANCH
# and HEAD. This is the missing piece the orchestrator's PARTIAL-COMPLETION
# GATE (issue #577) does not yet consult — that gap is #620 tasks 1-3.
_task_has_file_evidence() {
	local base="$1"; shift
	local touched
	touched=$(git diff "$base"...HEAD --name-only 2>/dev/null)
	local p
	for p in "$@"; do
		[[ "$touched" == *"$p"* ]] && return 0
	done
	return 1
}

# Mirrors the orchestrator's merge-block Gate A/Gate B computation verbatim
# (implement-issue-orchestrator.sh, "Gate B — partial task completion...").
# The drift-guard tests below assert the real script still contains these
# exact fragments, so this mirror cannot silently go stale.
_run_merge_gate() {
	local merge_blocked_reason=""
	local merge_block_kind=""

	local _persisted
	_persisted=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null || printf '')

	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" == "0" ]]; then
		:
	else
		if [[ -n "$_persisted" && "$_persisted" != "Partial implementation:"* ]]; then
			merge_blocked_reason="$_persisted"
			merge_block_kind="convergence"
		else
			local _ds
			for _ds in "${DEGRADED_STAGES[@]+"${DEGRADED_STAGES[@]}"}"; do
				if [[ "$_ds" == quality:convergence_failure:* ]]; then
					merge_blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
					merge_block_kind="convergence"
					break
				fi
			done
		fi
	fi

	if [[ -z "$merge_blocked_reason" ]]; then
		if [[ "${BLOCK_MERGE_ON_PARTIAL:-1}" == "0" ]]; then
			:
		else
			if [[ "$_persisted" == "Partial implementation:"* ]]; then
				merge_blocked_reason="$_persisted"
				merge_block_kind="partial"
			else
				local _dsp
				for _dsp in "${DEGRADED_STAGES[@]+"${DEGRADED_STAGES[@]}"}"; do
					if [[ "$_dsp" == implement:partial:* ]]; then
						merge_blocked_reason="Partial implementation — not all tasks completed (degraded_stages: $_dsp)."
						merge_block_kind="partial"
						break
					fi
					if [[ "$_dsp" == pr_review:max_iterations:* || "$_dsp" == pr_review:wall_timeout ]]; then
						merge_blocked_reason="PR review loop ended without an approved verdict (degraded_stages: $_dsp)."
						merge_block_kind="partial"
						break
					fi
				done
			fi
		fi
	fi

	printf '%s\x1e%s' "$merge_blocked_reason" "$merge_block_kind"
}

@test "#616 regression: three tasks, two recorded failed, all deliverables on branch -> gate does not block" {
	# PR #616 (issue #614) task/stage data, reproduced from the #620 bug report.
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "resolve_consumer_file()", status: "completed",
		 files: ["plugins/pipeline-core/scripts/resolve-pipeline-root.sh"]},
		{id: 2, description: "wire platform.sh via resolver", status: "failed",
		 files: ["plugins/pipeline-core/scripts/implement-issue-orchestrator.sh"]},
		{id: 3, description: "bats coverage", status: "failed",
		 files: ["tests/marketplace-smoke.bats"]}
	]')
	set_tasks "$tasks_json"

	# Ground truth #616 reported: all three deliverables genuinely landed on
	# the branch (a later fix-pr-review-iter-1 stage completed the abandoned
	# work), invisible to .tasks[].status.
	mkdir -p plugins/pipeline-core/scripts tests
	echo "resolve_consumer_file() { :; }" > plugins/pipeline-core/scripts/resolve-pipeline-root.sh
	echo "# wired via resolver" > plugins/pipeline-core/scripts/implement-issue-orchestrator.sh
	echo "# bats coverage" > tests/marketplace-smoke.bats
	git add plugins tests
	git commit -q -m "implement #614"

	local task_count completed_tasks
	task_count=$(jq '(.tasks // []) | length' "$STATUS_FILE")
	completed_tasks=$(jq '[(.tasks // [])[] | select(.status == "completed")] | length' "$STATUS_FILE")
	[ "$task_count" -eq 3 ]
	[ "$completed_tasks" -eq 1 ]

	# Branch-evidence re-evaluation (the #620 fix): a "failed" task with its
	# declared files present on the branch is not actually incomplete.
	local verified_completed=$completed_tasks
	local id status
	while IFS=$'\t' read -r id status; do
		[[ "$status" == "failed" ]] || continue
		local -a files=()
		while IFS= read -r f; do
			files+=("$f")
		done < <(jq -r --argjson id "$id" '(.tasks[] | select(.id == $id)).files[]' "$STATUS_FILE")
		if _task_has_file_evidence "$BASE_BRANCH" "${files[@]}"; then
			verified_completed=$((verified_completed + 1))
		fi
	done < <(jq -r '(.tasks // [])[] | [.id, .status] | @tsv' "$STATUS_FILE")

	[ "$verified_completed" -eq 3 ]

	# Replay the orchestrator's PARTIAL-COMPLETION GATE (issue #577) using the
	# branch-verified count in place of the raw stage-status count.
	if (( verified_completed < task_count )); then
		DEGRADED_STAGES+=("implement:partial:${verified_completed}/${task_count}")
		jq --arg reason "Partial implementation: ${verified_completed}/${task_count} tasks completed (implement:partial:${verified_completed}/${task_count})." \
			'.merge_blocked_reason = (.merge_blocked_reason // $reason)' \
			"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
	fi

	local gate_result blocked_reason block_kind
	gate_result=$(_run_merge_gate)
	blocked_reason="${gate_result%%$'\x1e'*}"
	block_kind="${gate_result#*$'\x1e'}"

	[ -z "$blocked_reason" ]
	[ -z "$block_kind" ]
	[ ${#DEGRADED_STAGES[@]} -eq 0 ]
}

@test "sanity: #616's raw stage status (no branch-evidence re-evaluation) does block" {
	# Same task roster/statuses as the regression test above but WITHOUT the
	# branch-evidence re-evaluation step — i.e. today's (pre-fix) behaviour.
	# Proves the gate mirror actually discriminates blocked vs not-blocked
	# rather than trivially passing regardless of input.
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "resolve_consumer_file()", status: "completed"},
		{id: 2, description: "wire platform.sh via resolver", status: "failed"},
		{id: 3, description: "bats coverage", status: "failed"}
	]')
	set_tasks "$tasks_json"

	local task_count completed_tasks
	task_count=$(jq '(.tasks // []) | length' "$STATUS_FILE")
	completed_tasks=$(jq '[(.tasks // [])[] | select(.status == "completed")] | length' "$STATUS_FILE")

	if (( completed_tasks < task_count )); then
		DEGRADED_STAGES+=("implement:partial:${completed_tasks}/${task_count}")
		jq --arg reason "Partial implementation: ${completed_tasks}/${task_count} tasks completed (implement:partial:${completed_tasks}/${task_count})." \
			'.merge_blocked_reason = (.merge_blocked_reason // $reason)' \
			"$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
	fi

	local gate_result blocked_reason
	gate_result=$(_run_merge_gate)
	blocked_reason="${gate_result%%$'\x1e'*}"

	[ -n "$blocked_reason" ]
	[[ "$blocked_reason" == "Partial implementation:"* ]]
}

# =============================================================================
# DRIFT GUARD: keep _run_merge_gate() (above) in lockstep with the real
# orchestrator so this regression test cannot silently decouple from the
# code it is meant to exercise.
# =============================================================================

@test "drift guard: Gate B fallback scan for implement:partial:* is unchanged in the orchestrator" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'if [[ "$_dsp" == implement:partial:* ]]; then'* ]]
	[[ "$script_content" == *'merge_blocked_reason="Partial implementation — not all tasks completed (degraded_stages: $_dsp)."'* ]]
}

@test "drift guard: PARTIAL-COMPLETION GATE persisted-reason format is unchanged in the orchestrator" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'DEGRADED_STAGES+=("implement:partial:${completed_tasks}/${task_count}")'* ]]
	[[ "$script_content" == *'"Partial implementation: ${completed_tasks}/${task_count} tasks completed (implement:partial:${completed_tasks}/${task_count})."'* ]]
}
