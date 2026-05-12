#!/usr/bin/env bats
#
# tests/watchdog-fd-inheritance.bats
# Regression test for issue #310: orphaned-sleep watchdog holds pipe write-end open.
#
# In execute_batch_parallel each task worker (B_i) launches a wall-time watchdog:
#   set -m
#   ( sleep N && kill ) > /dev/null 2>&1 &
#   _watchdog_pid=$!
#   set +m
# Before the fix, > /dev/null 2>&1 was absent, so the sleep child inherited B_i's
# stdout (write-end of the command-substitution pipe PA).  When watchdog bash was
# killed, sleep became an orphan still holding PA open — par_result=$(...) blocked
# for up to MAX_TASK_WALL_TIME_SECS.
#
# AC3: synthetic watchdog scenario (task completes normally, watchdog killed) leaves
# the test pipe readable with immediate EOF once the outer subshell exits.

bats_require_minimum_version 1.5.0

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helper: drain a fifo to /dev/null with a deadline (seconds).
# Returns 0 if EOF was reached before the deadline; 124 if timed out.
# Pure bash — does not require the GNU coreutils `timeout` command.
# ---------------------------------------------------------------------------
_drain_pipe_with_deadline() {
	local fifo="$1"
	local deadline_secs="$2"

	cat "$fifo" > /dev/null &
	local reader_pid=$!

	# Watchdog kills the reader if the deadline expires.
	(
		sleep "$deadline_secs"
		kill "$reader_pid" 2>/dev/null
	) &
	local watchdog_pid=$!

	wait "$reader_pid" 2>/dev/null
	local reader_rc=$?

	kill "$watchdog_pid" 2>/dev/null
	wait "$watchdog_pid" 2>/dev/null || true

	# reader was SIGKILLed/SIGTERMed → timed out
	if [[ $reader_rc -ne 0 ]]; then
		return 124
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 1 (AC3): fixed pattern — CS pipe reaches EOF immediately
# ---------------------------------------------------------------------------
@test "fixed watchdog: CS pipe reaches EOF immediately when task exits before wall-time" {
	local fifo="$TEST_TMP/cs_pipe"
	mkfifo "$fifo"

	# B_i subshell: task exits immediately, watchdog sleeps 300 s but is redirected
	# to /dev/null and killed atomically via process-group kill (the fix).
	(
		set -m
		sleep 0 &                   # simulate fast-completing task
		_task_pid=$!
		set +m

		set -m
		( sleep 300 && kill -- -"$_task_pid" 2>/dev/null ) > /dev/null 2>&1 &
		_watchdog_pid=$!
		set +m

		wait "$_task_pid" 2>/dev/null
		kill -- -"$_watchdog_pid" 2>/dev/null
		wait "$_watchdog_pid" 2>/dev/null || true
	) > "$fifo" &
	local bi_pid=$!

	# Drain pipe with a 5-second deadline.
	local exit_code=0
	_drain_pipe_with_deadline "$fifo" 5 || exit_code=$?

	wait "$bi_pid" 2>/dev/null || true

	if [[ $exit_code -eq 124 ]]; then
		fail "CS pipe did not reach EOF within 5 s — a process is holding the write-end open (issue #310 regression)"
	fi
	[[ $exit_code -eq 0 ]] || fail "unexpected exit code from pipe drain: $exit_code"
}

# ---------------------------------------------------------------------------
# Test 2 (AC1): no sleep from the watchdog survives after the subshell exits
# ---------------------------------------------------------------------------
@test "fixed watchdog: no orphaned sleep process survives after subshell exits" {
	local fifo="$TEST_TMP/cs_pipe2"
	mkfifo "$fifo"

	# Use a sleep duration unlikely to appear elsewhere on the system.
	local unique_secs=29999

	(
		set -m
		sleep 0 &
		_task_pid=$!
		set +m

		set -m
		( sleep "$unique_secs" && kill -- -"$_task_pid" 2>/dev/null ) > /dev/null 2>&1 &
		_watchdog_pid=$!
		set +m

		wait "$_task_pid" 2>/dev/null
		kill -- -"$_watchdog_pid" 2>/dev/null
		wait "$_watchdog_pid" 2>/dev/null || true
	) > "$fifo" &
	local bi_pid=$!

	_drain_pipe_with_deadline "$fifo" 5 || true
	wait "$bi_pid" 2>/dev/null || true

	# Allow the OS one tick to reap any orphans.
	sleep 0.2

	# pgrep is available on both macOS and Linux.
	local survivors
	survivors=$(pgrep -f "sleep ${unique_secs}" 2>/dev/null || true)

	if [[ -n "$survivors" ]]; then
		kill $survivors 2>/dev/null || true
		fail "orphaned sleep (sleep ${unique_secs}) still alive after watchdog kill — process-group kill did not reach sleep child (issue #310 regression)"
	fi
}
