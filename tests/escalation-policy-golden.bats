#!/usr/bin/env bats
#
# tests/escalation-policy-golden.bats
# Golden fixture tests for the escalation-policy bash decision tree.
#
# Loads JSON fixtures from tests/fixtures/escalation-policy/ and
# drives decide-action.sh with ESCALATION_POLICY_BACKEND=bash, which
# exercises the inline _bash_decide() tree without any live Claude
# invocations.  Each test pins one of the four routing actions.
#
# Decision paths under test:
#   accept      success + valid output + no error_kind
#   escalate    timeout on sub-ceiling model → next tier up
#   bail        permission_denied → unrecoverable, terminate stage
#   retry_same  rate_limit + no prior attempt at same model
#
# Requires: bats >= 1.5.0, jq
#

# `run --separate-stderr` needs bats 1.5+.
bats_require_minimum_version 1.5.0

# Resolve paths once at load time so tests are CWD-independent.
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
DECIDE_ACTION_SCRIPT="$REPO_ROOT/.claude/scripts/decide-action.sh"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures/escalation-policy"

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

# A canonical empty escalation history (no prior escalations).
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

# ===========================================================================
# accept — successful stage with valid output
# ===========================================================================

@test "accept: success+valid-output fixture produces accept action" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	local stage_result history
	stage_result=$(_load_fixture "accept-success")
	history=$(_history_empty)

	ESCALATION_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_ACTION_SCRIPT" "$stage_result" "$history"

	[ "$status" -eq 0 ]
	_assert_action "accept"
	_assert_reason_present
}

# ===========================================================================
# escalate — timeout on a sub-ceiling model escalates to the next tier
# ===========================================================================

@test "escalate: timeout on haiku escalates to sonnet" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	local stage_result history
	stage_result=$(_load_fixture "timeout-first-attempt")
	history=$(_history_empty)

	ESCALATION_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_ACTION_SCRIPT" "$stage_result" "$history"

	[ "$status" -eq 0 ]
	_assert_action "escalate"
	_assert_reason_present

	# escalate requires model to be set to the next tier.
	local model
	model=$(printf '%s' "$output" | jq -r '.model' 2>/dev/null)
	if [[ "$model" != "sonnet" ]]; then
		printf 'FAIL: expected model=sonnet for escalate action, got: %s\n' \
			"$model" >&2
		printf 'Full stdout: %s\n' "$output" >&2
		return 1
	fi
}

# ===========================================================================
# bail — unrecoverable error terminates the stage permanently
# ===========================================================================

@test "bail: permission_denied fixture produces bail action" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	local stage_result history
	stage_result=$(_load_fixture "bail-permission-denied")
	history=$(_history_empty)

	ESCALATION_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_ACTION_SCRIPT" "$stage_result" "$history"

	[ "$status" -eq 0 ]
	_assert_action "bail"
	_assert_reason_present
}

# ===========================================================================
# retry_same — rate_limit on first attempt retries the same model
# ===========================================================================

@test "retry_same: rate_limit+empty-history fixture produces retry_same" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	local stage_result history
	stage_result=$(_load_fixture "retry-same-rate-limit")
	history=$(_history_empty)

	ESCALATION_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_ACTION_SCRIPT" "$stage_result" "$history"

	[ "$status" -eq 0 ]
	_assert_action "retry_same"
	_assert_reason_present
}
