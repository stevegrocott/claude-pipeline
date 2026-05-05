#!/usr/bin/env bats
#
# tests/retry-policy-golden.bats
# Golden fixture tests for the retry-policy bash decision tree.
#
# Loads JSON fixtures from tests/fixtures/retry-policy/ and drives
# decide-retry.sh with RETRY_POLICY_BACKEND=bash, which exercises the
# inline _bash_retry_decide() tree without any live Claude invocations.
# Each test pins one of the three routing actions.
#
# Decision paths under test:
#   retry      rate_limit on first attempt → retry with backoff_ms
#   escalate   timeout at retry limit → escalate to next model tier
#   bail       permission_denied → unrecoverable, terminate stage
#
# Requires: bats >= 1.5.0, jq
#

# `run --separate-stderr` needs bats 1.5+.
bats_require_minimum_version 1.5.0

# Resolve paths once at load time so tests are CWD-independent.
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
DECIDE_RETRY_SCRIPT="$REPO_ROOT/.claude/scripts/decide-retry.sh"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures/retry-policy"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Load a fixture file by basename (without .json extension).
# Prints the file contents on stdout; fails the test if missing.
_load_fixture() {
	local name="$1"
	local fixture_file="$FIXTURES_DIR/${name}.json"
	if [[ ! -f "$fixture_file" ]]; then
		printf 'FAIL: fixture not found: %s\n' "$fixture_file" >&2
		return 1
	fi
	cat "$fixture_file"
}

# A canonical empty error history (no prior errors at this tier).
_history_empty() {
	printf '%s' '[]'
}

# Assert the .action field in $output equals EXPECTED.
# Prints a diagnostic and returns 1 on mismatch.
_assert_action() {
	local expected="$1"
	local got
	got=$(printf '%s' "$output" | jq -r '.action' 2>/dev/null)
	if [[ "$got" != "$expected" ]]; then
		printf 'FAIL: expected action=%s, got=%s\n' \
			"$expected" "$got" >&2
		printf 'Full stdout: %s\n' "$output" >&2
		return 1
	fi
}

# Assert the .reason field in $output is a non-empty, non-null string.
_assert_reason_present() {
	local reason
	reason=$(printf '%s' "$output" | jq -r '.reason' 2>/dev/null)
	if [[ -z "$reason" || "$reason" == "null" ]]; then
		printf 'FAIL: expected non-empty reason, got: %s\n' \
			"$reason" >&2
		return 1
	fi
}

# Assert the .backoff_ms field in $output is a positive integer.
_assert_backoff_ms_present() {
	local backoff
	backoff=$(printf '%s' "$output" | jq -r '.backoff_ms' 2>/dev/null)
	if [[ -z "$backoff" || "$backoff" == "null" ]]; then
		printf 'FAIL: expected backoff_ms, got: %s\n' "$backoff" >&2
		return 1
	fi
	if ! ((backoff > 0)); then
		printf 'FAIL: expected backoff_ms > 0, got: %s\n' "$backoff" >&2
		return 1
	fi
}

# ===========================================================================
# retry — rate_limit on first attempt retries the same model with back-off
# ===========================================================================

@test "retry: rate_limit first attempt produces retry action with backoff_ms" {
	[[ -x "$DECIDE_RETRY_SCRIPT" ]] \
		|| fail "decide-retry.sh not present or not executable"

	local stage_result history
	stage_result=$(_load_fixture "retry-under-limit")
	history=$(_history_empty)

	RETRY_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_RETRY_SCRIPT" "$stage_result" "0" "$history"

	[ "$status" -eq 0 ]
	_assert_action "retry"
	_assert_reason_present
	_assert_backoff_ms_present
}

# ===========================================================================
# escalate — timeout at retry limit escalates to next model tier
# ===========================================================================

@test "escalate: timeout at retry limit escalates from haiku to sonnet" {
	[[ -x "$DECIDE_RETRY_SCRIPT" ]] \
		|| fail "decide-retry.sh not present or not executable"

	local stage_result history
	stage_result=$(_load_fixture "at-limit-escalate")
	history=$(_history_empty)

	# retry_count=1 meets max_retries=1 for timeout → escalate
	RETRY_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_RETRY_SCRIPT" "$stage_result" "1" "$history"

	[ "$status" -eq 0 ]
	_assert_action "escalate"
	_assert_reason_present
}

# ===========================================================================
# bail — permission_denied is never retryable
# ===========================================================================

@test "bail: permission_denied fixture produces bail action" {
	[[ -x "$DECIDE_RETRY_SCRIPT" ]] \
		|| fail "decide-retry.sh not present or not executable"

	local stage_result history
	stage_result=$(_load_fixture "unretryable-bail")
	history=$(_history_empty)

	RETRY_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_RETRY_SCRIPT" "$stage_result" "0" "$history"

	[ "$status" -eq 0 ]
	_assert_action "bail"
	_assert_reason_present
}
