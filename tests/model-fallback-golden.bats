#!/usr/bin/env bats
#
# tests/model-fallback-golden.bats
# Golden fixture tests for the model-fallback bash decision tree.
#
# Loads JSON fixtures from tests/fixtures/model-fallback/ and drives
# decide-model-fallback.sh with MODEL_FALLBACK_BACKEND=bash, which
# exercises the inline _bash_model_fallback() tree without any live
# Claude invocations.  Each test pins one decision branch.
#
# Decision paths under test:
#   upgrade     timeout on haiku  → next_model=sonnet
#   upgrade     timeout on sonnet → next_model=opus
#   ceiling     error on opus     → at_ceiling=true, next_model=null
#   no-upgrade  unrecognised kind → next_model=null, at_ceiling=false
#
# Requires: bats >= 1.5.0, jq
#

# `run --separate-stderr` needs bats 1.5+.
bats_require_minimum_version 1.5.0

# Resolve paths once at load time so tests are CWD-independent.
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
DECIDE_FALLBACK_SCRIPT="$REPO_ROOT/.claude/scripts/decide-model-fallback.sh"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures/model-fallback"

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

# Assert the .next_model field in $output equals EXPECTED.
# Pass the literal string "null" to assert a JSON null.
_assert_next_model() {
	local expected="$1"
	local got
	got=$(printf '%s' "$output" | jq -r '.next_model' 2>/dev/null)
	if [[ "$got" != "$expected" ]]; then
		printf 'FAIL: expected next_model=%s, got=%s\n' \
			"$expected" "$got" >&2
		printf 'Full stdout: %s\n' "$output" >&2
		return 1
	fi
}

# Assert the .at_ceiling field in $output equals EXPECTED ("true"|"false").
_assert_at_ceiling() {
	local expected="$1"
	local got
	got=$(printf '%s' "$output" | jq -r '.at_ceiling' 2>/dev/null)
	if [[ "$got" != "$expected" ]]; then
		printf 'FAIL: expected at_ceiling=%s, got=%s\n' \
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
# upgrade — timeout on haiku produces next_model=sonnet
# ===========================================================================

@test "upgrade: timeout on haiku produces next_model=sonnet" {
	[[ -x "$DECIDE_FALLBACK_SCRIPT" ]] \
		|| fail "decide-model-fallback.sh not present or not executable"

	local stage_result
	stage_result=$(_load_fixture "haiku-timeout-upgrade")

	MODEL_FALLBACK_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_FALLBACK_SCRIPT" "$stage_result"

	[ "$status" -eq 0 ]
	_assert_next_model "sonnet"
	_assert_at_ceiling "false"
	_assert_reason_present
}

# ===========================================================================
# upgrade — timeout on sonnet produces next_model=opus
# ===========================================================================

@test "upgrade: timeout on sonnet produces next_model=opus" {
	[[ -x "$DECIDE_FALLBACK_SCRIPT" ]] \
		|| fail "decide-model-fallback.sh not present or not executable"

	local stage_result
	stage_result=$(_load_fixture "sonnet-timeout-upgrade")

	MODEL_FALLBACK_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_FALLBACK_SCRIPT" "$stage_result"

	[ "$status" -eq 0 ]
	_assert_next_model "opus"
	_assert_at_ceiling "false"
	_assert_reason_present
}

# ===========================================================================
# ceiling — error on opus produces at_ceiling=true and null next_model
# ===========================================================================

@test "ceiling: error on opus produces at_ceiling=true and null next_model" {
	[[ -x "$DECIDE_FALLBACK_SCRIPT" ]] \
		|| fail "decide-model-fallback.sh not present or not executable"

	local stage_result
	stage_result=$(_load_fixture "opus-ceiling")

	MODEL_FALLBACK_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_FALLBACK_SCRIPT" "$stage_result"

	[ "$status" -eq 0 ]
	_assert_next_model "null"
	_assert_at_ceiling "true"
	_assert_reason_present
}

# ===========================================================================
# no-upgrade — unrecognised error_kind produces null next_model
# ===========================================================================

@test "no-upgrade: unrecognised error_kind produces null next_model" {
	[[ -x "$DECIDE_FALLBACK_SCRIPT" ]] \
		|| fail "decide-model-fallback.sh not present or not executable"

	local stage_result
	stage_result=$(_load_fixture "unknown-error-no-upgrade")

	MODEL_FALLBACK_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_FALLBACK_SCRIPT" "$stage_result"

	[ "$status" -eq 0 ]
	_assert_next_model "null"
	_assert_at_ceiling "false"
	_assert_reason_present
}
