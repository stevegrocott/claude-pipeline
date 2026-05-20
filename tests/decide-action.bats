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
ORCHESTRATOR_SCRIPT="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"

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

	# decide-action.sh uses the composition pattern: it delegates to
	# decide-retry.sh, which (when RETRY_POLICY_BACKEND=claude) calls
	# the mock claude.  Install a mock claude that returns a valid
	# escalate action so we can verify the reason string from the skill
	# propagates through to stdout.
	#
	# A failure stage_result is required so the success gate in
	# _compose_decide does not short-circuit to accept before reaching
	# the retry-policy delegation.
	local skill_output
	skill_output='{"action":"escalate",'
	skill_output+='"reason":"double_timeout: passthrough"}'

	install_mock_claude
	set_mock_claude_output "$skill_output"

	# failure with double_timeout forces an escalate via the retry path
	local stage_result history
	stage_result='{"status":"failure","error_kind":"double_timeout",'
	stage_result+='"model":"haiku","raw":"","denials":[],"elapsed_ms":100}'
	history=$(_history_empty)

	# Export RETRY_POLICY_BACKEND=claude so _compose_decide forwards it
	# to decide-retry.sh, causing the mock claude to be invoked.
	RETRY_POLICY_BACKEND=claude run --separate-stderr \
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
	# The skill reason is combined with the model-fallback reason in the
	# composition path.  Verify the passthrough string from the mock
	# skill is present rather than requiring an exact match.
	if [[ "$reason" != *"passthrough"* ]]; then
		printf 'FAIL: skill reason did not propagate, got: %s\n' \
			"$reason" >&2
		return 1
	fi
}

# ===========================================================================
# (6) _compose_decide: unexpected retry_action value returns non-zero
# ===========================================================================

@test "(6) _compose_decide returns non-zero for unexpected retry_action value" {
	[[ -x "$DECIDE_ACTION_SCRIPT" ]] \
		|| fail "decide-action.sh not present or not executable"

	# Create a temp scripts directory holding a mock decide-retry.sh that
	# returns an unexpected action ("unknown").  This simulates what would
	# happen if RETRY_POLICY_BACKEND=bash emitted an action not yet handled
	# by _compose_decide's case block — e.g. a future policy extension.
	local mock_dir
	mock_dir="$TEST_TMP/scripts"
	mkdir -p "$mock_dir"
	cat > "$mock_dir/decide-retry.sh" <<'MOCK'
#!/usr/bin/env bash
# Mock: returns a schema-looking envelope with an unrecognised action.
printf '{"action":"unknown","reason":"injected unexpected action for test"}\n'
MOCK
	chmod +x "$mock_dir/decide-retry.sh"

	# Source _compose_decide and its dependencies in-process so the function
	# can be called directly.  Skip 'readonly' and 'set -o' header lines so
	# that SCRIPT_DIR / SCRIPT_NAME can be supplied by the test.
	local func_file
	func_file="$TEST_TMP/compose_decide.bash"
	awk '
		/^readonly /  { next }
		/^set -o /    { next }
		/^_compose_decide\(\) \{$/,/^\}$/        { print; next }
		/^_valid_retry_schema\(\) \{$/,/^\}$/    { print; next }
		/^_valid_fallback_schema\(\) \{$/,/^\}$/ { print; next }
		/^_bash_decide\(\) \{$/,/^\}$/           { print; next }
		/^_next_model\(\) \{$/,/^\}$/            { print; next }
		/^die\(\) \{$/,/^\}$/                    { print; next }
	' "$DECIDE_ACTION_SCRIPT" > "$func_file"

	# Point SCRIPT_DIR at the mock directory so _compose_decide invokes
	# mock/decide-retry.sh when it delegates the retry decision.
	SCRIPT_DIR="$mock_dir"
	SCRIPT_NAME="decide-action.sh"
	# shellcheck disable=SC1090
	source "$func_file"

	# Override _valid_retry_schema to return 0 for any JSON that carries a
	# non-empty reason field.  This lets the "unknown" action pass schema
	# validation so it reaches the wildcard arm of _compose_decide's case
	# block — the new code added to reject unexpected retry_action values.
	_valid_retry_schema() {
		local json="$1"
		local reason
		reason=$(jq -r '.reason // empty' 2>/dev/null <<< "$json")
		[[ -n "$reason" ]]
	}

	local stage_result history
	stage_result='{"status":"failure","error_kind":"timeout","model":"haiku",'
	stage_result+='"raw":"","denials":[],"elapsed_ms":100}'
	history='[]'

	run --separate-stderr _compose_decide "$stage_result" "$history"

	[ "$status" -ne 0 ]

	# Wildcard arm must emit the diagnostic to stderr.
	[[ "$stderr" == *"unexpected retry_action"* ]] || {
		printf 'FAIL: expected "unexpected retry_action" in stderr, got: %s\n' \
			"$stderr" >&2
		return 1
	}
}

# ===========================================================================
# (should_run_deploy_verify) fast-path gate
# Tests verify that should_run_deploy_verify() skips the deploy-verify
# stage when STATUS_FILE contains ".route = fast-path".  These exercise
# the gate added in issue #354 at the tests/ suite level.
# ===========================================================================

# Extract should_run_deploy_verify() from the orchestrator into an
# isolated file and source it into the calling test's subshell.
_load_deploy_verify_fn() {
	local fn_file="$TEST_TMP/deploy_verify_fn.bash"
	awk '
		/^should_run_deploy_verify\(\) \{$/,/^\}$/ { print; next }
	' "$ORCHESTRATOR_SCRIPT" > "$fn_file"
	# shellcheck disable=SC1090
	source "$fn_file"
}

@test "(7) should_run_deploy_verify returns 1 when STATUS_FILE route is fast-path" {
	[[ -f "$ORCHESTRATOR_SCRIPT" ]] \
		|| fail "orchestrator script not found: $ORCHESTRATOR_SCRIPT"

	_load_deploy_verify_fn

	STATUS_FILE="$TEST_TMP/status.json"
	LOG_BASE="$TEST_TMP/logs"
	DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
	TRACKER="github"
	export STATUS_FILE LOG_BASE DEPLOY_VERIFY_CMD TRACKER

	mkdir -p "$LOG_BASE/context"
	printf '{"route":"fast-path","state":"running"}\n' > "$STATUS_FILE"

	# A qualifying label is present — the fast-path gate must win.
	gh() { printf 'env:test\n'; }
	export -f gh

	run --separate-stderr should_run_deploy_verify "99"
	[ "$status" -eq 1 ]
}

@test "(8) should_run_deploy_verify returns 0 when STATUS_FILE route is full" {
	[[ -f "$ORCHESTRATOR_SCRIPT" ]] \
		|| fail "orchestrator script not found: $ORCHESTRATOR_SCRIPT"

	_load_deploy_verify_fn

	STATUS_FILE="$TEST_TMP/status.json"
	LOG_BASE="$TEST_TMP/logs"
	DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
	TRACKER="github"
	export STATUS_FILE LOG_BASE DEPLOY_VERIFY_CMD TRACKER

	mkdir -p "$LOG_BASE/context"
	printf '{"route":"full","state":"running"}\n' > "$STATUS_FILE"

	gh() { printf 'env:test\n'; }
	export -f gh

	run --separate-stderr should_run_deploy_verify "99"
	[ "$status" -eq 0 ]
}

@test "(9) should_run_deploy_verify returns 0 when STATUS_FILE has no route key" {
	[[ -f "$ORCHESTRATOR_SCRIPT" ]] \
		|| fail "orchestrator script not found: $ORCHESTRATOR_SCRIPT"

	_load_deploy_verify_fn

	STATUS_FILE="$TEST_TMP/status.json"
	LOG_BASE="$TEST_TMP/logs"
	DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
	TRACKER="github"
	export STATUS_FILE LOG_BASE DEPLOY_VERIFY_CMD TRACKER

	mkdir -p "$LOG_BASE/context"
	# Omit .route — jq default of "full" means the gate must not fire.
	printf '{"state":"running"}\n' > "$STATUS_FILE"

	gh() { printf 'env:test\n'; }
	export -f gh

	run --separate-stderr should_run_deploy_verify "99"
	[ "$status" -eq 0 ]
}

@test "(10) should_run_deploy_verify fast-path gate wins over env:staging label" {
	[[ -f "$ORCHESTRATOR_SCRIPT" ]] \
		|| fail "orchestrator script not found: $ORCHESTRATOR_SCRIPT"

	_load_deploy_verify_fn

	STATUS_FILE="$TEST_TMP/status.json"
	LOG_BASE="$TEST_TMP/logs"
	DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
	TRACKER="github"
	export STATUS_FILE LOG_BASE DEPLOY_VERIFY_CMD TRACKER

	mkdir -p "$LOG_BASE/context"
	printf '{"route":"fast-path","state":"running"}\n' > "$STATUS_FILE"

	# env:staging is normally a qualifying label — fast-path must still skip.
	gh() { printf 'env:staging\n'; }
	export -f gh

	run --separate-stderr should_run_deploy_verify "99"
	[ "$status" -eq 1 ]
}

# ===========================================================================
# (should_run_deploy_verify) env:nas-premerge label
# env:nas-premerge issues are handled by the NAS pre-merge notification block
# (a comment posted pre-PR asking the human to trigger the NAS build manually).
# The post-merge deploy_verify stage must NOT fire for this label alone.
# ===========================================================================

@test "(11) should_run_deploy_verify returns 1 for env:nas-premerge label" {
	[[ -f "$ORCHESTRATOR_SCRIPT" ]] \
		|| fail "orchestrator script not found: $ORCHESTRATOR_SCRIPT"

	_load_deploy_verify_fn

	STATUS_FILE="$TEST_TMP/status.json"
	LOG_BASE="$TEST_TMP/logs"
	DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
	TRACKER="github"
	export STATUS_FILE LOG_BASE DEPLOY_VERIFY_CMD TRACKER

	mkdir -p "$LOG_BASE/context"
	printf '{"route":"full","state":"running"}\n' > "$STATUS_FILE"
	# No issue body file — label check is the only gate.
	rm -f "$LOG_BASE/context/issue-body.md"

	# env:nas-premerge does NOT match env:(test|nas|staging) — gate must skip.
	gh() { printf 'env:nas-premerge\n'; }
	export -f gh

	run --separate-stderr should_run_deploy_verify "99"
	[ "$status" -eq 1 ]
}

@test "(12) should_run_deploy_verify returns 0 for env:nas (not premerge variant)" {
	# Confirm env:nas (without -premerge suffix) still triggers deploy_verify,
	# distinguishing it from the env:nas-premerge notification path.
	[[ -f "$ORCHESTRATOR_SCRIPT" ]] \
		|| fail "orchestrator script not found: $ORCHESTRATOR_SCRIPT"

	_load_deploy_verify_fn

	STATUS_FILE="$TEST_TMP/status.json"
	LOG_BASE="$TEST_TMP/logs"
	DEPLOY_VERIFY_CMD="./scripts/deploy-nas.sh"
	TRACKER="github"
	export STATUS_FILE LOG_BASE DEPLOY_VERIFY_CMD TRACKER

	mkdir -p "$LOG_BASE/context"
	printf '{"route":"full","state":"running"}\n' > "$STATUS_FILE"
	rm -f "$LOG_BASE/context/issue-body.md"

	gh() { printf 'env:nas\n'; }
	export -f gh

	run --separate-stderr should_run_deploy_verify "99"
	[ "$status" -eq 0 ]
}

# ===========================================================================
# (should_run_deploy_verify) body-scan gate
# Tests verify that should_run_deploy_verify() uses the "## Deploy
# Verification" section in issue-body.md as a fallback gate when no
# qualifying env: label is present.
# ===========================================================================

@test "(13) should_run_deploy_verify returns 0 when body has Deploy Verification section and DEPLOY_VERIFY_CMD is set" {
	[[ -f "$ORCHESTRATOR_SCRIPT" ]] \
		|| fail "orchestrator script not found: $ORCHESTRATOR_SCRIPT"

	_load_deploy_verify_fn

	STATUS_FILE="$TEST_TMP/status.json"
	LOG_BASE="$TEST_TMP/logs"
	DEPLOY_VERIFY_CMD="./scripts/deploy-test.sh"
	TRACKER="github"
	export STATUS_FILE LOG_BASE DEPLOY_VERIFY_CMD TRACKER

	mkdir -p "$LOG_BASE/context"
	printf '{"route":"full","state":"running"}\n' > "$STATUS_FILE"
	printf '## Deploy Verification\n\n**Verification command:** ./scripts/deploy-test.sh\n\nRun smoke tests after deploy.\n' \
		> "$LOG_BASE/context/issue-body.md"

	# No qualifying env: label — body-scan must be the trigger.
	gh() { printf ''; }
	export -f gh

	run --separate-stderr should_run_deploy_verify "99"
	[ "$status" -eq 0 ]
}

@test "(14) should_run_deploy_verify returns 1 when body has Deploy Verification section but DEPLOY_VERIFY_CMD is empty" {
	[[ -f "$ORCHESTRATOR_SCRIPT" ]] \
		|| fail "orchestrator script not found: $ORCHESTRATOR_SCRIPT"

	_load_deploy_verify_fn

	STATUS_FILE="$TEST_TMP/status.json"
	LOG_BASE="$TEST_TMP/logs"
	DEPLOY_VERIFY_CMD=""
	TRACKER="github"
	export STATUS_FILE LOG_BASE DEPLOY_VERIFY_CMD TRACKER

	mkdir -p "$LOG_BASE/context"
	printf '{"route":"full","state":"running"}\n' > "$STATUS_FILE"
	printf '## Deploy Verification\n\n**Verification command:** ./scripts/deploy-test.sh\n\nRun smoke tests after deploy.\n' \
		> "$LOG_BASE/context/issue-body.md"

	# No qualifying env: label present either.
	gh() { printf ''; }
	export -f gh

	run --separate-stderr should_run_deploy_verify "99"
	[ "$status" -eq 1 ]
}
