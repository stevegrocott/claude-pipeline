#!/usr/bin/env bats
#
# tests/event-emission.bats
# Assertions that stage_end status=error appears in events.jsonl after a bail
# outcome from _apply_stage_action (issue #280).
#
# Background: set_stage_completed() is the only function that emits stage_end,
# and it always uses status=success.  Stages that bail never emit a matching
# stage_end.  Tasks 1 and 2 of issue #280 add set_stage_failed() and wire it
# into the bail) and *) branches of _apply_stage_action().
#
# Test cases:
#   (1) event-emit.sh schema accepts a well-formed stage_end status=error event
#       [GREEN — plumbing exists today]
#   (2) _apply_stage_action bail) branch results in stage_end status=error in
#       events.jsonl  [RED until task 2 is implemented]
#   (3) _apply_stage_action *) unknown-action branch results in stage_end
#       status=error in events.jsonl  [RED until task 2 is implemented]
#

# Test cases (4)-(9) below cover issue #809: batch-orchestrator.sh's
# issue_end event hardcodes outcome=success for every process_issue() return
# of 0, which conflates three non-success terminal states (merge_blocked,
# budget_exceeded, already_done) with a genuine success. Tasks 1 and 2 of
# issue #809 make process_issue() record which terminal state it hit (a
# generalisation of the existing _PREFLIGHT_SKIPPED out-of-band flag) and
# make the emit site at the bottom of the main issue loop branch on it
# instead of hardcoding outcome=success. These tests assert only on the
# resulting events.jsonl content, not on the name of whatever internal
# variable carries the state, so they hold regardless of the exact
# mechanism tasks 1/2 land with.
#
#   (4) merge_blocked terminal state -> issue_end outcome=merge_blocked
#       [RED until tasks 1/2 are implemented]
#   (5) budget_exceeded terminal state -> issue_end outcome=budget_exceeded
#       [RED until tasks 1/2 are implemented]
#   (6) already_implemented terminal state -> issue_end outcome=already_done
#       [RED until tasks 1/2 are implemented]
#   (7) a generic processing error -> issue_end outcome=failed
#       [GREEN today — regression guard, unrelated arm of the case statement]
#   (8) a genuinely merged issue -> issue_end outcome=success
#       [GREEN today — regression guard, unrelated arm of the case statement]
#   (9) two issues in one batch, one merge_blocked then one budget_exceeded,
#       each get their own correct outcome with no leakage between calls
#       [RED until tasks 1/2 are implemented]

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
ORCHESTRATOR="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"
EVENT_EMIT="$REPO_ROOT/.claude/scripts/event-emit.sh"
BATCH_ORCHESTRATOR="$REPO_ROOT/.claude/scripts/batch-orchestrator.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# LOG_BASE must be a directory; emit_event derives run_id from its basename.
	export LOG_BASE="$TEST_TMP/test-run-event-emission"
	mkdir -p "$LOG_BASE"

	# Minimal status.json — set_stage_failed mirrors set_stage_completed, which
	# updates .stages[$stage] via jq.  The empty .stages object is enough.
	export STATUS_FILE="$TEST_TMP/status.json"
	printf '%s\n' '{"stages":{},"last_update":""}' > "$STATUS_FILE"

	# SCRIPT_DIR must point at the scripts directory so emit_event can locate
	# event-emit.sh; SCRIPT_NAME is used only in log messages.
	export SCRIPT_DIR="$REPO_ROOT/.claude/scripts"
	export SCRIPT_NAME="event-emission-test"

	# LOG_FILE empty → log_error writes only to stderr (no file needed).
	export LOG_FILE=""

	# _RUN_STAGE_NAME is the global used by run_stage() to track the active stage.
	# Set it here so set_stage_failed can read it if the implementation uses it
	# instead of (or in addition to) extracting stage from the stage_result JSON.
	export _RUN_STAGE_NAME="bail_test_stage"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Extract and source the functions needed for the orchestrator-level tests.
# Uses the same awk-range pattern as test (6) in decide-action.bats.
# set_stage_failed is included in the pattern; if it doesn't exist yet in the
# orchestrator (task 1 not done) the pattern simply matches nothing and the
# function remains undefined — test (2) and (3) will fail as expected (RED).
_source_orchestrator_functions() {
	local func_file="$TEST_TMP/orchestrator_funcs.bash"
	awk '
		/^readonly /                          { next }
		/^set -o /                            { next }
		/^log_error\(\) \{$/,/^\}$/          { print; next }
		/^sync_status_to_log\(\) \{$/,/^\}$/ { print; next }
		/^emit_event\(\) \{$/,/^\}$/         { print; next }
		/^set_stage_failed\(\) \{$/,/^\}$/   { print; next }
		/^check_run_budget\(\) \{$/,/^\}$/   { print; next }
		/^set_run_budget_exceeded\(\) \{$/,/^\}$/ { print; next }
		/^_apply_stage_action\(\) \{$/,/^\}$/ { print; next }
	' "$ORCHESTRATOR" > "$func_file"
	# shellcheck disable=SC1090
	source "$func_file"
}

# Minimal stage_result JSON with status=error and error_kind=double_timeout.
# This is the envelope produced by run_stage() when a bail decision is reached.
# The .stage field is intentionally set to a DECOY value distinct from
# $_RUN_STAGE_NAME so the assertion can verify _apply_stage_action reads the
# stage name from the global (correct) rather than from this envelope (the
# bug pattern that emitted an empty/wrong stage_end before issue #280).
_bail_stage_result() {
	printf '%s' \
		'{"status":"error","output":null,"raw":"","denials":[],' \
		'"model":"haiku","error_kind":"double_timeout","elapsed_ms":500,' \
		'"stage":"DECOY_STAGE_FROM_ENVELOPE"}'
}

# Assert that events.jsonl contains at least one stage_end event with
# status=error and a .stage field that exactly matches $_RUN_STAGE_NAME.
# Matching the global (not the envelope's decoy) is the meaningful check:
# it proves _apply_stage_action used the run_stage-tracked stage name, not
# the stage_result JSON.
# Prints diagnostics to stderr on failure.
_assert_stage_end_error_in_events() {
	local events_file="$LOG_BASE/events.jsonl"

	if [[ ! -f "$events_file" ]]; then
		printf 'FAIL: events.jsonl was not created — stage_end was never emitted\n' >&2
		return 1
	fi

	local found_status
	found_status=$(jq -r \
		'select(.event == "stage_end" and .status == "error") | .status' \
		"$events_file" 2>/dev/null)

	if [[ "$found_status" != "error" ]]; then
		printf 'FAIL: stage_end status=error not found in events.jsonl\n' >&2
		printf 'events.jsonl contents:\n' >&2
		cat "$events_file" >&2 || printf '(empty or unreadable)\n' >&2
		return 1
	fi

	local found_stage
	found_stage=$(jq -r \
		'select(.event == "stage_end" and .status == "error") | .stage // ""' \
		"$events_file" 2>/dev/null)

	if [[ -z "$found_stage" ]]; then
		printf 'FAIL: stage_end status=error has empty .stage field in events.jsonl\n' >&2
		printf 'events.jsonl contents:\n' >&2
		cat "$events_file" >&2 || printf '(empty or unreadable)\n' >&2
		return 1
	fi

	if [[ "$found_stage" != "$_RUN_STAGE_NAME" ]]; then
		printf 'FAIL: stage_end .stage=%s does not match _RUN_STAGE_NAME=%s\n' \
			"$found_stage" "$_RUN_STAGE_NAME" >&2
		printf '(implementation likely read .stage from stage_result envelope ' >&2
		printf 'instead of the run_stage-tracked global)\n' >&2
		printf 'events.jsonl contents:\n' >&2
		cat "$events_file" >&2 || printf '(empty or unreadable)\n' >&2
		return 1
	fi
}

# ===========================================================================
# (1) event-emit.sh schema accepts a well-formed stage_end status=error event
# ===========================================================================

@test "(1) event-emit.sh validates and appends stage_end status=error to events.jsonl" {
	[[ -x "$EVENT_EMIT" ]] \
		|| fail "event-emit.sh not present or not executable"

	local event
	event=$(jq -cn \
		--arg ts "$(date -Iseconds)" \
		--arg run_id "test-run-event-emission" \
		--arg stage "bail_test_stage" \
		'{ts: $ts, run_id: $run_id, event: "stage_end", stage: $stage, status: "error"}')

	LOG_DIR="$LOG_BASE" run --separate-stderr "$EVENT_EMIT" "$event"
	[ "$status" -eq 0 ]

	_assert_stage_end_error_in_events
}

# ===========================================================================
# (2) _apply_stage_action bail) emits stage_end status=error
# ===========================================================================

@test "(2) _apply_stage_action bail produces stage_end status=error in events.jsonl" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "implement-issue-orchestrator.sh not present"
	[[ -x "$EVENT_EMIT" ]] \
		|| fail "event-emit.sh not present or not executable"

	_source_orchestrator_functions

	local stage_result
	stage_result=$(_bail_stage_result)

	# _apply_stage_action returns 1 for bail; ignore the non-zero exit so the
	# test can inspect events.jsonl rather than aborting on the return code.
	_apply_stage_action "$stage_result" "bail" "double_timeout" || true

	_assert_stage_end_error_in_events
}

# ===========================================================================
# (3) _apply_stage_action *) unknown-action emits stage_end status=error
# ===========================================================================

@test "(3) _apply_stage_action unknown-action produces stage_end status=error in events.jsonl" {
	[[ -f "$ORCHESTRATOR" ]] \
		|| fail "implement-issue-orchestrator.sh not present"
	[[ -x "$EVENT_EMIT" ]] \
		|| fail "event-emit.sh not present or not executable"

	_source_orchestrator_functions

	local stage_result
	stage_result=$(_bail_stage_result)

	# Unknown action string triggers the wildcard *) branch, which also
	# returns 1; ignore the exit code and inspect events.jsonl directly.
	_apply_stage_action "$stage_result" "completely_unknown_action" "test" || true

	_assert_stage_end_error_in_events
}

# ===========================================================================
# Helpers for tests (4)-(9): batch-orchestrator.sh issue_end outcome (#809)
# ===========================================================================

# Extract process_issue(), emit_event(), and the main per-issue loop from
# batch-orchestrator.sh, with every external dependency they touch stubbed
# out first. git/setsid/gh-backed helpers must never touch this worktree or
# the network; dispatch_composition/perform_scripted_merge stand in for the
# process-pr agent call and the merge step so test (8) can drive
# process_issue() through its real completed -> approved -> merged path.
#
# The main loop (`for issue in "${ISSUE_ARRAY[@]}"; do ... done`) is not a
# function in the source file, so it is captured by anchoring on its literal
# start/end text (not line numbers) and wrapped in a function here. This
# survives tasks 1/2 adding lines inside process_issue() above it, since the
# anchors are outside the part of the file those tasks touch.
_source_batch_orchestrator_functions() {
	local func_file="$TEST_TMP/batch_orch_funcs.bash"

	export BRANCH="main"
	export MAX_CONSECUTIVE_FAILURES=5
	export PLATFORM_DIR="$TEST_TMP/platform"
	mkdir -p "$PLATFORM_DIR"
	printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$PLATFORM_DIR/transition-issue.sh"
	chmod +x "$PLATFORM_DIR/transition-issue.sh"

	cat > "$func_file" <<'STUBS'
git() { return 0; }
setsid() { return 0; }
validate_issue_for_processing() { return 0; }
update_issue_field() { :; }
update_progress() { :; }
set_current_issue() { :; }
set_state() { :; }
log() { :; }
log_warn() { :; }
log_error() { :; }
check_issue_pr_merged() { return 1; }
check_issue_resolved_upstream() { return 1; }
wait_for_pr_merged() { return 0; }
check_batch_budget() { return 0; }
detect_rate_limit() { return 1; }
dispatch_composition() { printf '%s\n' '{"structured_output":{"status":"approved","follow_up_issues":[]}}'; }
perform_scripted_merge() { return 0; }
STUBS

	awk '
		/^process_issue\(\) \{$/,/^\}$/ { print; next }
		/^emit_event\(\) \{$/,/^\}$/    { print; next }
	' "$BATCH_ORCHESTRATOR" >> "$func_file"

	{
		printf '%s\n' '_run_issue_loop() {'
		awk '
			/^for issue in "\$\{ISSUE_ARRAY\[@\]\}"; do$/ { found=1 }
			found { print }
			found && /^done$/ { exit }
		' "$BATCH_ORCHESTRATOR"
		printf '%s\n' '}'
	} >> "$func_file"

	consecutive_failures=0
	exit_code=0

	# shellcheck disable=SC1090
	source "$func_file"
}

# Writes $STATUS_FILE with a .issues[] entry (status "pending", so the
# up-front `current_status == completed` skip gate does not fire) for each
# issue number passed.
_write_batch_status_file() {
	local issues_json="[]" n
	for n in "$@"; do
		issues_json=$(jq -c --arg num "$n" \
			'. + [{number: $num, status: "pending"}]' <<< "$issues_json")
	done
	jq -n --argjson issues "$issues_json" '{issues: $issues}' > "$STATUS_FILE"
}

# Writes the per-issue status file process_issue() reads via
# $LOG_BASE/issue-<num>-status.json. $3, if given, becomes
# .stages.pr.pr_number (mirrors what implement-issue-orchestrator.sh records
# for merge_blocked/budget_exceeded/completed states).
_write_issue_status_file() {
	local num="$1" state="$2" pr="${3:-}"
	if [[ -n "$pr" ]]; then
		jq -n --arg state "$state" --argjson pr "$pr" \
			'{state: $state, stages: {pr: {pr_number: $pr}}}' \
			> "$LOG_BASE/issue-$num-status.json"
	else
		jq -n --arg state "$state" '{state: $state}' \
			> "$LOG_BASE/issue-$num-status.json"
	fi
}

# Asserts the most recent issue_end event for issue $1 has outcome $2.
_assert_issue_end_outcome() {
	local num="$1" expected="$2"
	local events_file="$LOG_BASE/events.jsonl"

	if [[ ! -f "$events_file" ]]; then
		printf 'FAIL: events.jsonl was not created for issue #%s\n' "$num" >&2
		return 1
	fi

	local found
	found=$(jq -r --arg num "$num" \
		'select(.event == "issue_end" and .issue_num == $num) | .outcome' \
		"$events_file" 2>/dev/null | tail -1)

	if [[ "$found" != "$expected" ]]; then
		printf 'FAIL: issue #%s issue_end outcome=%s, expected %s\n' \
			"$num" "${found:-<none>}" "$expected" >&2
		printf 'events.jsonl contents:\n' >&2
		cat "$events_file" >&2 || printf '(empty or unreadable)\n' >&2
		return 1
	fi
}

# ===========================================================================
# (4) merge_blocked terminal state -> issue_end outcome=merge_blocked
# ===========================================================================

@test "(4) process_issue merge_blocked state produces issue_end outcome=merge_blocked" {
	[[ -f "$BATCH_ORCHESTRATOR" ]] \
		|| fail "batch-orchestrator.sh not present"

	_source_batch_orchestrator_functions

	ISSUE_ARRAY=("501")
	_write_batch_status_file "501"
	_write_issue_status_file "501" "merge_blocked" "42"

	_run_issue_loop

	_assert_issue_end_outcome "501" "merge_blocked"

	# AC4: a quality-gate hold must not trip the circuit breaker.
	[[ "$consecutive_failures" -eq 0 ]] || {
		printf \
			'FAIL: merge_blocked incremented consecutive_failures to %s\n' \
			"$consecutive_failures" >&2
		return 1
	}
}

# ===========================================================================
# (5) budget_exceeded terminal state -> issue_end outcome=budget_exceeded
# ===========================================================================

@test "(5) process_issue budget_exceeded state produces issue_end outcome=budget_exceeded" {
	[[ -f "$BATCH_ORCHESTRATOR" ]] \
		|| fail "batch-orchestrator.sh not present"

	_source_batch_orchestrator_functions

	ISSUE_ARRAY=("502")
	_write_batch_status_file "502"
	_write_issue_status_file "502" "budget_exceeded"

	_run_issue_loop

	_assert_issue_end_outcome "502" "budget_exceeded"

	# AC4: a per-run spend halt must not trip the circuit breaker.
	[[ "$consecutive_failures" -eq 0 ]] || {
		printf \
			'FAIL: budget_exceeded incremented consecutive_failures to %s\n' \
			"$consecutive_failures" >&2
		return 1
	}
}

# ===========================================================================
# (6) already_implemented terminal state -> issue_end outcome=already_done
# ===========================================================================

@test "(6) process_issue already_implemented state produces issue_end outcome=already_done" {
	[[ -f "$BATCH_ORCHESTRATOR" ]] \
		|| fail "batch-orchestrator.sh not present"

	_source_batch_orchestrator_functions

	ISSUE_ARRAY=("503")
	_write_batch_status_file "503"
	_write_issue_status_file "503" "already_implemented"

	_run_issue_loop

	_assert_issue_end_outcome "503" "already_done"

	[[ "$consecutive_failures" -eq 0 ]] || {
		printf \
			'FAIL: already_implemented incremented consecutive_failures to %s\n' \
			"$consecutive_failures" >&2
		return 1
	}
}

# ===========================================================================
# (7) generic processing error -> issue_end outcome=failed (regression)
# ===========================================================================

@test "(7) process_issue generic error state still produces issue_end outcome=failed" {
	[[ -f "$BATCH_ORCHESTRATOR" ]] \
		|| fail "batch-orchestrator.sh not present"

	_source_batch_orchestrator_functions

	ISSUE_ARRAY=("504")
	_write_batch_status_file "504"
	_write_issue_status_file "504" "error"

	_run_issue_loop

	_assert_issue_end_outcome "504" "failed"

	# A genuine failure must still trip the circuit breaker path.
	[[ "$consecutive_failures" -eq 1 ]] || {
		printf \
			'FAIL: expected consecutive_failures=1 after a real failure, got %s\n' \
			"$consecutive_failures" >&2
		return 1
	}
}

# ===========================================================================
# (8) genuinely merged issue -> issue_end outcome=success (regression)
# ===========================================================================

@test "(8) process_issue completed+merged state still produces issue_end outcome=success" {
	[[ -f "$BATCH_ORCHESTRATOR" ]] \
		|| fail "batch-orchestrator.sh not present"

	_source_batch_orchestrator_functions

	ISSUE_ARRAY=("505")
	_write_batch_status_file "505"
	_write_issue_status_file "505" "completed" "77"

	_run_issue_loop

	_assert_issue_end_outcome "505" "success"

	[[ "$consecutive_failures" -eq 0 ]] || {
		printf \
			'FAIL: a genuine success incremented consecutive_failures to %s\n' \
			"$consecutive_failures" >&2
		return 1
	}
}

# ===========================================================================
# (9) two issues, one batch: no outcome leakage between process_issue calls
# ===========================================================================

@test "(9) merge_blocked then budget_exceeded in one batch each emit their own outcome" {
	[[ -f "$BATCH_ORCHESTRATOR" ]] \
		|| fail "batch-orchestrator.sh not present"

	_source_batch_orchestrator_functions

	ISSUE_ARRAY=("506" "507")
	_write_batch_status_file "506" "507"
	_write_issue_status_file "506" "merge_blocked" "10"
	_write_issue_status_file "507" "budget_exceeded"

	_run_issue_loop

	# The risk this guards against (per issue #809's evaluation): a stale
	# module-level variable leaking issue #506's outcome into #507's event.
	_assert_issue_end_outcome "506" "merge_blocked"
	_assert_issue_end_outcome "507" "budget_exceeded"

	[[ "$consecutive_failures" -eq 0 ]] || {
		printf \
			'FAIL: two non-failure terminal states incremented consecutive_failures to %s\n' \
			"$consecutive_failures" >&2
		return 1
	}
}
