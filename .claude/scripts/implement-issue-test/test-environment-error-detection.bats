#!/usr/bin/env bats
#
# test-environment-error-detection.bats
# Tests for all_failures_environment_related()
#
# Verifies that the function:
#   - Returns 0 (true)  when every failure is environment-related
#   - Returns 1 (false) when any failure is code-level
#   - Returns 1 (false) for an empty failures array
#   - Matches all documented environment patterns case-insensitively
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env
	install_mocks

	export ISSUE_NUMBER=123
	export BASE_BRANCH=main
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0
	export SCHEMA_DIR="$TEST_TMP/schemas"

	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

	source_orchestrator_functions
	init_status
}

teardown() {
	teardown_test_env
}

# =============================================================================
# HAPPY PATH — all failures are environment-related
# =============================================================================

@test "returns 0 when single failure mentions redis" {
	local failures='[{"test":"cache.set","message":"Redis connection refused"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when single failure mentions ECONNREFUSED" {
	local failures
	failures='[{"test":"db.connect","message":"connect ECONNREFUSED 127.0.0.1:5432"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when single failure mentions connection refused (lowercase)" {
	local failures
	failures='[{"test":"service.init","message":"connection refused to postgres"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when single failure mentions HTTP 500" {
	local failures
	failures='[{"test":"route.handler","message":"Expected 200, got HTTP 500"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when single failure mentions database connection" {
	local failures
	failures='[{"test":"orm.init","message":"database connection failed"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when single failure mentions socket hang up" {
	local failures
	failures='[{"test":"http.fetch","message":"socket hang up on upstream"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when single failure mentions ETIMEDOUT" {
	local failures
	failures='[{"test":"db.query","message":"ETIMEDOUT connecting to replica"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when single failure mentions ENOTFOUND" {
	local failures
	failures='[{"test":"smtp.send","message":"ENOTFOUND mail.example.com"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when single failure mentions connect timeout" {
	local failures
	failures='[{"test":"s3.upload","message":"connect timeout after 30000ms"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when single failure mentions ECONNRESET" {
	local failures
	failures='[{"test":"api.get","message":"ECONNRESET on read"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "returns 0 when multiple failures all match environment patterns" {
	local failures
	failures='[
		{"test":"cache.set","message":"Redis connection refused"},
		{"test":"db.query","message":"ETIMEDOUT connecting to postgres"},
		{"test":"http.call","message":"Expected 200, got HTTP 500"}
	]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "matching is case-insensitive for redis" {
	local failures='[{"test":"cache","message":"REDIS connection error"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "matching is case-insensitive for http 500" {
	local failures='[{"test":"route","message":"received http 500 from upstream"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "env keyword in test name alone does not count (message-only matching)" {
	local failures
	failures='[{"test":"redis.cluster.failover","message":"unexpected cluster state"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 1 ]
}

# =============================================================================
# RETURNS FALSE — at least one code-level failure
# =============================================================================

@test "returns 1 for a pure code-level failure" {
	local failures
	failures='[{"test":"auth.validate","message":"Expected 201, got 422"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 1 ]
}

@test "returns 1 when one failure is code-level and one is environment" {
	local failures
	failures='[
		{"test":"cache.set","message":"Redis connection refused"},
		{"test":"auth.validate","message":"Expected 201, got 422"}
	]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 1 ]
}

@test "returns 1 for assertion failure unrelated to infrastructure" {
	local failures
	failures='[{"test":"sum.calculate","message":"Expected 10, got 11"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 1 ]
}

@test "returns 1 for type error failure" {
	local failures
	failures='[{"test":"parse.json","message":"TypeError: Cannot read properties of null"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 1 ]
}

@test "returns 1 for import resolution failure" {
	local failures
	failures='[{"test":"module","message":"Cannot find module ./utils"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 1 ]
}

# =============================================================================
# EDGE CASES
# =============================================================================

@test "returns 1 for empty array (no failures to classify)" {
	run all_failures_environment_related '[]'
	[ "$status" -eq 1 ]
}

@test "returns 1 when failures field is null" {
	run all_failures_environment_related 'null'
	[ "$status" -eq 1 ]
}

@test "handles failures with missing message field gracefully" {
	local failures='[{"test":"no-message-here"}]'
	# no message field — message defaults to ""; no env pattern matches
	run all_failures_environment_related "$failures"
	[ "$status" -eq 1 ]
}

@test "handles failures with missing test field gracefully" {
	local failures='[{"message":"Redis connection refused"}]'
	run all_failures_environment_related "$failures"
	[ "$status" -eq 0 ]
}

@test "handles failures with empty message and empty test gracefully" {
	local failures='[{"test":"","message":""}]'
	# neither field matches any env pattern → code-level
	run all_failures_environment_related "$failures"
	[ "$status" -eq 1 ]
}
