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

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
ORCHESTRATOR="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"
EVENT_EMIT="$REPO_ROOT/.claude/scripts/event-emit.sh"

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
