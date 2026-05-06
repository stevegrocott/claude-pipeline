#!/usr/bin/env bats
#
# tests/decide-action.bats
# Tests for .claude/scripts/decide-action.sh (issue #210, PR-B of #195).
#
# decide-action.sh is the bash glue between the orchestrator and the
# escalation-policy skill.  It accepts a stage_result envelope and an
# escalation history, invokes the skill via the composition pattern,
# validates the skill's output against the {action, model?, reason}
# schema, and echoes the chosen action to stdout.  On schema-invalid
# skill output, or when ESCALATION_POLICY_BACKEND=bash, it falls back
# to an inline bash decision tree so the orchestrator never crashes
# mid-flight.
#
# Fixture cases (per issue #210 task 2):
#   (1) ESCALATION_POLICY_BACKEND=bash path returns a valid action
#       (and does NOT invoke the skill — verified via tripwire mock)
#   (2) Schema-invalid skill output triggers the bash fallback,
#       not a crash
#   (3) Valid skill output is echoed through to stdout
#

# `run --separate-stderr` needs bats 1.5+; declare the requirement so
# bats fails fast on older versions instead of emitting a BW02 warning.
bats_require_minimum_version 1.5.0

# Resolve repo-root paths once at load time so tests are CWD-independent.
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
DECIDE_ACTION_SCRIPT="$REPO_ROOT/.claude/scripts/decide-action.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Snapshot PATH so the mock-claude bin doesn't leak between tests.
	_ORIGINAL_PATH="$PATH"

	# Default: no kill-switch.  Individual tests opt in to bash mode.
	unset ESCALATION_POLICY_BACKEND
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
# Mock `claude` for decide-action tests.  All args are ignored;
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

# A minimal stage_result envelope mapping to a clear bash decision
# (status=success + non-null output + null error_kind → accept), so
# the bash fallback yields a deterministic action regardless of
# decision-tree edge cases.
_stage_result_success() {
	printf '%s' \
		'{"status":"success","output":{"status":"ok"},' \
		'"raw":"","denials":[],"model":"haiku",' \
		'"error_kind":null,"elapsed_ms":100}'
}

_history_empty() {
	printf '%s' '[]'
}

# Assert $output (from `run --separate-stderr`) parses as JSON with
# .action set to one of the four allowed values and a non-empty
# .reason.  Helpers return non-zero to fail the calling @test.
_assert_valid_action_envelope() {
	local action reason
	action=$(printf '%s' "$output" | jq -r '.action' 2>/dev/null)
	reason=$(printf '%s' "$output" | jq -r '.reason' 2>/dev/null)

	case "$action" in
		accept|escalate|bail|retry_same) ;;
		*)
			printf 'FAIL: expected valid action, got: %s\n' \
				"$action" >&2
			printf 'Full stdout: %s\n' "$output" >&2
			return 1
			;;
	esac

	if [[ -z "$reason" || "$reason" == "null" ]]; then
		printf 'FAIL: expected non-empty reason, got: %s\n' \
			"$reason" >&2
		return 1
	fi
}

# A minimal stage_result with status=success but NO .output.status field.
# Under the old buggy guard, output_status resolved to "null" which caused
# the compound condition to fail, falling through to error handling instead
# of accepting.  The new guard checks status first, so this must → accept.
_stage_result_success_no_output_status() {
	printf '%s' \
		'{"status":"success","raw":"","denials":[],"model":"haiku",' \
		'"error_kind":null,"elapsed_ms":100}'
}

# ===========================================================================
# (1) ESCALATION_POLICY_BACKEND=bash bypasses the skill entirely
# ===========================================================================

@test "(1) ESCALATION_POLICY_BACKEND=bash returns a valid action via inline bash" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	# Tripwire: if the bash backend incorrectly invokes the skill,
	# the mock prints this sentinel and exits 1.  A correctly-routed
	# bash backend never reaches the mock.
	install_mock_claude
	set_mock_claude_output 'TRIPWIRE-SKILL-WAS-INVOKED'
	set_mock_claude_exit 1

	local stage_result history
	stage_result=$(_stage_result_success)
	history=$(_history_empty)

	ESCALATION_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_ACTION_SCRIPT" "$stage_result" "$history"

	[ "$status" -eq 0 ]
	_assert_valid_action_envelope

	# The tripwire string must not appear on stdout — proves the
	# skill code path was not exercised.
	if [[ "$output" == *"TRIPWIRE-SKILL-WAS-INVOKED"* ]]; then
		printf 'FAIL: skill invoked despite bash kill-switch\n' >&2
		printf 'Output: %s\n' "$output" >&2
		return 1
	fi
}

# ===========================================================================
# (2) Schema-invalid skill output triggers the bash fallback
# ===========================================================================

@test "(2) schema-invalid skill output triggers bash fallback (no crash)" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	# Skill returns JSON that lacks the required `action` field —
	# must fail jq schema validation and force the fallback path.
	install_mock_claude
	set_mock_claude_output '{"foo":"bar","not_an_action":"oops"}'

	local stage_result history
	stage_result=$(_stage_result_success)
	history=$(_history_empty)

	run --separate-stderr \
		bash "$DECIDE_ACTION_SCRIPT" "$stage_result" "$history"

	# Fallback must succeed — the orchestrator never sees a crash
	# from a malformed skill response.
	[ "$status" -eq 0 ]
	_assert_valid_action_envelope
}

# ===========================================================================
# (3) Valid skill output is echoed through to stdout
# ===========================================================================

# ===========================================================================
# (issue-252) success gate fires on status=success even without .output.status
# ===========================================================================

@test "(4) status=success without .output.status → accept (bash backend)" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	local stage_result history
	stage_result=$(_stage_result_success_no_output_status)
	history=$(_history_empty)

	ESCALATION_POLICY_BACKEND=bash run --separate-stderr \
		bash "$DECIDE_ACTION_SCRIPT" "$stage_result" "$history"

	[ "$status" -eq 0 ]

	local action
	action=$(printf '%s' "$output" | jq -r '.action')
	if [[ "$action" != "accept" ]]; then
		printf 'FAIL: expected accept, got: %s\n' "$action" >&2
		printf 'Stdout: %s\n' "$output" >&2
		return 1
	fi
}

@test "(5) status=success without .output.status → accept (compose backend)" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	local stage_result history
	stage_result=$(_stage_result_success_no_output_status)
	history=$(_history_empty)

	# Use compose backend (default); the success gate must fire before any
	# sub-script delegation, so no mock for decide-retry.sh is needed.
	run --separate-stderr \
		bash "$DECIDE_ACTION_SCRIPT" "$stage_result" "$history"

	[ "$status" -eq 0 ]

	local action
	action=$(printf '%s' "$output" | jq -r '.action')
	if [[ "$action" != "accept" ]]; then
		printf 'FAIL: expected accept, got: %s\n' "$action" >&2
		printf 'Stdout: %s\n' "$output" >&2
		return 1
	fi
}

@test "(3) valid skill output is echoed through to stdout" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	local skill_output
	skill_output='{"action":"escalate","model":"sonnet",'
	skill_output+='"reason":"double_timeout: passthrough"}'

	install_mock_claude
	set_mock_claude_output "$skill_output"

	local stage_result history
	stage_result=$(_stage_result_success)
	history=$(_history_empty)

	run --separate-stderr \
		bash "$DECIDE_ACTION_SCRIPT" "$stage_result" "$history"

	[ "$status" -eq 0 ]

	# Round-trip the three fields independently — assertion is
	# order- and whitespace-independent.
	local action model reason
	action=$(printf '%s' "$output" | jq -r '.action')
	model=$(printf '%s' "$output"  | jq -r '.model')
	reason=$(printf '%s' "$output" | jq -r '.reason')

	if [[ "$action" != "escalate" ]]; then
		printf 'FAIL: expected action=escalate, got: %s\n' \
			"$action" >&2
		printf 'Stdout: %s\n' "$output" >&2
		return 1
	fi
	if [[ "$model" != "sonnet" ]]; then
		printf 'FAIL: expected model=sonnet, got: %s\n' \
			"$model" >&2
		return 1
	fi
	if [[ "$reason" != "double_timeout: passthrough" ]]; then
		printf 'FAIL: reason did not round-trip, got: %s\n' \
			"$reason" >&2
		return 1
	fi
}
