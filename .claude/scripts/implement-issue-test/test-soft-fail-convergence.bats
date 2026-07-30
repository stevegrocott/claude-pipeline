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
	# platform.sh sets MAX_ORCHESTRATOR_WALL_TIME=10800 (3h) before the
	# orchestrator's own ${VAR:-14640} default runs, so the orchestrator
	# default is a no-op and the effective runtime value is platform's 10800.
	[ "$MAX_ORCHESTRATOR_WALL_TIME" -eq 10800 ]
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
	[[ "$script_content" == *'MAX_ORCHESTRATOR_WALL_TIME="${MAX_ORCHESTRATOR_WALL_TIME:-14640}"'* ]]
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
# NO MID-LOOP HARD EXIT (soft-fail replaces hard exit)
#
# Historically the quality/test/pr loops hard-failed with `exit 2` when they
# exceeded their iteration budget; that was replaced with the soft-fail pattern
# (break + DEGRADED_STAGES) so the pipeline continues to PR/merge reporting.
# Issue #577 reintroduces a TERMINAL `exit 2` at the merge gate for the
# completed_partial state (after the PR exists) — a distinct non-zero exit so
# batch metrics and operators can tell a partial delivery from an error or a
# full success.  Issue #583/#590 adds a SECOND terminal `exit 2` in the
# parent-shell budget guard (_halt_if_budget_exceeded → set_final_state
# "budget_exceeded"; exit 2), which halts the whole run when the token/cost
# ceiling is breached — again a run-halt, not a mid-loop hard-fail.  These
# tests guard the original invariant (loops soft-fail) while permitting those
# two terminal exits, and only those two.
# =============================================================================

@test "every exit 2 is a terminal run-halt (completed_partial or budget_exceeded)" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Exactly two line-terminal `exit 2` sites may remain — the completed_partial
	# merge gate (#577) and the budget_exceeded run halt (#583/#590).
	local exit2_count
	exit2_count=$(grep -c 'exit 2$' "$ORCHESTRATOR_SCRIPT" || true)
	[ "$exit2_count" -eq 2 ]

	# Each terminal state's set_final_state must be immediately followed by an
	# `exit 2` (its next exit is exit 2), i.e. both exits are terminal run-halts
	# and neither is a mid-loop hard-fail.  Two accounted-for terminal exits +
	# a total count of exactly two ⇒ no unaccounted mid-loop exit 2 remains.
	local partial_pos budget_pos next_exit

	partial_pos=$(grep -n 'set_final_state "completed_partial"' <<< "$script_content" \
		| tail -1 | cut -d: -f1)
	next_exit=$(awk "NR>$partial_pos && /exit [0-9]/{ print; exit }" <<< "$script_content")
	[[ "$next_exit" == *'exit 2'* ]]

	budget_pos=$(grep -n 'set_final_state "budget_exceeded"' <<< "$script_content" \
		| tail -1 | cut -d: -f1)
	next_exit=$(awk "NR>$budget_pos && /exit [0-9]/{ print; exit }" <<< "$script_content")
	[[ "$next_exit" == *'exit 2'* ]]
}

@test "orchestrator uses soft-fail pattern in loops (not a mid-loop exit 2)" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Soft-fail means the quality/test/pr loops break and add to DEGRADED_STAGES
	# rather than hard-exiting.
	[[ "$script_content" == *"DEGRADED_STAGES"* ]]
	[[ "$script_content" == *'DEGRADED_STAGES+=("quality:max_iterations:'* ]]
	[[ "$script_content" == *'DEGRADED_STAGES+=("quality:convergence_failure:'* ]]

	# No more than the two terminal run-halt exit 2 sites (completed_partial +
	# budget_exceeded) may exist; any third would be a mid-loop hard-fail.
	local exit2_count
	exit2_count=$(grep -c 'exit 2$' "$ORCHESTRATOR_SCRIPT" || true)
	[ "$exit2_count" -le 2 ]
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

# =============================================================================
# PR-CHANGED TEST FILE DETECTION ON BASH SCOPE (#636)
#
# The test loop only dispatches a fix agent for failures it believes belong to
# the PR.  Under `bash` scope changed_test_files used to be empty by
# construction, so every bats failure was reclassified "pre-existing" and the
# loop reported complete.  These tests pin the detection AND the inference:
# an empty changed_test_files may only mean "no PR-owned failures" when
# detection was actually attempted for the active scope.
# =============================================================================

# Build a throwaway git repo on `main` for run_test_loop to diff against.
_setup_test_loop_repo() {
	mkdir -p "$TEST_TMP/repo"
	cd "$TEST_TMP/repo" || return 1
	git init -q
	git config user.email "test@example.com"
	git config user.name "Test"
	git checkout -q -b main
	printf 'initial\n' > README.md
	git add README.md
	git commit -q -m "initial"
	export BASE_BRANCH=main
}

# Install a run_stage stub that fails the first test iteration with
# $1 (a JSON failures array) and passes every later iteration, recording
# fix-agent dispatch in $FIX_CALLED_FILE.
_install_failing_then_passing_run_stage() {
	local failures_json="$1"

	FIX_CALLED_FILE="$TEST_TMP/fix_called"
	TEST_ITER_FILE="$TEST_TMP/test_iters"
	export FIX_CALLED_FILE TEST_ITER_FILE
	printf 'false\n' > "$FIX_CALLED_FILE"
	printf '0\n' > "$TEST_ITER_FILE"

	STUB_FAILURES_JSON="$failures_json"
	export STUB_FAILURES_JSON

	run_stage() {
		local stage_name="$1"
		local count
		case "$stage_name" in
			test-iter-*)
				count=$(< "$TEST_ITER_FILE")
				count=$((count + 1))
				printf '%s\n' "$count" > "$TEST_ITER_FILE"
				if (( count <= 1 )); then
					printf '%s' "{\"status\":\"success\",\"output\":{\"result\":\"failed\",\"failures\":$STUB_FAILURES_JSON,\"summary\":\"failures\",\"validation_result\":\"skipped\"}}"
				else
					printf '%s' '{"status":"success","output":{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}}'
				fi
				;;
			fix-tests-*)
				printf 'true\n' > "$FIX_CALLED_FILE"
				printf '%s' '{"status":"success","output":{"summary":"Fixed"}}'
				;;
			*)
				printf '%s' '{"status":"success","output":{"summary":"noop"}}'
				;;
		esac
	}
	export -f run_stage

	comment_issue() { :; }
	export -f comment_issue
}

@test "bash scope: failure in a PR-changed .bats file dispatches the fix agent" {
	_setup_test_loop_repo
	git checkout -q -b feature-bats-red

	mkdir -p tests
	printf '@test "red" { false; }\n' > tests/new-suite.bats
	git add tests/new-suite.bats
	git commit -q -m "add failing bats suite"

	_install_failing_then_passing_run_stage \
		'[{"title":"new-suite","description":"not ok 1 red"}]'

	run_test_loop "$TEST_TMP/repo" "feature-bats-red" "" "bash"

	expect_ok "fix agent must be dispatched for a failure in a PR-changed .bats file" \
		test "$(< "$FIX_CALLED_FILE")" = "true"
	expect_not_ok "loop must not declare the failure pre-existing" \
		grep -q "All test failures are pre-existing" "$LOG_FILE"
}

@test "bash scope: failure in an untouched suite is still skipped as pre-existing" {
	_setup_test_loop_repo
	git checkout -q -b feature-bash-no-tests

	mkdir -p .claude/scripts
	printf '#!/usr/bin/env bash\ntrue\n' > .claude/scripts/helper.sh
	git add .claude/scripts/helper.sh
	git commit -q -m "shell change without touching any bats file"

	_install_failing_then_passing_run_stage \
		'[{"title":"untouched-suite","description":"not ok 1 pre-existing"}]'

	run_test_loop "$TEST_TMP/repo" "feature-bash-no-tests" "" "bash"

	expect_ok "fix agent must not be dispatched when the PR changed no .bats file" \
		test "$(< "$FIX_CALLED_FILE")" = "false"
	expect_ok "loop must log the pre-existing skip" \
		grep -q "pre-existing failure" "$LOG_FILE"
}

@test "bash scope: #631 replay — 5 failures with one in a PR-added bats file dispatch the fix agent" {
	# Replay of run issue-631-20260728-121943, which logged
	#   "No changed test files found — falling back to --changedSince=main"
	#   "Skipping 5 pre-existing failure(s)"
	#   "Test loop complete."
	# while one of the 5 was tests/marketplace-smoke.bats, added by that PR.
	_setup_test_loop_repo
	git checkout -q -b feature-631-replay

	mkdir -p tests .claude/scripts
	printf '@test "consumer" { false; }\n' > tests/marketplace-smoke.bats
	printf '#!/usr/bin/env bash\ntrue\n' > .claude/scripts/issue-body-lib.sh
	git add tests/marketplace-smoke.bats .claude/scripts/issue-body-lib.sh
	git commit -q -m "issue 631 tasks"

	_install_failing_then_passing_run_stage \
		'[{"title":"comment_issue","description":"pre-existing"},
		  {"title":"comment_pr","description":"pre-existing"},
		  {"title":"issue_num guard","description":"pre-existing"},
		  {"title":"writing-agents SKILL.md","description":"pre-existing"},
		  {"title":"bundle: issue-body-lib validates a consumer agent","description":"assert_issue_valid: unknown agent: consumer-only-agent"}]'

	run_test_loop "$TEST_TMP/repo" "feature-631-replay" "" "bash"

	expect_ok "fix agent must be dispatched when a PR-added bats suite is red" \
		test "$(< "$FIX_CALLED_FILE")" = "true"
	expect_not_ok "loop must not short-circuit as all-pre-existing" \
		grep -q "All test failures are pre-existing" "$LOG_FILE"
}

@test "pre-existing skip requires detection to have been attempted for the scope" {
	# `frontend` scope never populates changed_test_files, so an empty value
	# carries no information.  Inferring "no PR-owned failures" from emptiness
	# alone must not resurrect: failures have to reach the fix agent.
	_setup_test_loop_repo
	git checkout -q -b feature-scope-without-detection

	printf 'export const Button = () => null;\n' > Button.tsx
	git add Button.tsx
	git commit -q -m "frontend change"

	_install_failing_then_passing_run_stage \
		'[{"title":"Button","description":"render failure"}]'

	run_test_loop "$TEST_TMP/repo" "feature-scope-without-detection" "" "frontend"

	expect_ok "empty changed_test_files must not imply pre-existing when detection never ran" \
		test "$(< "$FIX_CALLED_FILE")" = "true"
}

# =============================================================================
# NARROWED BASH COMMAND ATTRIBUTION (#686)
#
# #686 narrows _build_bash_test_command to the PR-changed BATS suites instead
# of running the full 2,425-test suite every iteration. The failure-attribution
# logic above (#636) keys off changed_test_files alone, never off which
# command actually ran, so a narrowed command must be routed through that SAME
# path a full-suite run uses -- no separate "narrowed" skip branch may exist.
# _build_bash_test_command is stubbed here to stand in for the narrowed
# builder (tasks 1/2), so this pins the wiring ahead of/independent of that
# builder change: whatever command it returns must (a) reach the agent
# prompt verbatim and (b) have its reported failures dispatched to the fix
# agent with no pre-existing skip.
# =============================================================================

# Stand in for #686 tasks 1/2's narrowed builder: return a single targeted
# suite invocation instead of the full-directory glob.
#
# NOTE: the replacement command must be exported as a plain variable, not
# captured as a `local` -- a `local` goes out of scope the moment this
# function returns, so the nested function body would expand it to empty
# at call time rather than at definition time (bash has no closures).
_stub_narrowed_bash_test_command() {
	NARROWED_BASH_TEST_COMMAND="$1"
	export NARROWED_BASH_TEST_COMMAND
	_build_bash_test_command() { printf '%s\n' "$NARROWED_BASH_TEST_COMMAND"; }
	export -f _build_bash_test_command
}

# Like _install_failing_then_passing_run_stage, but also captures the
# test-iter-1 prompt (arg 2) so a test can assert the narrowed command was
# actually embedded in what the agent is told to run.
_install_failing_then_passing_run_stage_capture_prompt() {
	local failures_json="$1"

	FIX_CALLED_FILE="$TEST_TMP/fix_called"
	TEST_ITER_FILE="$TEST_TMP/test_iters"
	PROMPT_CAPTURE_FILE="$TEST_TMP/captured_prompt"
	export FIX_CALLED_FILE TEST_ITER_FILE PROMPT_CAPTURE_FILE
	printf 'false\n' > "$FIX_CALLED_FILE"
	printf '0\n' > "$TEST_ITER_FILE"
	: > "$PROMPT_CAPTURE_FILE"

	STUB_FAILURES_JSON="$failures_json"
	export STUB_FAILURES_JSON

	run_stage() {
		local stage_name="$1"
		local prompt="$2"
		local count
		case "$stage_name" in
			test-iter-*)
				count=$(< "$TEST_ITER_FILE")
				count=$((count + 1))
				printf '%s\n' "$count" > "$TEST_ITER_FILE"
				if (( count <= 1 )); then
					printf '%s' "$prompt" > "$PROMPT_CAPTURE_FILE"
					printf '%s' "{\"status\":\"success\",\"output\":{\"result\":\"failed\",\"failures\":$STUB_FAILURES_JSON,\"summary\":\"failures\",\"validation_result\":\"skipped\"}}"
				else
					printf '%s' '{"status":"success","output":{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}}'
				fi
				;;
			fix-tests-*)
				printf 'true\n' > "$FIX_CALLED_FILE"
				printf '%s' '{"status":"success","output":{"summary":"Fixed"}}'
				;;
			*)
				printf '%s' '{"status":"success","output":{"summary":"noop"}}'
				;;
		esac
	}
	export -f run_stage

	comment_issue() { :; }
	export -f comment_issue
}

@test "narrowed bash command: failure from a targeted suite is attributed to the PR, not skipped as pre-existing" {
	_setup_test_loop_repo
	git checkout -q -b feature-narrowed-bats

	mkdir -p tests
	printf '@test "red" { false; }\n' > tests/new-suite.bats
	git add tests/new-suite.bats
	git commit -q -m "add failing bats suite"

	_stub_narrowed_bash_test_command "bash run-tests.sh new-suite.bats && bats tests/new-suite.bats"
	_install_failing_then_passing_run_stage_capture_prompt \
		'[{"title":"new-suite","description":"not ok 1 red"}]'

	run_test_loop "$TEST_TMP/repo" "feature-narrowed-bats" "" "bash"

	expect_ok "the narrowed command must reach the agent verbatim" \
		grep -qF "bash run-tests.sh new-suite.bats && bats tests/new-suite.bats" \
			"$PROMPT_CAPTURE_FILE"
	expect_ok "fix agent must be dispatched for a failure surfaced by the narrowed command" \
		test "$(< "$FIX_CALLED_FILE")" = "true"
	expect_not_ok "no pre-existing skip path may fire for a narrowed-command failure" \
		grep -q "pre-existing failure" "$LOG_FILE"
	expect_not_ok "no pre-existing skip path may fire for a narrowed-command failure" \
		grep -q "All test failures are pre-existing" "$LOG_FILE"
}
