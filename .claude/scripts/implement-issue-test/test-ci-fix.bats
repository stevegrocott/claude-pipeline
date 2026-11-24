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

# =============================================================================
# _ci_fix_attempt
# =============================================================================

# Real git repo plus a run_stage stub. STUB_STAGE_ACTION picks what the fake
# fix stage does: commit, commit_workflow, dirty or nothing.
fix_setup() {
	git init -q "$TEST_TMP/repo"
	cd "$TEST_TMP/repo" || return 1
	git config user.email t@example.com
	git config user.name t
	printf 'a\n' > a.sh
	git add a.sh
	git commit -q -m init

	cat > "$PLATFORM_DIR/read-mr-checks.sh" <<'STUB'
#!/usr/bin/env bash
[[ "$2" == "--failed-log" ]] || exit 0
printf '%s' "$STUB_FAILED_LOG"
STUB
	export STUB_FAILED_LOG
	STUB_FAILED_LOG=$(make_log)
	STAGE_NAME_FILE="$TEST_TMP/stage-name"
	STAGE_PROMPT_FILE="$TEST_TMP/stage-prompt"
	STAGE_SCHEMA_FILE="$TEST_TMP/stage-schema"
	STUB_STAGE_ACTION=commit

	_halt_if_budget_exceeded() { :; }
	_halt_if_api_error() { :; }
	run_stage() {
		printf '%s' "$1" > "$STAGE_NAME_FILE"
		printf '%s' "$2" > "$STAGE_PROMPT_FILE"
		printf '%s' "$3" > "$STAGE_SCHEMA_FILE"
		case "$STUB_STAGE_ACTION" in
			commit)
				printf 'b\n' >> a.sh
				git commit -q -am "fix ci"
				;;
			commit_workflow)
				mkdir -p .github/workflows
				printf 'x: 1\n' > .github/workflows/ci.yml
				git add .github
				git commit -q -m "touch workflow"
				;;
			dirty)
				printf 'c\n' >> a.sh
				;;
		esac
		printf '{"status":"success"}'
	}
}

@test "fix attempt saves the full log and runs a fix-ci-iter stage" {
	fix_setup

	run _ci_fix_attempt 7 "Bats Suite" 1
	[[ "$status" -eq 0 ]]

	[[ "$(< "$STAGE_NAME_FILE")" == fix-ci-iter-1 ]]
	[[ "$(< "$STAGE_SCHEMA_FILE")" == implement-issue-fix.json ]]
	local saved
	saved=$(< "$LOG_BASE/ci-failed-log-iter-1.log")
	[[ "$saved" == *'ordinary line 300'* ]]
}

@test "fix prompt carries the check, excerpt, log path and three rules" {
	fix_setup

	run _ci_fix_attempt 7 "Bats Suite" 1
	[[ "$status" -eq 0 ]]

	local prompt
	prompt=$(< "$STAGE_PROMPT_FILE")
	[[ "$prompt" == *'"Bats Suite"'* ]]
	[[ "$prompt" == *'not ok 7 an incidental block still parks'* ]]
	[[ "$prompt" == *"$LOG_BASE/ci-failed-log-iter-1.log"* ]]
	[[ "$prompt" == *'smallest change that fixes this failure'* ]]
	[[ "$prompt" == *'Change an existing test only where this issue deliberately changed the behaviour it asserts, and say so in the commit message'* ]]
	[[ "$prompt" == *'Change nothing if the failure is not caused by this branch'* ]]
}

@test "fix attempt fails without running a stage when the log is empty" {
	fix_setup
	STUB_FAILED_LOG=""

	run _ci_fix_attempt 7 "Bats Suite" 1
	[[ "$status" -ne 0 ]]
	[[ ! -e "$STAGE_NAME_FILE" ]]
}

@test "fix attempt fails when the stage commits nothing" {
	fix_setup
	STUB_STAGE_ACTION=nothing

	run _ci_fix_attempt 7 "Bats Suite" 1
	[[ "$status" -ne 0 ]]
}

@test "fix attempt fails when the stage leaves uncommitted changes" {
	fix_setup
	STUB_STAGE_ACTION=dirty

	run _ci_fix_attempt 7 "Bats Suite" 1
	[[ "$status" -ne 0 ]]
}

@test "fix attempt fails when the path guard rejects the commit" {
	fix_setup
	STUB_STAGE_ACTION=commit_workflow

	run _ci_fix_attempt 7 "Bats Suite" 1
	[[ "$status" -ne 0 ]]
	[[ "$output" == *"hard-denied"* || "$output" == *"CI fix rejected"* ]]
}

# =============================================================================
# _ci_fix_push_and_wait
# =============================================================================

# Repo with a bare origin, one fix commit on top, comment_pr recorded.
push_setup() {
	git init -q --bare "$TEST_TMP/origin.git"
	git init -q -b feat "$TEST_TMP/prepo"
	cd "$TEST_TMP/prepo" || return 1
	git config user.email t@example.com
	git config user.name t
	git remote add origin "$TEST_TMP/origin.git"
	printf 'a\n' > a.sh
	git add a.sh
	git commit -q -m init
	git push -q origin feat
	PUSH_BEFORE=$(git rev-parse HEAD)
	printf 'b\n' >> a.sh
	printf 'n\n' > new.sh
	git add new.sh
	git commit -q -am "fix ci"

	COMMENT_FILE="$TEST_TMP/comment"
	comment_pr() { printf '%s\n%s' "$2" "$3" > "$COMMENT_FILE"; }
	printf '%s\n' "{\"head_sha\":\"$(git rev-parse HEAD)\",\"checks\":[{\"name\":\"Bats\",\"status\":\"queued\"}]}" \
		> "$STUB_CHECKS_JSON"
}

@test "push verified, comment lists changed files, rerun awaited" {
	push_setup

	run _ci_fix_push_and_wait 5 Bats 1 feat "$PUSH_BEFORE"
	[[ "$status" -eq 0 ]]

	[[ "$(git ls-remote origin refs/heads/feat | cut -f1)" == "$(git rev-parse HEAD)" ]]
	local c
	c=$(< "$COMMENT_FILE")
	[[ "$c" == *'CI Fix'* ]]
	[[ "$c" == *'`a.sh`'* ]]
	[[ "$c" == *'`new.sh`'* ]]
}

@test "push failure returns 1 and posts no comment" {
	push_setup
	git remote set-url origin "$TEST_TMP/missing.git"

	run _ci_fix_push_and_wait 5 Bats 1 feat "$PUSH_BEFORE"
	[[ "$status" -eq 1 ]]
	[[ ! -e "$COMMENT_FILE" ]]
}

@test "remote head mismatch after push returns 1 and posts no comment" {
	push_setup
	git() {
		if [[ "$1" == ls-remote ]]; then
			printf 'deadbeef\trefs/heads/feat\n'
			return 0
		fi
		command git "$@"
	}

	run _ci_fix_push_and_wait 5 Bats 1 feat "$PUSH_BEFORE"
	[[ "$status" -eq 1 ]]
	[[ ! -e "$COMMENT_FILE" ]]
}

@test "returns 1 when the rerun never appears on the new head" {
	push_setup
	printf '%s\n' '{"head_sha":"old","checks":[]}' > "$STUB_CHECKS_JSON"

	run _ci_fix_push_and_wait 5 Bats 1 feat "$PUSH_BEFORE"
	[[ "$status" -eq 1 ]]
	[[ -e "$COMMENT_FILE" ]]
}

# =============================================================================
# _merge_with_ci_fix
# =============================================================================

# Stubs merge-mr.sh: declines with check_failed on the first STUB_DECLINES
# runs (writing MERGE_MR_DECLINE_FILE), then succeeds. Fix helpers are stubbed.
merge_setup() {
	export MERGE_MR_STEP_TIMEOUT=10
	MERGE_RUNS="$TEST_TMP/merge-runs"
	FIX_CALLS="$TEST_TMP/fix-calls"
	: > "$MERGE_RUNS"
	: > "$FIX_CALLS"
	export MERGE_RUNS STUB_DECLINES=1 STUB_KIND=check_failed
	cat > "$PLATFORM_DIR/merge-mr.sh" <<'STUB'
#!/usr/bin/env bash
printf 'run\n' >> "$MERGE_RUNS"
n=$(wc -l < "$MERGE_RUNS")
if ((n <= STUB_DECLINES)); then
	printf '%s\tBats\n' "$STUB_KIND" > "$MERGE_MR_DECLINE_FILE"
	exit 1
fi
exit 0
STUB
	chmod +x "$PLATFORM_DIR/merge-mr.sh"
	STUB_FIX_RC=0
	_ci_fix_attempt() { printf 'attempt %s %s %s\n' "$@" >> "$FIX_CALLS"; return "$STUB_FIX_RC"; }
	_ci_fix_push_and_wait() { printf 'push %s\n' "$3" >> "$FIX_CALLS"; return 0; }
}

@test "merge retries once after a CI fix and succeeds" {
	merge_setup
	local rc=0
	_merge_with_ci_fix 5 feat || rc=$?
	[[ "$rc" -eq 0 ]]
	[[ "$(wc -l < "$MERGE_RUNS")" -eq 2 ]]
	grep -q 'attempt 5 Bats 1' "$FIX_CALLS"
	grep -q 'push 1' "$FIX_CALLS"
}

@test "MAX_CI_FIX_ITERATIONS=0 never attempts a fix" {
	merge_setup
	MAX_CI_FIX_ITERATIONS=0
	local rc=0
	_merge_with_ci_fix 5 feat || rc=$?
	[[ "$rc" -eq 1 ]]
	[[ "$(wc -l < "$MERGE_RUNS")" -eq 1 ]]
	[[ ! -s "$FIX_CALLS" ]]
}

@test "merge stops after the iteration cap" {
	merge_setup
	STUB_DECLINES=5
	MAX_CI_FIX_ITERATIONS=2
	local rc=0
	_merge_with_ci_fix 5 feat || rc=$?
	[[ "$rc" -eq 1 ]]
	[[ "$(wc -l < "$MERGE_RUNS")" -eq 3 ]]
	[[ "$(grep -c '^attempt' "$FIX_CALLS")" -eq 2 ]]
}

@test "a non-CI decline is not retried" {
	merge_setup
	STUB_KIND=other
	local rc=0
	_merge_with_ci_fix 5 feat || rc=$?
	[[ "$rc" -eq 1 ]]
	[[ "$(wc -l < "$MERGE_RUNS")" -eq 1 ]]
	[[ ! -s "$FIX_CALLS" ]]
}

@test "a failed fix attempt returns the merge decline without retrying" {
	merge_setup
	STUB_FIX_RC=1
	local rc=0
	_merge_with_ci_fix 5 feat || rc=$?
	[[ "$rc" -eq 1 ]]
	[[ "$(wc -l < "$MERGE_RUNS")" -eq 1 ]]
}

@test "merged tip is re-read from origin after the CI fix push" {
	merge_setup
	push_setup
	git push -q origin HEAD:refs/heads/feat 2>/dev/null || true
	git update-ref refs/remotes/origin/feat "$PUSH_BEFORE"
	local fixed
	fixed=$(git rev-parse HEAD)
	_ci_fix_push_and_wait() {
		git update-ref refs/remotes/origin/feat "$fixed"
		return 0
	}
	local _merged_tip=""
	_merge_with_ci_fix 5 feat || true
	[[ "$_merged_tip" == "$fixed" ]]
}
