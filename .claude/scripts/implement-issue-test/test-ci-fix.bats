#!/usr/bin/env bats
#
# test-ci-fix.bats
# Tests for the merge-stage CI fix helpers (#1141): the failed-log excerpt
# and the bounded wait for a check to appear on a given head sha.
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env

	export ISSUE_NUMBER=123
	export BASE_BRANCH=test
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

	source_orchestrator_functions

	# Stub platform directory with a read-mr-checks.sh driven by files.
	PLATFORM_DIR="$TEST_TMP/platform"
	mkdir -p "$PLATFORM_DIR"
	cat > "$PLATFORM_DIR/read-mr-checks.sh" <<'STUB'
#!/usr/bin/env bash
cat "$STUB_CHECKS_JSON"
STUB
	chmod +x "$PLATFORM_DIR/read-mr-checks.sh"
	export STUB_CHECKS_JSON="$TEST_TMP/checks.json"
	export CI_FIX_RERUN_POLL_INTERVAL=1
	export CI_FIX_RERUN_WAIT_MAX=2
}

teardown() {
	teardown_test_env
}

# Builds a 300-line log with one "not ok" block 150 lines from the end.
make_log() {
	local i
	for ((i = 1; i <= 300; i++)); do
		if ((i == 150)); then
			printf 'not ok 7 an incidental block still parks\n'
			printf '# (in test file x.bats, line 12)\n'
			printf "#   \`[[ \$x == y ]]' failed\n"
		elif ((i > 150 && i < 153)); then
			continue
		else
			printf 'ordinary line %d\n' "$i"
		fi
	done
}

# =============================================================================
# _ci_failure_excerpt
# =============================================================================

@test "excerpt keeps the not ok line and the # lines under it" {
	local log out
	log=$(make_log)
	out=$(_ci_failure_excerpt "$log")

	[[ "$out" == *'not ok 7 an incidental block still parks'* ]]
	[[ "$out" == *'# (in test file x.bats, line 12)'* ]]
	[[ "$out" == *"failed"* ]]
}

@test "excerpt is at most 80 lines and omits the plain tail" {
	local log out count
	log=$(make_log)
	out=$(_ci_failure_excerpt "$log")
	count=$(wc -l <<< "$out")

	((count <= 80))
	[[ "$out" != *'ordinary line 300'* ]]
}

@test "excerpt falls back to the last 80 lines without a signature" {
	local log out count
	log=$(for i in {1..200}; do printf 'plain %d\n' "$i"; done)
	out=$(_ci_failure_excerpt "$log")
	count=$(wc -l <<< "$out")

	((count == 80))
	[[ "$out" == *'plain 200'* ]]
	[[ "$out" == *'plain 121'* ]]
	[[ "$out" != *'plain 120'$'\n'* ]]
}

@test "excerpt caps many not ok blocks at 80 lines" {
	local log out count
	log=$(for i in {1..100}; do
		printf 'not ok %d t\n# detail %d\n' "$i" "$i"
	done)
	out=$(_ci_failure_excerpt "$log")
	count=$(wc -l <<< "$out")

	((count == 80))
}

@test "excerpt of empty input prints nothing" {
	local out
	out=$(_ci_failure_excerpt "")

	[[ -z "$out" ]]
}

# =============================================================================
# _wait_for_check_on_head
# =============================================================================

@test "wait returns 0 when the head sha and check name are present" {
	printf '%s\n' '{"head_sha":"abc","checks":[{"name":"Bats","status":"in_progress"}]}' \
		> "$STUB_CHECKS_JSON"

	run _wait_for_check_on_head 5 abc Bats
	[[ "$status" -eq 0 ]]
}

@test "wait returns 1 when the check name never appears" {
	printf '%s\n' '{"head_sha":"abc","checks":[{"name":"Other","status":"completed"}]}' \
		> "$STUB_CHECKS_JSON"

	run _wait_for_check_on_head 5 abc Bats
	[[ "$status" -eq 1 ]]
}

@test "wait returns 1 when the check is only on a different head sha" {
	printf '%s\n' '{"head_sha":"old","checks":[{"name":"Bats","status":"completed"}]}' \
		> "$STUB_CHECKS_JSON"

	run _wait_for_check_on_head 5 new Bats
	[[ "$status" -eq 1 ]]
}

@test "wait succeeds once the new head appears during polling" {
	printf '%s\n' '{"head_sha":"old","checks":[]}' > "$STUB_CHECKS_JSON"
	(
		sleep 1
		printf '%s\n' '{"head_sha":"new","checks":[{"name":"Bats","status":"queued"}]}' \
			> "$STUB_CHECKS_JSON"
	) &
	CI_FIX_RERUN_WAIT_MAX=6

	run _wait_for_check_on_head 5 new Bats
	[[ "$status" -eq 0 ]]
}
