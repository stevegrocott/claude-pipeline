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
	! grep -q 'RED' "$COMMENT_FILE" || false
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
