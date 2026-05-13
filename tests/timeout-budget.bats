#!/usr/bin/env bats
#
# tests/timeout-budget.bats
# Verifies that per-iteration timeouts stay within their enclosing budgets so
# the PR-review and test loops each always get at least one full iteration.
#
# Three contract points exercised here:
#
#   (1) get_stage_timeout("pr-review-iter-*") >= get_pr_review_config().timeout
#       for a 200+ line diff — the enclosing stage timeout covers a full review
#       session (no premature kill before one pass completes).
#
#   (2) MAX_TASK_WALL_TIME_SECS default (1800) >= get_stage_timeout("test-iter-*")
#       (900) — the task wall-time budget allows at least one complete test
#       iteration before the wall-clock guard fires.
#
#   (3) MAX_PR_REVIEW_ITERATIONS and MAX_TEST_ITERATIONS environment variables
#       are honoured over their in-source defaults — callers that export these
#       variables get the expected iteration counts, not the baked-in fallbacks.
#
# Functions extracted from implement-issue-orchestrator.sh via awk range
# patterns (same technique used by event-emission.bats and
# agent-name-normalization.bats).  No live Claude invocations; all git calls
# are replaced by the get_diff_line_count mock defined in _setup_funcs().
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
ORCHESTRATOR="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	# Empty LOG_FILE: log/log_warn write only to stderr, no file I/O needed.
	export LOG_FILE=""
	# BASE_BRANCH is referenced inside get_pr_review_config() when it calls
	# get_diff_line_count; the mock ignores the argument, so any value is fine.
	export BASE_BRANCH="main"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Source timeout-related functions and their governing variable defaults from
# the orchestrator.  Callers may pre-set MAX_* variables before invoking this
# function; the ${:-N} expansion in the sourced file will leave pre-set values
# unchanged (that is exactly the env-override behaviour under test).
#
# Functions extracted:
#   get_stage_timeout
#   get_pr_review_config
#   apply_profile_to_pr_review_max_iter
#   apply_profile_to_test_max_iter
#
# Variables extracted (using ${:-default} form to allow env overrides):
#   MAX_TEST_ITERATIONS
#   MAX_PR_REVIEW_ITERATIONS
#   MAX_ORCHESTRATOR_WALL_TIME
#   MAX_TASK_WALL_TIME_SECS
_source_timeout_functions() {
	local func_file="$TEST_TMP/timeout_funcs.bash"
	# Stub log_warn so check_test_loop_wall_timeout can call it without
	# the full orchestrator environment.
	printf '%s\n' \
		'log_warn() { printf "[WARN] %s\n" "$*" >&2; }' \
		> "$func_file"
	awk '
		/^readonly / { next }
		/^set -o /   { next }
		/^MAX_TEST_ITERATIONS=/           { print; next }
		/^MAX_PR_REVIEW_ITERATIONS=/      { print; next }
		/^MAX_ORCHESTRATOR_WALL_TIME=/    { print; next }
		/^MAX_TASK_WALL_TIME_SECS=/       { print; next }
		/^TEST_LOOP_PLANNED_ITERATIONS=/  { print; next }
		/^TEST_ITER_WALL_TIME_SLACK=/     { print; next }
		/^TEST_LOOP_WALL_BUDGET=/         { print; next }
		/^PR_REVIEW_WALL_TIME_SLACK=/     { print; next }
		/^PR_REVIEW_WALL_BUDGET=/         { print; next }
		/^get_stage_timeout\(\) \{$/,/^\}$/                      { print; next }
		/^get_pr_review_config\(\) \{$/,/^\}$/                   { print; next }
		/^apply_profile_to_pr_review_max_iter\(\) \{$/,/^\}$/   { print; next }
		/^apply_profile_to_test_max_iter\(\) \{$/,/^\}$/         { print; next }
		/^calc_test_loop_budget\(\) \{$/,/^\}$/                  { print; next }
		/^calc_orchestrator_wall_time\(\) \{$/,/^\}$/            { print; next }
		/^check_test_loop_wall_timeout\(\) \{$/,/^\}$/           { print; next }
	' "$ORCHESTRATOR" >> "$func_file"
	# shellcheck disable=SC1090
	source "$func_file"
}

# Override get_diff_line_count so get_pr_review_config() never touches git.
# Must be called AFTER _source_timeout_functions so the override sticks.
# Stores the desired line count in _MOCK_DIFF_LINES and installs a shim that
# reads it on each call — avoids eval and lets callers re-mock by just
# reassigning the variable.
_mock_diff_count() {
	_MOCK_DIFF_LINES="${1:-200}"
	get_diff_line_count() { printf '%s' "$_MOCK_DIFF_LINES"; }
}

# =============================================================================
# (1) PR-review stage timeout >= large-diff pr_review_timeout
# =============================================================================

@test "(1a) get_stage_timeout pr-review-iter returns 1800" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	_source_timeout_functions

	local timeout
	timeout=$(get_stage_timeout "pr-review-iter-1" "")

	[[ "$timeout" -eq 1800 ]] || {
		printf 'FAIL: expected 1800, got %s\n' "$timeout" >&2
		return 1
	}
}

@test "(1b) get_pr_review_config returns 1200s timeout for a 200+ line diff" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	_source_timeout_functions
	_mock_diff_count 200

	local config pr_timeout
	config=$(get_pr_review_config)
	pr_timeout=$(printf '%s' "$config" | jq -r '.timeout')

	[[ "$pr_timeout" -eq 1200 ]] || {
		printf 'FAIL: expected timeout=1200, got %s\n' "$pr_timeout" >&2
		return 1
	}
}

@test "(1c) get_stage_timeout pr-review-iter >= get_pr_review_config timeout for 200+ line diff" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	_source_timeout_functions
	_mock_diff_count 250

	local stage_timeout pr_config pr_timeout
	stage_timeout=$(get_stage_timeout "pr-review-iter-1" "")
	pr_config=$(get_pr_review_config)
	pr_timeout=$(printf '%s' "$pr_config" | jq -r '.timeout')

	(( stage_timeout >= pr_timeout )) || {
		printf \
			'FAIL: stage timeout %ds < pr_review_timeout %ds — loop may kill a running review\n' \
			"$stage_timeout" "$pr_timeout" >&2
		return 1
	}
}

# =============================================================================
# (2) Test loop: task wall-time budget >= one test-iter stage timeout
# =============================================================================

@test "(2a) get_stage_timeout test-iter returns 900" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	_source_timeout_functions

	local timeout
	timeout=$(get_stage_timeout "test-iter-1" "")

	[[ "$timeout" -eq 900 ]] || {
		printf 'FAIL: expected 900, got %s\n' "$timeout" >&2
		return 1
	}
}

@test "(2b) default MAX_TASK_WALL_TIME_SECS >= test-iter stage timeout" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	# Unset so the ${:-1800} default takes effect when we source.
	unset MAX_TASK_WALL_TIME_SECS

	_source_timeout_functions

	local test_iter_timeout
	test_iter_timeout=$(get_stage_timeout "test-iter-1" "")

	(( MAX_TASK_WALL_TIME_SECS >= test_iter_timeout )) || {
		printf \
			'FAIL: MAX_TASK_WALL_TIME_SECS=%d < test-iter timeout=%d — wall guard fires before first iteration\n' \
			"$MAX_TASK_WALL_TIME_SECS" "$test_iter_timeout" >&2
		return 1
	}
}

# =============================================================================
# (3) Env overrides
# =============================================================================

@test "(3a) MAX_PR_REVIEW_ITERATIONS env override flows into get_pr_review_config for 200+ line diff" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	# Pre-set before sourcing; ${:-2} in the sourced file must NOT overwrite it.
	MAX_PR_REVIEW_ITERATIONS=3
	_source_timeout_functions
	_mock_diff_count 200

	local config max_iter
	config=$(get_pr_review_config)
	max_iter=$(printf '%s' "$config" | jq -r '.max_iterations')

	[[ "$max_iter" -eq 3 ]] || {
		printf \
			'FAIL: expected max_iterations=3 from env override, got %s\n' \
			"$max_iter" >&2
		return 1
	}
}

@test "(3b) MAX_PR_REVIEW_ITERATIONS env override: default 2 is used when unset" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset MAX_PR_REVIEW_ITERATIONS
	_source_timeout_functions
	_mock_diff_count 200

	local config max_iter
	config=$(get_pr_review_config)
	max_iter=$(printf '%s' "$config" | jq -r '.max_iterations')

	[[ "$max_iter" -eq 2 ]] || {
		printf \
			'FAIL: expected default max_iterations=2 when unset, got %s\n' \
			"$max_iter" >&2
		return 1
	}
}

@test "(3c) MAX_TEST_ITERATIONS env override is preserved after orchestrator variable init" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	# Pre-set before sourcing; ${:-7} in the sourced file must NOT overwrite it.
	MAX_TEST_ITERATIONS=5
	_source_timeout_functions

	[[ "$MAX_TEST_ITERATIONS" -eq 5 ]] || {
		printf \
			'FAIL: expected MAX_TEST_ITERATIONS=5 to survive orchestrator init, got %s\n' \
			"$MAX_TEST_ITERATIONS" >&2
		return 1
	}
}

@test "(3d) MAX_TEST_ITERATIONS env override flows into apply_profile_to_test_max_iter" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	MAX_TEST_ITERATIONS=5
	_source_timeout_functions

	local result
	# Simulates the orchestrator test-loop call:
	#   apply_profile_to_test_max_iter "$loop_profile" "$MAX_TEST_ITERATIONS"
	result=$(apply_profile_to_test_max_iter "standard" "$MAX_TEST_ITERATIONS")

	[[ "$result" -eq 5 ]] || {
		printf \
			'FAIL: expected apply_profile_to_test_max_iter to return 5, got %s\n' \
			"$result" >&2
		return 1
	}
}

@test "(3e) MAX_TEST_ITERATIONS default 7 is used when unset" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset MAX_TEST_ITERATIONS
	_source_timeout_functions

	[[ "$MAX_TEST_ITERATIONS" -eq 7 ]] || {
		printf \
			'FAIL: expected default MAX_TEST_ITERATIONS=7 when unset, got %s\n' \
			"$MAX_TEST_ITERATIONS" >&2
		return 1
	}
}

# =============================================================================
# (4) Test loop wall-clock budget
# =============================================================================
#
# Contract:
#   calc_test_loop_budget() returns
#     test-iter-timeout × max(TEST_LOOP_PLANNED_ITERATIONS, 1)
#       + TEST_ITER_WALL_TIME_SLACK
#   unless TEST_LOOP_WALL_BUDGET is set, in which case it returns that value.
#
#   check_test_loop_wall_timeout(start, budget) returns 0 when elapsed <=
#   budget and 1 when elapsed > budget.
#
#   The computed default budget >= one test-iter stage timeout so the loop
#   always gets at least one full iteration.
# =============================================================================

@test "(4a) TEST_LOOP_PLANNED_ITERATIONS default is 3 when unset" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset TEST_LOOP_PLANNED_ITERATIONS
	_source_timeout_functions

	[[ "$TEST_LOOP_PLANNED_ITERATIONS" -eq 3 ]] || {
		printf \
			'FAIL: expected default TEST_LOOP_PLANNED_ITERATIONS=3, got %s\n' \
			"$TEST_LOOP_PLANNED_ITERATIONS" >&2
		return 1
	}
}

@test "(4b) TEST_LOOP_PLANNED_ITERATIONS env override survives orchestrator init" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	TEST_LOOP_PLANNED_ITERATIONS=2
	_source_timeout_functions

	[[ "$TEST_LOOP_PLANNED_ITERATIONS" -eq 2 ]] || {
		printf \
			'FAIL: expected TEST_LOOP_PLANNED_ITERATIONS=2 to survive init, got %s\n' \
			"$TEST_LOOP_PLANNED_ITERATIONS" >&2
		return 1
	}
}

@test "(4c) TEST_ITER_WALL_TIME_SLACK default is 120 when unset" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset TEST_ITER_WALL_TIME_SLACK
	_source_timeout_functions

	[[ "$TEST_ITER_WALL_TIME_SLACK" -eq 120 ]] || {
		printf \
			'FAIL: expected default TEST_ITER_WALL_TIME_SLACK=120, got %s\n' \
			"$TEST_ITER_WALL_TIME_SLACK" >&2
		return 1
	}
}

@test "(4d) TEST_ITER_WALL_TIME_SLACK env override survives orchestrator init" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	TEST_ITER_WALL_TIME_SLACK=60
	_source_timeout_functions

	[[ "$TEST_ITER_WALL_TIME_SLACK" -eq 60 ]] || {
		printf \
			'FAIL: expected TEST_ITER_WALL_TIME_SLACK=60 to survive init, got %s\n' \
			"$TEST_ITER_WALL_TIME_SLACK" >&2
		return 1
	}
}

@test "(4e) calc_test_loop_budget uses formula: iter_timeout × planned_iter + slack" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset TEST_LOOP_WALL_BUDGET
	TEST_LOOP_PLANNED_ITERATIONS=3
	TEST_ITER_WALL_TIME_SLACK=120
	_source_timeout_functions

	local test_iter_timeout budget expected
	test_iter_timeout=$(get_stage_timeout "test-iter-1" "")
	expected=$(( test_iter_timeout * 3 + 120 ))

	budget=$(calc_test_loop_budget)

	[[ "$budget" -eq "$expected" ]] || {
		printf \
			'FAIL: expected budget=%d (%dx3+120), got %s\n' \
			"$expected" "$test_iter_timeout" "$budget" >&2
		return 1
	}
}

@test "(4f) TEST_LOOP_WALL_BUDGET env override bypasses the formula" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	TEST_LOOP_WALL_BUDGET=9999
	_source_timeout_functions

	local budget
	budget=$(calc_test_loop_budget)

	[[ "$budget" -eq 9999 ]] || {
		printf \
			'FAIL: expected budget=9999 from env override, got %s\n' \
			"$budget" >&2
		return 1
	}
}

@test "(4g) check_test_loop_wall_timeout returns 0 when within budget" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	_source_timeout_functions

	local start budget
	start=$(date +%s)
	budget=3600

	check_test_loop_wall_timeout "$start" "$budget" || {
		printf 'FAIL: expected 0 (within budget), got 1\n' >&2
		return 1
	}
}

@test "(4h) check_test_loop_wall_timeout returns 1 when budget exceeded" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	_source_timeout_functions

	# Start 100s in the past; budget is only 50s.
	local start budget
	start=$(( $(date +%s) - 100 ))
	budget=50

	! check_test_loop_wall_timeout "$start" "$budget" || {
		printf 'FAIL: expected 1 (budget exceeded), got 0\n' >&2
		return 1
	}
}

@test "(4i) default test loop budget >= one test-iter stage timeout" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset TEST_LOOP_WALL_BUDGET
	unset TEST_LOOP_PLANNED_ITERATIONS
	unset TEST_ITER_WALL_TIME_SLACK
	_source_timeout_functions

	local budget test_iter_timeout
	budget=$(calc_test_loop_budget)
	test_iter_timeout=$(get_stage_timeout "test-iter-1" "")

	(( budget >= test_iter_timeout )) || {
		printf \
			'FAIL: default budget %ds < test-iter timeout %ds\n' \
			"$budget" "$test_iter_timeout" >&2
		return 1
	}
}

@test "(4j) TEST_LOOP_PLANNED_ITERATIONS=1 still yields at least one iter budget" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset TEST_LOOP_WALL_BUDGET
	TEST_LOOP_PLANNED_ITERATIONS=1
	TEST_ITER_WALL_TIME_SLACK=0
	_source_timeout_functions

	local budget test_iter_timeout
	budget=$(calc_test_loop_budget)
	test_iter_timeout=$(get_stage_timeout "test-iter-1" "")

	(( budget >= test_iter_timeout )) || {
		printf \
			'FAIL: planned=1 budget %ds < test-iter timeout %ds\n' \
			"$budget" "$test_iter_timeout" >&2
		return 1
	}
}

# =============================================================================
# (5) Orchestrator wall time >= sum of phase budgets
# =============================================================================
#
# Contract:
#   calc_orchestrator_wall_time() returns a value >= the sum of:
#     test-loop budget (from calc_test_loop_budget) +
#     pr-review budget (worst-case: 1200s × max_iter + slack)
#
#   The default MAX_ORCHESTRATOR_WALL_TIME >= calc_orchestrator_wall_time()
#   so the global clock never fires while an inner loop is within its own
#   budget.
#
#   PR_REVIEW_WALL_BUDGET override is honoured in the sum.
# =============================================================================

@test "(5a) calc_orchestrator_wall_time >= test-loop + worst-case pr-review" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset PR_REVIEW_WALL_BUDGET TEST_LOOP_WALL_BUDGET
	MAX_PR_REVIEW_ITERATIONS=2
	PR_REVIEW_WALL_TIME_SLACK=120
	TEST_LOOP_PLANNED_ITERATIONS=3
	TEST_ITER_WALL_TIME_SLACK=120
	_source_timeout_functions

	local budget test_budget pr_budget pr_iter
	budget=$(calc_orchestrator_wall_time)
	test_budget=$(calc_test_loop_budget)
	pr_iter=$(( MAX_PR_REVIEW_ITERATIONS > 1 ? MAX_PR_REVIEW_ITERATIONS : 1 ))
	pr_budget=$(( 1200 * pr_iter + PR_REVIEW_WALL_TIME_SLACK ))

	(( budget >= test_budget + pr_budget )) || {
		printf \
			'FAIL: orchestrator budget %ds < test(%ds) + pr-review(%ds)\n' \
			"$budget" "$test_budget" "$pr_budget" >&2
		return 1
	}
}

@test "(5b) default MAX_ORCHESTRATOR_WALL_TIME >= calc_orchestrator_wall_time()" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset MAX_ORCHESTRATOR_WALL_TIME
	unset PR_REVIEW_WALL_BUDGET TEST_LOOP_WALL_BUDGET
	_source_timeout_functions

	local phase_sum
	phase_sum=$(calc_orchestrator_wall_time)

	(( MAX_ORCHESTRATOR_WALL_TIME >= phase_sum )) || {
		printf \
			'FAIL: default MAX_ORCHESTRATOR_WALL_TIME=%ds < phase sum=%ds\n' \
			"$MAX_ORCHESTRATOR_WALL_TIME" "$phase_sum" >&2
		return 1
	}
}

@test "(5c) calc_orchestrator_wall_time respects PR_REVIEW_WALL_BUDGET override" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	PR_REVIEW_WALL_BUDGET=9999
	unset TEST_LOOP_WALL_BUDGET
	TEST_LOOP_PLANNED_ITERATIONS=3
	TEST_ITER_WALL_TIME_SLACK=120
	_source_timeout_functions

	local budget test_budget expected
	budget=$(calc_orchestrator_wall_time)
	test_budget=$(calc_test_loop_budget)
	expected=$(( test_budget + 9999 + 5700 ))

	[[ "$budget" -eq "$expected" ]] || {
		printf \
			'FAIL: expected %ds (test %ds + pr override 9999 + overhead 5700), got %ds\n' \
			"$expected" "$test_budget" "$budget" >&2
		return 1
	}
}

@test "(5d) calc_orchestrator_wall_time default value is 11040" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "orchestrator not present: $ORCHESTRATOR"

	unset PR_REVIEW_WALL_BUDGET TEST_LOOP_WALL_BUDGET
	unset TEST_LOOP_PLANNED_ITERATIONS TEST_ITER_WALL_TIME_SLACK
	unset MAX_PR_REVIEW_ITERATIONS PR_REVIEW_WALL_TIME_SLACK
	_source_timeout_functions

	local budget
	budget=$(calc_orchestrator_wall_time)

	# Default: test-loop(900×3+120=2820) + pr-review(1200×2+120=2520)
	#          + overhead(5700) = 11040
	[[ "$budget" -eq 11040 ]] || {
		printf \
			'FAIL: expected default budget=11040, got %s\n' \
			"$budget" >&2
		return 1
	}
}
