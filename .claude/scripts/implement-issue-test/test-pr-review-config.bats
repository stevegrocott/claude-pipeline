#!/usr/bin/env bats
#
# test-pr-review-config.bats
# Tests for get_pr_review_config() three-tier diff-size routing.
#
# Boundary values under test (from the three-tier specification):
#   <50  lines  → sonnet, 360s,  1 iteration                    (small)
#   <200 lines  → sonnet, 600s,  MAX_PR_REVIEW_ITERATIONS iters (medium)
#   200+ lines  → sonnet, 1200s, MAX_PR_REVIEW_ITERATIONS iters (large)
#
# MAX_PR_REVIEW_ITERATIONS defaults to 2.
#

load 'helpers/test-helper.bash'

# =============================================================================
# TEST SETUP / TEARDOWN
# =============================================================================

setup() {
	setup_test_env
	install_mocks

	export ISSUE_NUMBER=123
	export BASE_BRANCH=test
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
# get_pr_review_config() — FOUR-TIER BOUNDARY TESTS
#
# Each test overrides get_diff_line_count() to inject a controlled diff size,
# then calls get_pr_review_config() and asserts the exact JSON output.
# Boundary values chosen to hit the first value of each tier transition.
# =============================================================================

@test "get_pr_review_config: small diff (<50 lines) returns sonnet/360s/1 iter" {
	# 49 is the highest value still in the <50 tier
	get_diff_line_count() { printf '%s' "49"; }
	local result
	result=$(get_pr_review_config)
	[[ "$result" == '{"model":"sonnet","timeout":360,"max_iterations":1}' ]]
}

@test "get_pr_review_config: medium diff (50-199 lines) returns sonnet/600s/2 iter" {
	# 50 is the exact boundary entering the second tier
	get_diff_line_count() { printf '%s' "50"; }
	local result
	result=$(get_pr_review_config)
	[[ "$result" == '{"model":"sonnet","timeout":600,"max_iterations":2}' ]]
}

@test "get_pr_review_config: medium upper bound (199 lines) returns sonnet/600s/2 iter" {
	# 199 is the highest value still in the <200 tier
	get_diff_line_count() { printf '%s' "199"; }
	local result
	result=$(get_pr_review_config)
	[[ "$result" == '{"model":"sonnet","timeout":600,"max_iterations":2}' ]]
}

@test "get_pr_review_config: large diff (>=200 lines) returns sonnet/1200s/2 iter" {
	# 200 is the exact boundary entering the third (else) tier
	get_diff_line_count() { printf '%s' "200"; }
	local result
	result=$(get_pr_review_config)
	[[ "$result" == '{"model":"sonnet","timeout":1200,"max_iterations":2}' ]]
}
