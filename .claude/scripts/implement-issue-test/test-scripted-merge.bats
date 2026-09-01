#!/usr/bin/env bats
#
# test-scripted-merge.bats
# Issue #853: the merge must not be contingent on model compliance.
#
# #848 closed the path where merge-mr.sh's refusal was laundered into a merge
# by the PR-exists recovery heuristic, but explicitly did NOT claim its AC4
# ("no pipeline path merges a PR whose check concluded in failure") because
# two holes remained:
#
#   1. process-pr's merge is LLM-mediated — SKILL.md instructs the model to
#      run merge-mr.sh, but nothing binds it. A model that shells out to
#      `gh pr merge` directly bypasses every guard.
#   2. MERGE_MR_MERGE_STATE_GATE=0 selects a legacy poll with no
#      concluded-check-failure test at all.
#
# These tests pin both holes shut, plus the orchestrator-side scripted merge
# that removes the model from the merge decision entirely.
#
# merge-mr.sh and the hook are read from .claude/scripts / .claude/hooks
# (canonical); the orchestrator function is sourced from the BUNDLED copy
# under plugins/pipeline-core/scripts/, matching test-pr-recovery-gate.bats,
# so a fix that lands only in the canonical tree is not credited here.
#

bats_require_minimum_version 1.5.0

load 'helpers/test-helper.bash'

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUNDLE_ORCHESTRATOR="$REPO_ROOT/plugins/pipeline-core/scripts/batch-orchestrator.sh"
MERGE_MR="$REPO_ROOT/.claude/scripts/platform/merge-mr.sh"
MERGE_HOOK="$REPO_ROOT/.claude/hooks/block-gh-pr-merge.sh"
PROCESS_PR_SCHEMA="$REPO_ROOT/.claude/scripts/schemas/process-pr.json"
PROCESS_PR_SKILL="$REPO_ROOT/plugins/pipeline-core/skills/process-pr/SKILL.md"
FAST_PATH="$REPO_ROOT/.claude/scripts/surgical-fast-path.sh"

setup() {
	setup_test_env
}

teardown() {
	teardown_test_env
}

# Sources wait_for_mergeable() and its helper out of merge-mr.sh without
# executing the script body (which would need a real PR and platform.sh).
_load_merge_mr_functions() {
	[[ -f "$MERGE_MR" ]] || fail "merge-mr.sh not found: $MERGE_MR"

	local gate_body name_body wait_body
	gate_body=$(_extract_function_body _has_concluded_check_failure "$MERGE_MR")
	[[ -n "$gate_body" ]] \
		|| fail "_has_concluded_check_failure() not defined in merge-mr.sh"
	name_body=$(_extract_function_body _first_failed_check "$MERGE_MR")
	[[ -n "$name_body" ]] \
		|| fail "_first_failed_check() not defined in merge-mr.sh"
	wait_body=$(_extract_function_body wait_for_mergeable "$MERGE_MR")
	[[ -n "$wait_body" ]] \
		|| fail "wait_for_mergeable() not defined in merge-mr.sh"

	eval "$gate_body"
	eval "$name_body"
	eval "$wait_body"

	# Neutralise the poll back-off. The loop still increments `elapsed` by
	# MERGE_MR_POLL_INTERVAL, so it terminates on MERGE_MR_POLL_MAX exactly as
	# in production — it just does not spend real seconds getting there.
	sleep() { :; }
}

# Stubs `gh pr view` so wait_for_mergeable sees a scripted payload. $1 is the
# JSON the stub returns for any --json query.
_stub_gh_pr_view() {
	local payload="$1"

	mkdir -p "$TEST_TMP/bin"
	cat > "$TEST_TMP/bin/gh" <<STUB
#!/usr/bin/env bash
# Records the invocation so tests can assert a merge was/was not attempted.
printf '%s\n' "\$*" >> "$TEST_TMP/gh-calls.log"
case "\$*" in
	*"pr view"*)
		# Emulate gh's own --jq application. The legacy poll calls
		# \`--json mergeable --jq .mergeable\` and expects a BARE value; the
		# gated poll asks for the object and applies jq itself. A stub that
		# ignored --jq would hand the legacy path a whole JSON blob as its
		# "state" and never match MERGEABLE.
		if [[ "\$*" == *"--jq"* ]]; then
			printf '%s\n' '$payload' | jq -r '.mergeable // "UNKNOWN"'
		else
			printf '%s\n' '$payload'
		fi
		;;
	*"pr merge"*)
		printf 'merged\n'
		;;
esac
exit 0
STUB
	chmod +x "$TEST_TMP/bin/gh"
	PATH="$TEST_TMP/bin:$PATH"
}

# Feeds a PreToolUse(Bash) payload to the hook and returns its exit code.
_run_merge_hook() {
	local cmd="$1"

	[[ -f "$MERGE_HOOK" ]] || fail "hook not found: $MERGE_HOOK"
	jq -n --arg c "$cmd" '{tool_input: {command: $c}}' \
		| "$MERGE_HOOK"
}

# =============================================================================
# AC3 — the concluded-check-failure test is not optional
# =============================================================================

@test "AC3: legacy gate still refuses a PR whose check concluded in failure" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"e2e"}]}'

	MERGE_MR_MERGE_STATE_GATE=0 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5857
	[[ "$status" -ne 0 ]] \
		|| fail "legacy gate returned success despite a FAILURE check"
	assert_contains "$output" "concluded in failure"
}

@test "AC3: legacy gate names the failing check in its refusal" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"e2e"}]}'

	MERGE_MR_MERGE_STATE_GATE=0 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5857
	# Assert the NAME appears inside the refusal sentence, not merely
	# anywhere in the output — the polled state JSON also contains "e2e", so a
	# bare substring check would pass without the gate firing at all.
	assert_contains "$output" 'check "e2e" that concluded in failure'
}

@test "AC4: legacy gate still returns success when the PR is mergeable and green" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"e2e"}]}'

	MERGE_MR_MERGE_STATE_GATE=0 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5857
	[[ "$status" -eq 0 ]] \
		|| fail "legacy gate refused a green mergeable PR: $output"
}

@test "AC4: default gate still refuses a concluded failure (unchanged)" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"e2e"}]}'

	MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5857
	[[ "$status" -ne 0 ]] || fail "default gate regressed — merged a failing PR"
	assert_contains "$output" "concluded in failure"
}

@test "AC3: a still-running check is not treated as a concluded failure" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeable":"UNKNOWN","mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"","name":"e2e"}]}'

	MERGE_MR_MERGE_STATE_GATE=0 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5857
	if printf '%s' "$output" | grep -q 'concluded in failure'; then
		fail "an in-progress check was misread as a concluded failure"
	fi
}

# =============================================================================
# AC1 — direct `gh pr merge` is hard-blocked, regardless of model behaviour
# =============================================================================

@test "AC1: hook blocks a direct gh pr merge" {
	run _run_merge_hook 'gh pr merge 5857 --squash --delete-branch'
	[[ "$status" -eq 2 ]] \
		|| fail "expected exit 2 (block), got $status: $output"
}

@test "AC1: hook blocks gh pr merge after a command separator" {
	run _run_merge_hook 'echo hi && gh pr merge 5857 --squash'
	[[ "$status" -eq 2 ]] || fail "expected block after &&, got $status"
}

@test "AC1: hook blocks gh pr merge behind env assignments and wrappers" {
	run _run_merge_hook 'FOO=1 command gh pr merge 5857 --merge'
	[[ "$status" -eq 2 ]] || fail "expected block behind wrappers, got $status"
}

@test "AC1: hook allows merge-mr.sh, the sanctioned entrypoint" {
	run _run_merge_hook '"$PLATFORM_DIR/merge-mr.sh" 5857'
	[[ "$status" -eq 0 ]] \
		|| fail "hook blocked the sanctioned entrypoint: $output"
}

@test "AC1: hook does not block an unrelated gh command" {
	run _run_merge_hook 'gh pr view 5857 --json mergeable'
	[[ "$status" -eq 0 ]] || fail "hook blocked an unrelated gh call"
}

@test "AC1: hook does not block a mere mention inside a quoted argument" {
	run _run_merge_hook 'git commit -m "do not gh pr merge by hand"'
	[[ "$status" -eq 0 ]] \
		|| fail "hook false-positived on a quoted mention"
}

@test "AC1: hook fails open on a malformed payload" {
	run bash -c "printf 'not json' | '$MERGE_HOOK'"
	[[ "$status" -eq 0 ]] || fail "hook must fail open, got $status"
}

@test "AC1: hook names merge-mr.sh so the blocked model knows where to go" {
	run _run_merge_hook 'gh pr merge 5857 --squash'
	assert_contains "$output" "merge-mr.sh"
}

# =============================================================================
# AC2 — the merge is performed by shell, not by the model
# =============================================================================

@test "AC2: schema accepts an approved verdict" {
	[[ -f "$PROCESS_PR_SCHEMA" ]] || fail "schema not found"
	run jq -e '.properties.status.enum | index("approved")' "$PROCESS_PR_SCHEMA"
	[[ "$status" -eq 0 ]] \
		|| fail "process-pr schema has no \"approved\" status"
}

@test "AC2: orchestrator defines the scripted merge helper" {
	[[ -f "$BUNDLE_ORCHESTRATOR" ]] || fail "bundled orchestrator not found"
	local body
	body=$(_extract_function_body perform_scripted_merge "$BUNDLE_ORCHESTRATOR")
	[[ -n "$body" ]] \
		|| fail "perform_scripted_merge() not defined in the bundled orchestrator"
}

@test "AC2: scripted merge invokes merge-mr.sh and succeeds when it does" {
	local body
	body=$(_extract_function_body perform_scripted_merge "$BUNDLE_ORCHESTRATOR")
	[[ -n "$body" ]] || fail "perform_scripted_merge() not defined"

	mkdir -p "$TEST_TMP/platform"
	cat > "$TEST_TMP/platform/merge-mr.sh" <<'STUB'
#!/usr/bin/env bash
printf 'merge-mr called with %s\n' "$*"
exit 0
STUB
	chmod +x "$TEST_TMP/platform/merge-mr.sh"

	log() { :; }
	log_error() { :; }
	log_warn() { :; }
	PLATFORM_DIR="$TEST_TMP/platform"
	eval "$body"

	run perform_scripted_merge 5792 5857
	[[ "$status" -eq 0 ]] \
		|| fail "scripted merge reported failure on a successful merge: $output"
}

@test "AC1: scripted merge reports failure when merge-mr.sh refuses" {
	local body
	body=$(_extract_function_body perform_scripted_merge "$BUNDLE_ORCHESTRATOR")
	[[ -n "$body" ]] || fail "perform_scripted_merge() not defined"

	mkdir -p "$TEST_TMP/platform"
	cat > "$TEST_TMP/platform/merge-mr.sh" <<'STUB'
#!/usr/bin/env bash
echo 'PR #5857 has check "e2e" that concluded in failure; refusing to wait' >&2
exit 1
STUB
	chmod +x "$TEST_TMP/platform/merge-mr.sh"

	log() { :; }
	log_error() { :; }
	log_warn() { :; }
	PLATFORM_DIR="$TEST_TMP/platform"
	eval "$body"

	run perform_scripted_merge 5792 5857
	[[ "$status" -ne 0 ]] \
		|| fail "scripted merge credited success despite merge-mr.sh refusing"
}

@test "AC2: the skill no longer instructs the model to run merge-mr.sh" {
	[[ -f "$PROCESS_PR_SKILL" ]] || fail "process-pr SKILL.md not found"
	if grep -qE '^"\$PLATFORM_DIR/merge-mr\.sh" "\$PR_NUMBER"' "$PROCESS_PR_SKILL"; then
		fail "SKILL.md still tells the model to perform the merge itself"
	fi
}

@test "AC2: the skill documents that the orchestrator performs the merge" {
	assert_file_contains "$PROCESS_PR_SKILL" "approved"
}

# =============================================================================
# AC5 — the fast path's own guard is untouched
# =============================================================================

@test "AC5: surgical fast path still guards its direct merge" {
	[[ -f "$FAST_PATH" ]] || fail "surgical-fast-path.sh not found"
	assert_file_contains "$FAST_PATH" "_fast_path_check_concluded_failure"
}
