#!/usr/bin/env bats
#
# tests/retry-policy-live.bats
# Tests for the live (Claude) backend path of decide-retry.sh.
#
# Installs a mock `claude` binary to verify the script routes correctly when
# RETRY_POLICY_BACKEND is unset or set to "claude":
#
#   (1) RETRY_POLICY_BACKEND=bash does NOT invoke claude (tripwire)
#   (2) RETRY_POLICY_BACKEND=claude passes valid action JSON through to stdout
#   (3) Unset RETRY_POLICY_BACKEND routes to the live claude path (not bash)
#   (4) Live path correctly forwards a bail action from claude
#
# The mock `claude` binary is configured via files in TEST_TMP:
#   TEST_TMP/claude_stdout — content printed by the mock on stdout
#   TEST_TMP/claude_exit   — exit code returned by the mock (default 0)
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

	# Snapshot PATH so the mock-claude bin doesn't leak between tests.
	_ORIGINAL_PATH="$PATH"

	# Default: no kill-switch so tests can control routing explicitly.
	unset RETRY_POLICY_BACKEND
}

teardown() {
	export PATH="${_ORIGINAL_PATH:-$PATH}"
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Install a mock `claude` CLI in TEST_TMP/bin and prepend it to PATH.
# The mock ignores all arguments and prints the contents of
# TEST_TMP/claude_stdout, exiting with the integer in
# TEST_TMP/claude_exit (default 0).
install_mock_claude() {
	local bin_dir="$TEST_TMP/bin"
	mkdir -p "$bin_dir"

	cat > "$bin_dir/claude" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock `claude` for retry-policy live-backend tests.  All args are ignored;
# stdout and exit code are driven by files in $TEST_TMP.
if [[ -f "$TEST_TMP/claude_stdout" ]]; then
	cat "$TEST_TMP/claude_stdout"
fi
if [[ -f "$TEST_TMP/claude_exit" ]]; then
	exit "$(<"$TEST_TMP/claude_exit")"
fi
exit 0
MOCK_EOF
	chmod +x "$bin_dir/claude"
	export PATH="$bin_dir:$PATH"
}

# Configure what the next mock-claude invocation prints to stdout.
set_mock_claude_output() {
	printf '%s' "$1" > "$TEST_TMP/claude_stdout"
}

# Configure the exit code for the next mock-claude invocation.
set_mock_claude_exit() {
	printf '%s' "$1" > "$TEST_TMP/claude_exit"
}

# Load a fixture file by basename (without .json extension).
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

# ===========================================================================
# (1) Bash kill-switch: RETRY_POLICY_BACKEND=bash never reaches claude
# ===========================================================================

@test "(1) RETRY_POLICY_BACKEND=bash does not invoke claude (tripwire)" {
	[[ -x "$DECIDE_RETRY_SCRIPT" ]] \
		|| fail "decide-retry.sh not present or not executable"

	# Tripwire: if the bash backend incorrectly invokes the skill, the mock
	# prints this sentinel and exits 1.  A correctly-routed bash backend
	# never reaches the mock.
	install_mock_claude
	set_mock_claude_output 'TRIPWIRE-SKILL-WAS-INVOKED'
	set_mock_claude_exit 1

	local stage_result history
	stage_result=$(_load_fixture "retry-under-limit")
	history=$(_history_empty)

	RETRY_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_RETRY_SCRIPT" "$stage_result" "0" "$history"

	[ "$status" -eq 0 ]
	_assert_action "retry"

	# The tripwire string must not appear on stdout — proves the skill code
	# path was not exercised.
	if [[ "$output" == *"TRIPWIRE-SKILL-WAS-INVOKED"* ]]; then
		printf 'FAIL: claude invoked despite RETRY_POLICY_BACKEND=bash\n' >&2
		printf 'Output: %s\n' "$output" >&2
		return 1
	fi
}

# ===========================================================================
# (2) Live path: RETRY_POLICY_BACKEND=claude passes action JSON through
# ===========================================================================

@test "(2) RETRY_POLICY_BACKEND=claude passes valid retry action JSON through" {
	[[ -x "$DECIDE_RETRY_SCRIPT" ]] \
		|| fail "decide-retry.sh not present or not executable"

	install_mock_claude
	local claude_output
	claude_output='{"action":"retry","reason":"rate_limit: transient throttle, retry_count=0, waiting 30000ms","backoff_ms":30000}'
	set_mock_claude_output "$claude_output"

	local stage_result history
	stage_result=$(_load_fixture "retry-under-limit")
	history=$(_history_empty)

	RETRY_POLICY_BACKEND=claude run --separate-stderr \
		bash "$DECIDE_RETRY_SCRIPT" "$stage_result" "0" "$history"

	[ "$status" -eq 0 ]
	_assert_action "retry"

	local backoff
	backoff=$(printf '%s' "$output" | jq -r '.backoff_ms' 2>/dev/null)
	if [[ "$backoff" != "30000" ]]; then
		printf 'FAIL: expected backoff_ms=30000, got: %s\n' "$backoff" >&2
		printf 'Full stdout: %s\n' "$output" >&2
		return 1
	fi
}

# ===========================================================================
# (3) Default path: unset RETRY_POLICY_BACKEND routes to claude
# ===========================================================================

@test "(3) unset RETRY_POLICY_BACKEND invokes claude, not the bash tree" {
	[[ -x "$DECIDE_RETRY_SCRIPT" ]] \
		|| fail "decide-retry.sh not present or not executable"

	install_mock_claude
	local claude_output
	claude_output='{"action":"escalate","reason":"timeout: retry_count=1 meets threshold; escalating haiku to sonnet"}'
	set_mock_claude_output "$claude_output"

	local stage_result history
	stage_result=$(_load_fixture "at-limit-escalate")
	history=$(_history_empty)

	# Explicitly unset RETRY_POLICY_BACKEND — must route to the live claude path.
	unset RETRY_POLICY_BACKEND
	run --separate-stderr \
		bash "$DECIDE_RETRY_SCRIPT" "$stage_result" "1" "$history"

	[ "$status" -eq 0 ]
	_assert_action "escalate"
}

# ===========================================================================
# (4) Live path: bail action from claude is forwarded unchanged
# ===========================================================================

@test "(4) RETRY_POLICY_BACKEND=claude forwards bail action from claude" {
	[[ -x "$DECIDE_RETRY_SCRIPT" ]] \
		|| fail "decide-retry.sh not present or not executable"

	install_mock_claude
	local claude_output
	claude_output='{"action":"bail","reason":"permission_denied: configuration error, retrying cannot fix this"}'
	set_mock_claude_output "$claude_output"

	local stage_result history
	stage_result=$(_load_fixture "unretryable-bail")
	history=$(_history_empty)

	RETRY_POLICY_BACKEND=claude run --separate-stderr \
		bash "$DECIDE_RETRY_SCRIPT" "$stage_result" "0" "$history"

	[ "$status" -eq 0 ]
	_assert_action "bail"

	local reason
	reason=$(printf '%s' "$output" | jq -r '.reason' 2>/dev/null)
	if [[ -z "$reason" || "$reason" == "null" ]]; then
		printf 'FAIL: expected non-empty reason, got: %s\n' "$reason" >&2
		return 1
	fi
}
