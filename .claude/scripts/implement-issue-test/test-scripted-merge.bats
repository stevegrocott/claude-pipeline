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

	# Issue #861: the gate consults the non-blocking allowlist through three
	# more helpers and four module-level assignments; load them the same way so
	# the extracted functions run exactly as in production.
	local helper
	for helper in _non_blocking_checks_json _ignored_failed_checks \
		_pending_ignored_checks _has_pending_check _pr_terminal_state \
		_pr_head_sha _check_runs_json _latest_full_run_id \
		_post_label_run_state wait_for_full_run; do
		local body
		body=$(_extract_function_body "$helper" "$MERGE_MR")
		[[ -n "$body" ]] || fail "$helper() not defined in merge-mr.sh"
		eval "$body"
	done
	eval "$(grep -E '^(MERGE_MR_NON_BLOCKING_CHECKS|MERGE_MR_FULL_RUN_LABEL|MERGE_MR_FULL_RUN_CHECK|_JQ_CHECK_NAME|_JQ_IS_FAILED_STATE|_JQ_FAILED_CHECK_NAME)=' "$MERGE_MR")"

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

# Stubs `gh` for the full-run wait (issue #878).
#
#   $1 - head SHA reported BEFORE the label is applied
#   $2 - head SHA reported AFTER  the label is applied (same as $1 unless the
#        test is exercising the head-moved refusal)
#   $3 - `gh api` check-runs payload BEFORE the label is applied
#   $4 - `gh api` check-runs payload AFTER  the label is applied
#
# Splitting before/after is the point: it lets a test present a run that was
# already green on the head at label time and assert the wait is NOT satisfied
# by it.
_stub_gh_full_run() {
	local sha_before="$1" sha_after="$2" before="$3" after="$4"

	mkdir -p "$TEST_TMP/bin"
	printf '%s' "$before" > "$TEST_TMP/check-runs-before.json"
	printf '%s' "$after" > "$TEST_TMP/check-runs-after.json"
	cat > "$TEST_TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMP/gh-calls.log"
if [[ -f "$TEST_TMP/label-applied" ]]; then
	_sha='$sha_after'
	_runs="$TEST_TMP/check-runs-after.json"
else
	_sha='$sha_before'
	_runs="$TEST_TMP/check-runs-before.json"
fi
case "\$*" in
	*"pr edit"*)
		: > "$TEST_TMP/label-applied"
		;;
	*"pr view"*headRefOid*)
		printf '%s\n' "\$_sha"
		;;
	*api*check-runs*)
		cat "\$_runs"
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

# ---------------------------------------------------------------------------
# Issue #861: MERGE_MR_NON_BLOCKING_CHECKS — informational checks must not
# turn an otherwise-green PR into a refusal.
# ---------------------------------------------------------------------------

@test "#861 AC1: UNSTABLE from an allowlisted check only, nothing pending -> mergeable, names the ignored check" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"frontend-unit-tests"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"validate"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"e2e"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS=frontend-unit-tests MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5979
	[[ "$status" -eq 0 ]] \
		|| fail "gate refused a PR whose only red check is allowlisted: $output"
	assert_contains "$output" "non-blocking check(s) [frontend-unit-tests]"
}

# ---------------------------------------------------------------------------
# End-to-end: run the real script, not extracted functions.
#
# Every other case here extracts a function and calls it through bats `run`,
# which captures the status and so never trips `set -e`. That is precisely why
# the #876 regression shipped: _pr_terminal_state returns 1 on the normal
# "still open, proceed" path, and a bare call under `set -euo pipefail` aborted
# merge-mr.sh before it ever reached the mergeability wait. Every merge of an
# open PR failed with exit 1 and no output, and the whole suite stayed green.
# ---------------------------------------------------------------------------

@test "#876 regression: the script reaches the merge for an OPEN, CLEAN PR" {
	mkdir -p "$TEST_TMP/bin"
	: > "$TEST_TMP/gh-e2e.log"
	cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "GHLOG"
for a in "$@"; do
  case "$a" in
    state) printf 'OPEN\n'; exit 0 ;;
    mergeStateStatus,statusCheckRollup)
      printf '%s\n' '{"mergeStateStatus":"CLEAN","statusCheckRollup":[]}'; exit 0 ;;
  esac
done
case "$1 $2" in
  "pr merge") printf 'merged\n'; exit 0 ;;
esac
printf '{}\n'; exit 0
STUB
	sed -i.bak "s|GHLOG|$TEST_TMP/gh-e2e.log|" "$TEST_TMP/bin/gh"
	chmod +x "$TEST_TMP/bin/gh"

	PATH="$TEST_TMP/bin:$PATH" run "$MERGE_MR" 5979
	[[ "$status" -eq 0 ]] \
		|| fail "script aborted on an OPEN PR (exit $status) — set -e regression: $output"

	# It must actually have got as far as merging, not just exited 0 early.
	grep -q "pr merge" "$TEST_TMP/gh-e2e.log" \
		|| fail "script exited 0 without merging; gh calls: $(cat "$TEST_TMP/gh-e2e.log")"
}

# ---------------------------------------------------------------------------
# Issue #876: a MERGED or CLOSED PR reports mergeStateStatus UNKNOWN forever.
# Polling one wastes MERGE_MR_POLL_MAX and reports a false decline, which the
# batch counts as a failed issue.
# ---------------------------------------------------------------------------

# Stubs `gh pr view --json state`, recording every call so the API-call count
# can be asserted.
_stub_gh_pr_state() {
	mkdir -p "$TEST_TMP/bin"
	: > "$TEST_TMP/gh-state-calls.log"
	cat > "$TEST_TMP/bin/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_TMP/gh-state-calls.log"
printf '%s\n' "$1"
exit 0
STUB
	chmod +x "$TEST_TMP/bin/gh"
	PATH="$TEST_TMP/bin:$PATH"
}

@test "#876 AC1: an already-MERGED PR short-circuits in one API call" {
	_load_merge_mr_functions
	_stub_gh_pr_state "MERGED"

	run _pr_terminal_state 6032
	[[ "$status" -eq 0 ]] \
		|| fail "a MERGED PR must report done, got status $status: $output"
	assert_contains "$output" "already MERGED"

	local calls
	calls=$(grep -c . "$TEST_TMP/gh-state-calls.log" 2>/dev/null) || calls=0
	[[ "$calls" -eq 1 ]] \
		|| fail "expected exactly one API call, saw $calls"
}

@test "#876 AC1: a CLOSED-unmerged PR is refused, naming the state" {
	_load_merge_mr_functions
	_stub_gh_pr_state "CLOSED"

	run _pr_terminal_state 6032
	[[ "$status" -eq 2 ]] \
		|| fail "a CLOSED PR must be a distinct refusal, got status $status"
	assert_contains "$output" "CLOSED without having been merged"
}

@test "#876 AC1: an OPEN PR falls through to the mergeability wait" {
	_load_merge_mr_functions
	_stub_gh_pr_state "OPEN"

	run _pr_terminal_state 6032
	[[ "$status" -eq 1 ]] \
		|| fail "an OPEN PR must proceed to the wait, got status $status"
}

@test "#876 AC1: an unreadable state falls through rather than short-circuiting" {
	_load_merge_mr_functions
	_stub_gh_pr_state ""

	run _pr_terminal_state 6032
	[[ "$status" -eq 1 ]] \
		|| fail "an unknown state must not be treated as terminal, got $status"
}

@test "#876 AC2: the github arm consults the terminal check before waiting" {
	# The batch treats merge-mr.sh's exit 0 as merged, so the MERGED
	# short-circuit is what stops a false 'failed' issue. Assert the wiring.
	local arm
	arm=$(awk '/^case "\$GIT_HOST" in/,/^esac/' "$MERGE_MR")
	[[ "$arm" == *'_pr_terminal_state "$MR"'* ]] \
		|| fail "github arm does not consult _pr_terminal_state: $arm"
	[[ "$arm" == *'0) exit 0 ;;'* ]] \
		|| fail "MERGED does not exit 0, so the batch would count a failure"
	# ...and it must come before the poll, or it saves nothing.
	local before after
	before=${arm%%wait_for_mergeable*}
	[[ "$before" == *'_pr_terminal_state'* ]] \
		|| fail "terminal check runs after the poll, defeating its purpose"
}

# ---------------------------------------------------------------------------
# Issue #877: a *pending* allowlisted check must not hold the merge either.
# A 25-33 min allowlisted job turned every merge into merge_pr_timeout and the
# batch counted a failure with every blocking check green.
# ---------------------------------------------------------------------------

@test "#877 AC1: UNSTABLE with only an allowlisted check still running -> merges on the first poll" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"","name":"frontend-unit-tests"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"validate"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"e2e"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS=frontend-unit-tests MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 6051
	[[ "$status" -eq 0 ]] \
		|| fail "waited on an allowlisted check that was still running: $output"
	assert_contains "$output" "frontend-unit-tests (still running)"
}

@test "#877 AC1: BLOCKED with only an allowlisted check still running -> merges on the first poll" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"","name":"frontend-unit-tests"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS=frontend-unit-tests MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 6051
	[[ "$status" -eq 0 ]] \
		|| fail "BLOCKED with only an allowlisted check pending was not accepted: $output"
	assert_contains "$output" "is BLOCKED only because of non-blocking check(s)"
}

@test "#877 AC2: a NON-allowlisted check still running keeps waiting (unchanged)" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"frontend-unit-tests"},{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"","name":"e2e"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS=frontend-unit-tests MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 6051
	[[ "$status" -ne 0 ]] \
		|| fail "merged while a BLOCKING check was still running"
	assert_contains "$output" "Timed out waiting"
}

@test "#877 AC2: an allowlisted pending check with a real FAILURE is still refused" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"","name":"frontend-unit-tests"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"e2e"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS=frontend-unit-tests MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 6051
	[[ "$status" -ne 0 ]] \
		|| fail "merged despite a real FAILURE while an allowlisted check ran"
	assert_contains "$output" 'check "e2e" that concluded in failure'
}

@test "#877 AC3: with no allowlist, a pending check still holds the merge" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"","name":"frontend-unit-tests"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS="" MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 6051
	[[ "$status" -ne 0 ]] \
		|| fail "an empty allowlist must not waive a pending check"
}

@test "#861 AC2: an allowlisted failure plus a real failure is still refused, naming the real one" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"frontend-unit-tests"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"e2e"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS=frontend-unit-tests MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5979
	[[ "$status" -ne 0 ]] \
		|| fail "gate merged despite a non-allowlisted FAILURE"
	assert_contains "$output" 'check "e2e" that concluded in failure'
}

@test "#861 AC2: an allowlisted failure with another check still running keeps waiting (times out, no merge)" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"frontend-unit-tests"},{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":"","name":"e2e"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS=frontend-unit-tests MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=2
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5979
	[[ "$status" -ne 0 ]] \
		|| fail "gate proceeded while a blocking check was still running"
	assert_contains "$output" "Waiting for PR #5979"
	assert_contains "$output" "Timed out"
}

@test "#861 AC1: an empty allowlist changes nothing — the same UNSTABLE PR is refused" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"frontend-unit-tests"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS= MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5979
	[[ "$status" -ne 0 ]] \
		|| fail "empty allowlist merged an UNSTABLE PR"
	assert_contains "$output" 'check "frontend-unit-tests" that concluded in failure'
}

@test "#861 AC3: legacy gate (MERGE_MR_MERGE_STATE_GATE=0) honours the allowlist and is otherwise unchanged" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeable":"MERGEABLE","mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE","name":"frontend-unit-tests"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS=frontend-unit-tests MERGE_MR_MERGE_STATE_GATE=0 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5979
	[[ "$status" -eq 0 ]] \
		|| fail "legacy gate refused an allowlisted-only failure: $output"
}

@test "#861: legacy commit-status entries are matched by context, and names are trimmed" {
	_load_merge_mr_functions
	_stub_gh_pr_view '{"mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"__typename":"StatusContext","state":"FAILURE","context":"ci/informational"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS","name":"validate"}]}'

	MERGE_MR_NON_BLOCKING_CHECKS=" ci/informational , other " MERGE_MR_MERGE_STATE_GATE=1 MERGE_MR_POLL_INTERVAL=1 MERGE_MR_POLL_MAX=1
	export MERGE_MR_NON_BLOCKING_CHECKS MERGE_MR_MERGE_STATE_GATE MERGE_MR_POLL_INTERVAL MERGE_MR_POLL_MAX

	run wait_for_mergeable 5979
	[[ "$status" -eq 0 ]] \
		|| fail "status-context allowlist entry not honoured: $output"
	assert_contains "$output" "[ci/informational]"
}


# ---------------------------------------------------------------------------
# Issue #878: one full E2E per merge, requested by label on the FINAL head.
#
# The consumer's curated suite runs on PR-open and on demand via a label, so a
# PR that took review-fix pushes can otherwise merge on a head the suite never
# covered. merge-mr.sh adds the label and waits — but the run it waits for must
# be one the label created. A suite that went green at PR-open time is still
# attached to the same head SHA, so a wait keyed on the SHA alone matches it
# instantly and waits for nothing.
# ---------------------------------------------------------------------------

_RUN_GREEN_111='{"check_runs":[{"id":111,"name":"e2e","status":"completed","conclusion":"success"}]}'

@test "#878 AC1: a pre-label green e2e run on the same head does NOT satisfy the wait" {
	_load_merge_mr_functions
	# The same payload before and after: the head already carries a green
	# `e2e` run and the label triggers nothing new.
	_stub_gh_full_run deadbeef deadbeef "$_RUN_GREEN_111" "$_RUN_GREEN_111"

	MERGE_MR_FULL_RUN_LABEL=full-e2e MERGE_MR_FULL_RUN_POLL_INTERVAL=1 MERGE_MR_FULL_RUN_POLL_MAX=2
	export MERGE_MR_FULL_RUN_LABEL MERGE_MR_FULL_RUN_POLL_INTERVAL MERGE_MR_FULL_RUN_POLL_MAX

	run wait_for_full_run 6051
	[[ "$status" -ne 0 ]] \
		|| fail "a stale pre-label green run satisfied the wait: $output"
	assert_contains "$output" "Timed out waiting for a post-label e2e run"
	# ...and it still asked for the run, so this is a real wait, not a
	# short-circuit that never requested anything.
	assert_file_contains "$TEST_TMP/gh-calls.log" "pr edit 6051 --add-label full-e2e"
}

@test "#878 AC1: a run created after the label satisfies the wait once it succeeds" {
	_load_merge_mr_functions
	_stub_gh_full_run deadbeef deadbeef "$_RUN_GREEN_111" \
		'{"check_runs":[{"id":111,"name":"e2e","status":"completed","conclusion":"success"},{"id":222,"name":"e2e","status":"completed","conclusion":"success"}]}'

	MERGE_MR_FULL_RUN_LABEL=full-e2e MERGE_MR_FULL_RUN_POLL_INTERVAL=1 MERGE_MR_FULL_RUN_POLL_MAX=4
	export MERGE_MR_FULL_RUN_LABEL MERGE_MR_FULL_RUN_POLL_INTERVAL MERGE_MR_FULL_RUN_POLL_MAX

	run wait_for_full_run 6051
	[[ "$status" -eq 0 ]] \
		|| fail "a post-label green run did not satisfy the wait: $output"
	assert_contains "$output" "(run 222) concluded success"
}

@test "#878 AC1: a post-label run still in progress keeps the merge waiting" {
	_load_merge_mr_functions
	_stub_gh_full_run deadbeef deadbeef "$_RUN_GREEN_111" \
		'{"check_runs":[{"id":111,"name":"e2e","status":"completed","conclusion":"success"},{"id":222,"name":"e2e","status":"in_progress","conclusion":null}]}'

	MERGE_MR_FULL_RUN_LABEL=full-e2e MERGE_MR_FULL_RUN_POLL_INTERVAL=1 MERGE_MR_FULL_RUN_POLL_MAX=2
	export MERGE_MR_FULL_RUN_LABEL MERGE_MR_FULL_RUN_POLL_INTERVAL MERGE_MR_FULL_RUN_POLL_MAX

	run wait_for_full_run 6051
	[[ "$status" -ne 0 ]] \
		|| fail "merged while the requested run was still in progress: $output"
	assert_contains "$output" "run 222 on deadbeef (status: in_progress"
}

@test "#878 AC1: a post-label run that fails is refused immediately, not waited out" {
	_load_merge_mr_functions
	_stub_gh_full_run deadbeef deadbeef "$_RUN_GREEN_111" \
		'{"check_runs":[{"id":111,"name":"e2e","status":"completed","conclusion":"success"},{"id":222,"name":"e2e","status":"completed","conclusion":"failure"}]}'

	MERGE_MR_FULL_RUN_LABEL=full-e2e MERGE_MR_FULL_RUN_POLL_INTERVAL=1 MERGE_MR_FULL_RUN_POLL_MAX=4
	export MERGE_MR_FULL_RUN_LABEL MERGE_MR_FULL_RUN_POLL_INTERVAL MERGE_MR_FULL_RUN_POLL_MAX

	run wait_for_full_run 6051
	[[ "$status" -ne 0 ]] \
		|| fail "a failed post-label run was treated as a green full run"
	assert_contains "$output" "(run 222) concluded failure"
	if [[ "$output" == *"Timed out"* ]]; then
		fail "a concluded failure must refuse at once, not poll to the timeout"
	fi
}

@test "#878 AC1: a head that moves while waiting is refused rather than merged" {
	_load_merge_mr_functions
	_stub_gh_full_run deadbeef cafe1234 "$_RUN_GREEN_111" \
		'{"check_runs":[{"id":222,"name":"e2e","status":"completed","conclusion":"success"}]}'

	MERGE_MR_FULL_RUN_LABEL=full-e2e MERGE_MR_FULL_RUN_POLL_INTERVAL=1 MERGE_MR_FULL_RUN_POLL_MAX=4
	export MERGE_MR_FULL_RUN_LABEL MERGE_MR_FULL_RUN_POLL_INTERVAL MERGE_MR_FULL_RUN_POLL_MAX

	run wait_for_full_run 6051
	[[ "$status" -ne 0 ]] \
		|| fail "merged a head the requested run did not cover: $output"
	assert_contains "$output" "head moved from deadbeef to cafe1234"
}

@test "#878 AC1: an unreadable check-runs payload refuses rather than assuming a zero watermark" {
	_load_merge_mr_functions
	# A zero watermark would make the pre-existing green run count as "new".
	_stub_gh_full_run deadbeef deadbeef '{"message":"Bad credentials"}' \
		"$_RUN_GREEN_111"

	MERGE_MR_FULL_RUN_LABEL=full-e2e MERGE_MR_FULL_RUN_POLL_INTERVAL=1 MERGE_MR_FULL_RUN_POLL_MAX=2
	export MERGE_MR_FULL_RUN_LABEL MERGE_MR_FULL_RUN_POLL_INTERVAL MERGE_MR_FULL_RUN_POLL_MAX

	run wait_for_full_run 6051
	[[ "$status" -ne 0 ]] \
		|| fail "an unreadable baseline was treated as 'no runs yet': $output"
	assert_contains "$output" "Cannot read the check runs on deadbeef"
	if [[ -f "$TEST_TMP/gh-calls.log" ]] \
		&& grep -q 'pr edit' "$TEST_TMP/gh-calls.log"; then
		fail "labelled the PR despite being unable to establish a watermark"
	fi
}

@test "#878 AC2: with MERGE_MR_FULL_RUN_LABEL unset the wait is a no-op — no label, no API call" {
	_load_merge_mr_functions
	_stub_gh_full_run deadbeef deadbeef "$_RUN_GREEN_111" "$_RUN_GREEN_111"

	MERGE_MR_FULL_RUN_LABEL="" MERGE_MR_FULL_RUN_POLL_INTERVAL=1 MERGE_MR_FULL_RUN_POLL_MAX=2
	export MERGE_MR_FULL_RUN_LABEL MERGE_MR_FULL_RUN_POLL_INTERVAL MERGE_MR_FULL_RUN_POLL_MAX

	expect_ok "unset label must be an immediate no-op" wait_for_full_run 6051
	if [[ -f "$TEST_TMP/gh-calls.log" ]]; then
		fail "unset label still called gh: $(< "$TEST_TMP/gh-calls.log")"
	fi
}

@test "#878 AC1: the check name the label must re-trigger is configurable" {
	# Exported BEFORE the functions are loaded, so the module-level
	# `${MERGE_MR_FULL_RUN_CHECK:-e2e}` default is evaluated with the
	# consumer's value in scope — a hardcoded check name fails here.
	MERGE_MR_FULL_RUN_CHECK=curated-e2e
	export MERGE_MR_FULL_RUN_CHECK
	_load_merge_mr_functions
	_stub_gh_full_run deadbeef deadbeef \
		'{"check_runs":[{"id":111,"name":"curated-e2e","status":"completed","conclusion":"success"}]}' \
		'{"check_runs":[{"id":111,"name":"curated-e2e","status":"completed","conclusion":"success"},{"id":222,"name":"curated-e2e","status":"completed","conclusion":"success"},{"id":333,"name":"e2e","status":"completed","conclusion":"failure"}]}'

	MERGE_MR_FULL_RUN_LABEL=full-e2e MERGE_MR_FULL_RUN_POLL_INTERVAL=1 MERGE_MR_FULL_RUN_POLL_MAX=4
	export MERGE_MR_FULL_RUN_LABEL MERGE_MR_FULL_RUN_POLL_INTERVAL MERGE_MR_FULL_RUN_POLL_MAX

	run wait_for_full_run 6051
	[[ "$status" -eq 0 ]] \
		|| fail "the configured check name was not the one awaited: $output"
	assert_contains "$output" "curated-e2e (run 222) concluded success"
}

@test "#878 AC2: the github arm requests the full run before the mergeability wait" {
	local arm
	arm=$(awk '/^case "\$GIT_HOST" in/,/^esac/' "$MERGE_MR")
	[[ "$arm" == *'wait_for_full_run "$MR" || exit 1'* ]] \
		|| fail "github arm never requests the full run: $arm"
	local before
	before=${arm%%wait_for_mergeable*}
	[[ "$before" == *'wait_for_full_run'* ]] \
		|| fail "the full-run request runs after the mergeability wait, so a merge could land before the suite was even requested"
}

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
