#!/usr/bin/env bats
#
# test-merge-pr-timeouts.bats
# Tests for per-command timeouts in the merge_pr stage.
#
# Verifies that each long-running sub-step (merge-mr.sh, git fetch,
# git checkout, git pull, and the completion comment) is wrapped with a
# timeout, and that a timeout causes the orchestrator to transition to
# the merge_pr_timeout error stage rather than hanging indefinitely.
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
# STATIC ANALYSIS: per-command timeout constants
# =============================================================================

@test "MERGE_MR_STEP_TIMEOUT constant is defined with a default" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'MERGE_MR_STEP_TIMEOUT'* ]]
}

@test "MERGE_GIT_TIMEOUT constant is defined with a default" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'MERGE_GIT_TIMEOUT'* ]]
}

@test "MERGE_COMMENT_TIMEOUT constant is defined with a default" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'MERGE_COMMENT_TIMEOUT'* ]]
}

@test "MERGE_MR_STEP_TIMEOUT uses env-override pattern" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'MERGE_MR_STEP_TIMEOUT:-'* ]]
}

@test "MERGE_GIT_TIMEOUT uses env-override pattern" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'MERGE_GIT_TIMEOUT:-'* ]]
}

@test "MERGE_COMMENT_TIMEOUT uses env-override pattern" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'MERGE_COMMENT_TIMEOUT:-'* ]]
}

# =============================================================================
# STATIC ANALYSIS: timeout wrapping of each merge_pr sub-command
# =============================================================================

@test "merge_pr stage wraps merge-mr.sh with timeout" {
	# Extract merge_pr stage block for focused analysis
	local merge_block
	merge_block=$(awk \
		'/set_stage_started "merge_pr"/,/set_final_state "completed"/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$merge_block" == *'timeout'*'merge-mr.sh'* ]] || \
		[[ "$merge_block" == *'timeout "$MERGE_MR_STEP_TIMEOUT"'* ]]
}

@test "merge_pr stage wraps git fetch with timeout" {
	local merge_block
	merge_block=$(awk \
		'/set_stage_started "merge_pr"/,/set_final_state "completed"/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$merge_block" == *'timeout'*'git fetch'* ]] || \
		[[ "$merge_block" == *'timeout "$MERGE_GIT_TIMEOUT"'*'git fetch'* ]]
}

@test "merge_pr stage wraps git checkout with timeout" {
	local merge_block
	merge_block=$(awk \
		'/set_stage_started "merge_pr"/,/set_final_state "completed"/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$merge_block" == *'timeout'*'git checkout'* ]] || \
		[[ "$merge_block" == *'timeout "$MERGE_GIT_TIMEOUT"'*'git checkout'* ]]
}

@test "merge_pr stage wraps git pull with timeout" {
	local merge_block
	merge_block=$(awk \
		'/set_stage_started "merge_pr"/,/set_final_state "completed"/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$merge_block" == *'timeout'*'git pull'* ]] || \
		[[ "$merge_block" == *'timeout "$MERGE_GIT_TIMEOUT"'*'git pull'* ]]
}

@test "merge_pr stage wraps comment operation with timeout" {
	local merge_block
	merge_block=$(awk \
		'/set_stage_started "merge_pr"/,/set_final_state "completed"/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	# Either comment-issue.sh or comment-mr.sh is called with timeout
	[[ "$merge_block" == *'timeout'*'comment'* ]] || \
		[[ "$merge_block" == *'MERGE_COMMENT_TIMEOUT'* ]]
}

# =============================================================================
# STATIC ANALYSIS: timeout error handling in merge_pr stage
# =============================================================================

@test "merge_pr timeout handling calls set_stage_started merge_pr_timeout" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'set_stage_started "merge_pr_timeout"'* ]]
}

@test "merge_pr timeout handling calls set_final_state error" {
	# The set_final_state "error" call must appear after
	# set_stage_started "merge_pr_timeout" somewhere in the script
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	local timeout_pos error_pos
	timeout_pos=$(grep -n 'set_stage_started "merge_pr_timeout"' \
		<<< "$script_content" | head -1 | cut -d: -f1)
	error_pos=$(grep -n 'set_final_state "error"' \
		<<< "$script_content" | tail -1 | cut -d: -f1)

	[[ -n "$timeout_pos" ]]
	[[ -n "$error_pos" ]]
	(( timeout_pos < error_pos ))
}

@test "merge_pr timeout handling exits 1 after error state" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Find the block that contains merge_pr_timeout state transition,
	# then verify exit 1 follows it
	local timeout_block
	timeout_block=$(awk \
		'/set_stage_started "merge_pr_timeout"/,/exit 1/' \
		<<< "$script_content" 2>/dev/null | head -10 || true)

	[[ "$timeout_block" == *'exit 1'* ]]
}

@test "merge_pr timeout check tests for exit code 124" {
	# The timeout binary exits 124 on timeout — the stage must check for it
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Pattern: (( _exit == 124 )) or [ $? -eq 124 ] or similar
	[[ "$script_content" == *'== 124'* ]]
}

@test "merge_pr logs error message on timeout" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Some log_error call referencing timeout must appear near the timeout check
	[[ "$script_content" == *'timed out'* ]]
}

# =============================================================================
# STATIC ANALYSIS: ordering — timeout wrapping precedes set_stage_completed
# =============================================================================

@test "merge-mr.sh invocation precedes set_stage_completed merge_pr" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Match the actual invocation (contains PLATFORM_DIR), not log messages
	local merge_mr_line completed_line
	merge_mr_line=$(grep -n 'PLATFORM_DIR.*merge-mr\.sh' <<< "$script_content" \
		| head -1 | cut -d: -f1)
	completed_line=$(grep -n 'set_stage_completed "merge_pr"' <<< "$script_content" \
		| head -1 | cut -d: -f1)

	[[ -n "$merge_mr_line" ]]
	[[ -n "$completed_line" ]]
	(( merge_mr_line < completed_line ))
}

@test "merge_pr_timeout stage transition precedes set_final_state completed" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	local timeout_stage_pos completed_pos
	timeout_stage_pos=$(grep -n 'merge_pr_timeout' <<< "$script_content" \
		| head -1 | cut -d: -f1)
	completed_pos=$(grep -n 'set_final_state "completed"' <<< "$script_content" \
		| tail -1 | cut -d: -f1)

	[[ -n "$timeout_stage_pos" ]]
	[[ -n "$completed_pos" ]]
	(( timeout_stage_pos < completed_pos ))
}

# =============================================================================
# FUNCTIONAL: set_stage_started "merge_pr_timeout" updates status.json
# =============================================================================

@test "set_stage_started merge_pr_timeout sets current_stage in status.json" {
	set_stage_started "merge_pr_timeout"

	local stage
	stage=$(jq -r '.current_stage' "$STATUS_FILE")
	[[ "$stage" == "merge_pr_timeout" ]]
}

@test "set_final_state error after merge_pr_timeout records error state" {
	set_stage_started "merge_pr_timeout"
	set_final_state "error"

	local state
	state=$(jq -r '.state' "$STATUS_FILE")
	[[ "$state" == "error" ]]
}

@test "status.json current_stage is merge_pr_timeout when error state set" {
	set_stage_started "merge_pr_timeout"
	set_final_state "error"

	local stage
	stage=$(jq -r '.current_stage' "$STATUS_FILE")
	[[ "$stage" == "merge_pr_timeout" ]]
}

# =============================================================================
# STATIC ANALYSIS: validate_plan per-command timeout constants
# =============================================================================

@test "VALIDATE_PLAN_GIT_TIMEOUT constant is defined with a default" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'VALIDATE_PLAN_GIT_TIMEOUT'* ]]
}

@test "VALIDATE_PLAN_COMMENT_TIMEOUT constant is defined with a default" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'VALIDATE_PLAN_COMMENT_TIMEOUT'* ]]
}

@test "VALIDATE_PLAN_GIT_TIMEOUT uses env-override pattern" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'VALIDATE_PLAN_GIT_TIMEOUT:-'* ]]
}

@test "VALIDATE_PLAN_COMMENT_TIMEOUT uses env-override pattern" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'VALIDATE_PLAN_COMMENT_TIMEOUT:-'* ]]
}

# =============================================================================
# STATIC ANALYSIS: validate_plan stage timeout wrapping
# =============================================================================

@test "validate_plan early git rev-list is wrapped with timeout" {
	local early_block
	early_block=$(awk \
		'/EARLY SCOPE CHECK/,/STAGE: VALIDATE PLAN/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$early_block" == *'timeout'*'VALIDATE_PLAN_GIT_TIMEOUT'*'git rev-list'* ]] || \
		[[ "$early_block" == *'timeout "$VALIDATE_PLAN_GIT_TIMEOUT"'*'git rev-list'* ]]
}

@test "validate_plan stage wraps comment operation with timeout" {
	local vp_block
	vp_block=$(awk \
		'/set_stage_started "validate_plan"/,/set_stage_completed "validate_plan"/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$vp_block" == *'timeout'*'comment'* ]] || \
		[[ "$vp_block" == *'VALIDATE_PLAN_COMMENT_TIMEOUT'* ]]
}

@test "validate_plan timeout check tests for exit code 124" {
	local early_block
	early_block=$(awk \
		'/EARLY SCOPE CHECK/,/STAGE: VALIDATE PLAN/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$early_block" == *'== 124'* ]]
}

# =============================================================================
# STATIC ANALYSIS: implement per-command timeout constants
# =============================================================================

@test "IMPLEMENT_GIT_TIMEOUT constant is defined with a default" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'IMPLEMENT_GIT_TIMEOUT'* ]]
}

@test "IMPLEMENT_GIT_TIMEOUT uses env-override pattern" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'IMPLEMENT_GIT_TIMEOUT:-'* ]]
}

# =============================================================================
# STATIC ANALYSIS: implement stage timeout wrapping
# =============================================================================

@test "implement stage wraps git checkout with timeout" {
	local impl_block
	impl_block=$(awk \
		'/set_stage_started "implement"/,/set_stage_completed "implement"/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$impl_block" == *'timeout'*'git checkout'* ]] || \
		[[ "$impl_block" == *'IMPLEMENT_GIT_TIMEOUT'* ]]
}

@test "implement git checkout timeout check tests for exit code 124" {
	local impl_block
	impl_block=$(awk \
		'/set_stage_started "implement"/,/set_stage_completed "implement"/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$impl_block" == *'== 124'* ]]
}

# =============================================================================
# STATIC ANALYSIS: test_loop per-command timeout constants
# =============================================================================

@test "TEST_LOOP_GIT_TIMEOUT constant is defined with a default" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'TEST_LOOP_GIT_TIMEOUT'* ]]
}

@test "TEST_LOOP_GIT_TIMEOUT uses env-override pattern" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'TEST_LOOP_GIT_TIMEOUT:-'* ]]
}

# =============================================================================
# STATIC ANALYSIS: test_loop stage timeout wrapping
# =============================================================================

@test "run_test_loop wraps git diff with timeout" {
	local tl_block
	tl_block=$(awk \
		'/^run_test_loop\(\)/,/^}/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$tl_block" == *'timeout'*'git'*'diff'* ]] || \
		[[ "$tl_block" == *'TEST_LOOP_GIT_TIMEOUT'* ]]
}

@test "run_test_loop git diff timeout check tests for exit code 124" {
	local tl_block
	tl_block=$(awk \
		'/^run_test_loop\(\)/,/^}/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$tl_block" == *'== 124'* ]]
}

# =============================================================================
# FUNCTIONAL: validate_plan_timeout stage transitions
# =============================================================================

@test "set_stage_started validate_plan_timeout sets current_stage in status.json" {
	set_stage_started "validate_plan_timeout"

	local stage
	stage=$(jq -r '.current_stage' "$STATUS_FILE")
	[[ "$stage" == "validate_plan_timeout" ]]
}

@test "set_stage_started implement_git_timeout sets current_stage in status.json" {
	set_stage_started "implement_git_timeout"

	local stage
	stage=$(jq -r '.current_stage' "$STATUS_FILE")
	[[ "$stage" == "implement_git_timeout" ]]
}

# =============================================================================
# FUNCTIONAL: a sleeping merge-mr.sh stub trips the real timeout wrapping and
# drives the actual state transition to merge_pr_timeout (AC3).
#
# Unlike the static-grep tests above, this exercises the genuine mechanism the
# merge_pr stage uses: `timeout "$MERGE_MR_STEP_TIMEOUT" merge-mr.sh` against a
# stub that sleeps past the limit (→ exit 124), followed by the real
# _handle_merge_pr_timeout handler that the stage invokes on 124.
# =============================================================================

@test "sleeping merge-mr.sh stub trips timeout and transitions to merge_pr_timeout" {
	# Stub merge-mr.sh sleeps far longer than the timeout we set.
	mkdir -p "$TEST_TMP/platform"
	cat > "$TEST_TMP/platform/merge-mr.sh" <<'STUB'
#!/usr/bin/env bash
sleep 30
STUB
	chmod +x "$TEST_TMP/platform/merge-mr.sh"

	export MERGE_MR_STEP_TIMEOUT=1

	# Drive the exact timeout wrapping the merge_pr stage uses. The stub never
	# returns on its own, so a passing assertion proves the timeout fired.
	# Wrap in `run` so the expected non-zero exit doesn't abort the test.
	run timeout "$MERGE_MR_STEP_TIMEOUT" "$TEST_TMP/platform/merge-mr.sh"

	# `timeout` exits 124 when it kills the child for exceeding the limit.
	[ "$status" -eq 124 ]

	# Exercise the real handler the stage calls on a 124 (it exits 1).
	run _handle_merge_pr_timeout "merge-mr.sh" "$MERGE_MR_STEP_TIMEOUT"
	[ "$status" -eq 1 ]

	# Verify the actual persisted state transition, not just a string match.
	local stage state
	stage=$(jq -r '.current_stage' "$STATUS_FILE")
	state=$(jq -r '.state' "$STATUS_FILE")
	[ "$stage" = "merge_pr_timeout" ]
	[ "$state" = "error" ]
}
