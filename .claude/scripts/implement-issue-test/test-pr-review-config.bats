#!/usr/bin/env bats
#
# test-pr-review-config.bats
# Tests for get_pr_review_config() four-tier diff-size routing.
#
# Boundary values under test (from the four-tier specification):
#   <20  lines  → haiku,  300s,  1 iteration  (tiny)
#   <50  lines  → haiku,  600s,  1 iteration  (small)
#   <200 lines  → sonnet, 900s,  2 iterations (medium)
#   200+ lines  → sonnet, 1800s, 2 iterations (large)
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

@test "get_pr_review_config: tiny diff (<20 lines) returns haiku/300s/1 iter" {
	# 19 is the highest value still in the <20 tier
	get_diff_line_count() { printf '%s' "19"; }
	local result
	result=$(get_pr_review_config)
	[[ "$result" == '{"model":"haiku","timeout":300,"max_iterations":1}' ]]
}

@test "get_pr_review_config: small diff (20-49 lines) returns haiku/600s/1 iter" {
	# 20 is the exact boundary entering the second tier
	get_diff_line_count() { printf '%s' "20"; }
	local result
	result=$(get_pr_review_config)
	[[ "$result" == '{"model":"haiku","timeout":600,"max_iterations":1}' ]]
}

@test "get_pr_review_config: medium diff (50-199 lines) returns sonnet/900s/2 iter" {
	# 50 is the exact boundary entering the third tier
	get_diff_line_count() { printf '%s' "50"; }
	local result
	result=$(get_pr_review_config)
	[[ "$result" == '{"model":"sonnet","timeout":900,"max_iterations":2}' ]]
}

@test "get_pr_review_config: large diff (>=200 lines) returns sonnet/1800s/2 iter" {
	# 200 is the exact boundary entering the fourth (else) tier
	get_diff_line_count() { printf '%s' "200"; }
	local result
	result=$(get_pr_review_config)
	[[ "$result" == '{"model":"sonnet","timeout":1800,"max_iterations":2}' ]]
}
