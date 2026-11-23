#!/usr/bin/env bats
#
# test-full-suite-check.bats
# Crash-vs-failure classification for the informational Jest/npm full-suite
# check in implement-issue-orchestrator.sh (#977). Drives the REAL block,
# extracted from the orchestrator, over mocked runner output — a crashed
# runner (OOM / stack dump) must classify as unmeasured, not RED, and the
# captured detail must keep the cause line.

load 'helpers/test-helper.bash'

setup() {
	setup_test_env
	DEGRADED_STAGES=()
	COMMENT_FILE="$TEST_TMP/comment.txt"
	: > "$COMMENT_FILE"
	BASE_BRANCH=main
	branch_scope=typescript
	TEST_UNIT_CMD="bash $TEST_TMP/mock-runner.sh"
}

teardown() {
	teardown_test_env
}

# Extract the live npm full-suite block (from its opening `if` to the line
# before the BATS sibling's banner comment) and define it as a function.
_load_full_suite_block() {
	local orch="$BATS_TEST_DIRNAME/../implement-issue-orchestrator.sh"
	{
		echo '_full_suite_block() {'
		awk '
			/Running informational full-suite check/ { grab = 1; print "if true; then"; print; next }
			grab && /NON-BLOCKING FULL-SUITE BATS CHECK/ { exit }
			grab { print }
		' "$orch" | sed '$d' | sed '$d'
		echo '}'
	} > "$TEST_TMP/block.sh"
	# shellcheck disable=SC1091
	source "$TEST_TMP/block.sh"
	# Real helpers the block calls, extracted from the orchestrator.
	local fn
	for fn in _full_suite_runner_crashed _full_suite_cause_lines; do
		# shellcheck disable=SC1090
		source <(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {g=1} g {print} g && /^}/ {exit}' "$orch")
	done

	log() { :; }
	log_warn() { :; }
	comment_issue() { printf '%s\n%s\n' "$1" "$2" >> "$COMMENT_FILE"; }
	# Mock bounded runner: run the command, capture output to $3, return rc.
	_run_bounded_process_group() {
		local out="$3"
		shift 3
		"$@" > "$out" 2>&1
	}
}

_write_runner() {
	local body="$1"
	printf '#!/usr/bin/env bash\n%s\n' "$body" > "$TEST_TMP/mock-runner.sh"
}

@test "block extraction finds the real full-suite check" {
	_load_full_suite_block
	grep -q '_run_bounded_process_group' "$TEST_TMP/block.sh"
	grep -q 'full_suite_red' "$TEST_TMP/block.sh"
}

@test "genuine Jest failure classifies RED with failing test names surfaced" {
	_write_runner 'cat <<OUT
 FAIL  src/services/crop.test.ts
  ● CropService › computes yield for wheat
    expect(received).toBe(expected)
Test Suites: 1 failed, 3 passed, 4 total
Tests:       1 failed, 20 passed, 21 total
OUT
exit 1'
	_load_full_suite_block
	_full_suite_block || true
	[[ " ${DEGRADED_STAGES[*]} " == *" test:full_suite_red "* ]]
	grep -q 'RED' "$COMMENT_FILE"
	grep -q 'computes yield for wheat' "$COMMENT_FILE"
}

@test "OOM crash dump classifies unmeasured, not RED, with FATAL ERROR surfaced" {
	_write_runner 'echo "FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory"
for i in $(seq 1 30); do echo "$i: 0x1054e0bec Builtins_InterpreterEntryTrampoline [/opt/homebrew/Cellar/node/24.4.1/bin/node]"; done
exit 134'
	_load_full_suite_block
	_full_suite_block || true
	[[ " ${DEGRADED_STAGES[*]} " != *" test:full_suite_red "* ]]
	! grep -qw 'RED' "$COMMENT_FILE" || false
	! grep -qi 'review before merge' "$COMMENT_FILE" || false
	grep -qi 'unmeasured' "$COMMENT_FILE"
	grep -q 'FATAL ERROR' "$COMMENT_FILE"
}

@test "200 identical stack frames do not evict the cause line" {
	_write_runner 'echo "FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory"
for i in $(seq 1 200); do echo "0x1054e0bec Builtins_InterpreterEntryTrampoline [/opt/homebrew/Cellar/node/24.4.1/bin/node]"; done
exit 134'
	_load_full_suite_block
	_full_suite_block || true
	grep -q 'FATAL ERROR' "$COMMENT_FILE"
	local frames
	frames=$(grep -c 'Builtins_InterpreterEntryTrampoline' "$COMMENT_FILE" || true)
	(( frames < 40 ))
}

@test "green run records no degraded stage and posts no comment" {
	_write_runner 'echo "Tests: 5 passed, 5 total"; exit 0'
	_load_full_suite_block
	_full_suite_block || true
	[ "${#DEGRADED_STAGES[@]}" -eq 0 ]
	[ ! -s "$COMMENT_FILE" ]
}

# =============================================================================
# GREEN BATS FULL SUITE SUPERSEDES bats_incomplete MARKS (#1152)
# =============================================================================

_load_bats_outcome_fns() {
	local orch="$BATS_TEST_DIRNAME/../implement-issue-orchestrator.sh"
	local fn
	for fn in _supersede_bats_incomplete_marks \
		_bats_full_suite_outcome _bats_full_suite_failure_count; do
		# shellcheck disable=SC1090
		source <(awk -v f="$fn" '$0 ~ "^"f"\\(\\) \\{" {g=1} g {print} g && /^}/ {exit}' "$orch")
	done
	log() { :; }
	log_warn() { :; }
	comment_issue() { printf '%s\n%s\n' "$1" "$2" >> "$COMMENT_FILE"; }
}

@test "green BATS full suite collapses bats_incomplete marks into exactly one superseded entry" {
	_load_bats_outcome_fns
	DEGRADED_STAGES=("test:bats_incomplete:iter=1" "test:other" \
		"test:bats_incomplete:iter=2")
	_bats_full_suite_outcome 0 "ok 1 a" "$TEST_TMP/log"
	[ "${#DEGRADED_STAGES[@]}" -eq 2 ]
	[ "${DEGRADED_STAGES[0]}" = "test:other" ]
	[ "${DEGRADED_STAGES[1]}" = "test:bats_incomplete_superseded" ]
	[ -s "$COMMENT_FILE" ]
	grep -q 'supersede' "$COMMENT_FILE"
}

@test "green BATS full suite syncs the superseded list to the status file" {
	_load_bats_outcome_fns
	STATUS_FILE="$TEST_TMP/status.json"
	echo '{"degraded_stages":["test:bats_incomplete:iter=1","test:other"]}' > "$STATUS_FILE"
	status_json_write() { local t; t=$(jq "$@" "$STATUS_FILE") && printf '%s' "$t" > "$STATUS_FILE"; }
	sync_status_to_log() { :; }
	DEGRADED_STAGES=("test:bats_incomplete:iter=1" "test:other")
	_bats_full_suite_outcome 0 "ok 1 a" "$TEST_TMP/log"
	[ "$(jq -c '.degraded_stages' "$STATUS_FILE")" = '["test:other","test:bats_incomplete_superseded"]' ]
}

@test "unmeasured BATS full suite leaves bats_incomplete marks intact and posts no supersede comment" {
	_load_bats_outcome_fns
	DEGRADED_STAGES=("test:bats_incomplete:iter=1")
	_bats_full_suite_outcome 1 "" "$TEST_TMP/log"
	[ "${DEGRADED_STAGES[0]}" = "test:bats_incomplete:iter=1" ]
	[ "${DEGRADED_STAGES[1]}" = "test:bats_full_suite_unmeasured" ]
	! grep -q 'supersede' "$COMMENT_FILE" || return 1
}

@test "red BATS full suite leaves bats_incomplete marks intact" {
	_load_bats_outcome_fns
	DEGRADED_STAGES=("test:bats_incomplete:iter=1")
	_bats_full_suite_outcome 1 "not ok 1 broken" "$TEST_TMP/log" r.sh x
	[ "${DEGRADED_STAGES[0]}" = "test:bats_incomplete:iter=1" ]
	[ "${DEGRADED_STAGES[1]}" = "test:bats_full_suite_red" ]
}

@test "timed-out BATS full suite leaves bats_incomplete marks intact" {
	_load_bats_outcome_fns
	DEGRADED_STAGES=("test:bats_incomplete:iter=1")
	_bats_full_suite_outcome 124 "" "$TEST_TMP/log"
	[ "${DEGRADED_STAGES[0]}" = "test:bats_incomplete:iter=1" ]
	[ "${DEGRADED_STAGES[1]}" = "test:bats_full_suite_timeout" ]
}

@test "green BATS full suite with empty DEGRADED_STAGES stays empty" {
	_load_bats_outcome_fns
	DEGRADED_STAGES=()
	_bats_full_suite_outcome 0 "ok 1 a" "$TEST_TMP/log"
	[ "${#DEGRADED_STAGES[@]}" -eq 0 ]
}
