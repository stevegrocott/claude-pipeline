#!/usr/bin/env bats
#
# test-reexec.bats
# Tests for implement-issue-orchestrator.sh's re-exec-from-a-private-copy
# self-modification fix (issue #778, mirroring batch-orchestrator.sh's
# issue #775 fix).
#
# bash reads a top-level script incrementally by byte offset as execution
# proceeds. implement-issue-orchestrator.sh is a 12k-line top-level script,
# and the pipeline routinely runs it on issues that edit the orchestrator
# itself. When such a change lands on disk mid-run, bash resumes reading the
# rewritten file at a now-meaningless offset -- observed as either a syntax
# error or a silent early exit that drops the rest of the run.
#
# The fix copies the script to a private temp file at startup and re-execs
# from it, carrying the real script's directory across in
# _IMPLEMENT_ISSUE_ORCHESTRATOR_SCRIPT_DIR, guarding the re-exec so it fires
# exactly once, and removing the snapshot from the EXIT/TERM traps.
#
# Every test below drives the REAL script from an isolated copy of scripts/,
# so the corrupting rewrites can never touch tracked repo source.
#

load 'helpers/test-helper.bash'

# Captured at load time: setup_test_env() cd's into TEST_TMP, and other
# helpers clobber SCRIPT_DIR, so resolve both paths up front.
REAL_SCRIPTS_DIR="$SCRIPT_DIR"
REAL_CONFIG_DIR="$SCRIPT_DIR/../config"

setup() {
	setup_test_env
}

teardown() {
	teardown_test_env
}

# =============================================================================
# HELPERS
# =============================================================================

# Both helpers below SET GLOBALS rather than echoing their result, and must
# be called as plain commands. Calling them via $(...) would run them in a
# subshell, discarding the `export`s they rely on (TMPDIR, and the config
# dir) -- which silently turns the TMPDIR-based assertions into vacuous
# checks against an empty directory.
ORCH_COPY=""
REEXEC_TMPDIR=""

# Copy the whole scripts/ tree into TEST_TMP so the tests can rewrite the
# orchestrator on disk without ever touching the real repo file. Sets
# ORCH_COPY to the isolated orchestrator path.
#
# Consumer config (platform.sh) lives outside scripts/, in the real repo's
# .claude/config/ -- point resolve_consumer_file() at it directly rather
# than also copying it (see resolve-pipeline-root.sh).
make_scripts_copy() {
	local scripts_copy="$TEST_TMP/scripts_copy"
	mkdir -p "$scripts_copy"
	cp -r "$REAL_SCRIPTS_DIR/." "$scripts_copy/"
	chmod +x "$scripts_copy"/*.sh
	export PIPELINE_CONFIG_DIR="$REAL_CONFIG_DIR"
	ORCH_COPY="$scripts_copy/implement-issue-orchestrator.sh"
}

# Isolate TMPDIR so the private re-exec copy is the only
# implement-issue-orchestrator.* file that can appear there -- turning
# "how many times did the re-exec fire" and "was the snapshot cleaned up"
# into direct file counts. Sets REEXEC_TMPDIR.
isolate_tmpdir() {
	REEXEC_TMPDIR="$TEST_TMP/reexec_tmp"
	mkdir -p "$REEXEC_TMPDIR"
	export TMPDIR="$REEXEC_TMPDIR"
}

# expect_no_substring <haystack> <needle> [label]
# Fail unless <needle> is absent from <haystack>. Written as a plain
# substring test rather than an extglob '!(...)' pattern: extglob is off by
# default under bats, so a negated glob would be matched literally and the
# assertion would not mean what it reads as.
expect_no_substring() {
	local haystack="$1"
	local needle="$2"
	local label="${3:-output should not contain}"

	if [[ "$haystack" == *"$needle"* ]]; then
		printf 'FAIL: %s\n  unexpected substring: %s\n  actual: %s\n' \
			"$label" "$needle" "$haystack" >&2
		exit 1
	fi
}

# Count private re-exec snapshots left in the isolated TMPDIR.
count_private_copies() {
	find "$1" -maxdepth 1 -name 'implement-issue-orchestrator.*' \
		-type f | wc -l | tr -d ' '
}

# Install a `git` stub that blocks on a ready/release handshake.
#
# The orchestrator resolves PLATFORM_CONTEXT_FILE via `git rev-parse
# --show-toplevel` while still in its CONFIGURATION block (~line 140 of
# 12k) -- long before bash has read the rest of the file. Blocking there
# gives a deterministic window in which the on-disk script can be rewritten
# while bash's read offset is still near the top, which is precisely the
# condition that breaks an unfixed run.
install_blocking_git() {
	local mock_bin="$TEST_TMP/mockbin"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/git" << MOCKGIT
#!/usr/bin/env bash
touch "$TEST_TMP/git_ready"
i=0
while [[ ! -f "$TEST_TMP/git_release" ]] && ((i++ < 300)); do
	sleep 0.1
done
exit 0
MOCKGIT
	chmod +x "$mock_bin/git"
	export PATH="$mock_bin:$PATH"
}

# Block until the stubbed git call is reached, proving the run is genuinely
# mid-flight before the rewrite lands.
wait_for_git_block() {
	local i=0
	while [[ ! -f "$TEST_TMP/git_ready" ]] && ((i++ < 150)); do
		sleep 0.1
	done
	[[ -f "$TEST_TMP/git_ready" ]]
}

# Overwrite the running process's own script file with a truncated, broken
# snippet -- the on-disk shape of a merge landing mid-run.
corrupt_script() {
	cat > "$1" << 'BROKEN'
#!/usr/bin/env bash
echo "rewritten out from under the running process"
    for f in "${arr[@]}"; do
BROKEN
}

# =============================================================================
# PRECONDITION
# =============================================================================

@test "implement-issue-orchestrator.sh exists and is executable" {
	[[ -f "$ORCHESTRATOR_SCRIPT" ]]
	[[ -x "$ORCHESTRATOR_SCRIPT" ]]
}

# =============================================================================
# AC1: rewriting the script mid-run does not disturb the run
# =============================================================================
#
# Verified RED against the pre-fix script (HEAD before this change): the
# unfixed run resumed reading the rewritten file, hit its premature EOF, and
# exited 0 having printed NOTHING -- silently losing the entire run instead
# of reaching argument validation. Post-fix it reads from the private
# snapshot, so the rewrite is invisible and the run completes normally.

@test "real orchestrator: rewriting the script on disk mid-run does not disturb the run" {
	make_scripts_copy
	install_blocking_git

	# No args: argument validation is the first observable outcome that
	# lives well past the rewrite point, so reaching it proves the run
	# kept executing the code it started with.
	(
		cd "$TEST_TMP" || exit 1
		exec "$ORCH_COPY"
	) > "$TEST_TMP/orch.out" 2>&1 &
	local pid=$!

	expect_ok "run reached the blocking git call" wait_for_git_block

	corrupt_script "$ORCH_COPY"
	touch "$TEST_TMP/git_release"

	local exit_status=0
	wait "$pid" || exit_status=$?

	# The corruption really landed (rules out a silent no-op overwrite).
	expect_ok "script file was actually rewritten" \
		grep -q "rewritten out from under" "$ORCH_COPY"

	local output
	output=$(cat "$TEST_TMP/orch.out")

	# A pre-fix run reading the rewritten file at its stale offset either
	# dies with a syntax error or falls off the truncated end silently.
	expect_glob "$output" '*ERROR: --issue and --branch are required*' \
		"run reached its own argument validation after the rewrite"
	expect_glob "$output" '*--issue <number>*' \
		"run printed its real usage text after the rewrite"
	expect_no_substring "$output" "syntax error" "no bash syntax error"
	expect_ok "run exited with the usage status (3), not a crash" \
		[ "$exit_status" -eq 3 ]
}

# =============================================================================
# AC2: SCRIPT_DIR survives the re-exec
# =============================================================================
#
# The re-exec repoints BASH_SOURCE[0] at the private temp copy before
# SCRIPT_DIR is derived from it. Without an explicit carry-across SCRIPT_DIR
# silently becomes the bare $TMPDIR the snapshot lives in -- a worse failure
# than the crash it fixes, since it surfaces as unresolved siblings and
# schemas rather than an obvious error.

@test "real orchestrator: SCRIPT_DIR resolves to the real script directory after re-exec" {
	make_scripts_copy
	isolate_tmpdir

	# usage() is the first exit path reached only after every
	# SCRIPT_DIR-dependent sibling has already been sourced successfully:
	# model-config.sh, claude-usage.sh, prompts/triage-prompt.sh,
	# resolve-pipeline-root.sh, and (via resolve_consumer_file) platform.sh.
	run "$ORCH_COPY"

	# If SCRIPT_DIR repointed at $TMPDIR, those sources fail with "No such
	# file or directory", resolve_consumer_file is never defined, and the
	# run dies early on the "platform.sh not found" FATAL (exit 1) instead
	# of ever reaching argument parsing.
	expect_no_substring "$output" "No such file or directory" \
		"no sibling script failed to resolve"
	expect_no_substring "$output" "platform.sh not found" \
		"platform.sh resolved via the real config dir"
	expect_glob "$output" '*--issue <number>*' "usage text was reached"
	expect_ok "exited with the usage status (3)" [ "$status" -eq 3 ]
}

@test "real orchestrator: SCHEMA_DIR-adjacent siblings resolve from the real scripts dir" {
	make_scripts_copy
	isolate_tmpdir

	run "$ORCH_COPY"

	# Nothing the orchestrator sources may resolve to the snapshot's
	# directory. If SCRIPT_DIR had collapsed to $TMPDIR, the isolated
	# TMPDIR would be where schemas/ and siblings were looked up -- assert
	# it holds nothing but the single snapshot file.
	local stray
	stray=$(find "$REEXEC_TMPDIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
	expect_ok "no directories were created in TMPDIR" [ "$stray" -eq 0 ]
	expect_glob "$output" '*--issue <number>*' "usage text was reached"
}

# =============================================================================
# AC3: the recursion guard fires the re-exec exactly once
# =============================================================================
#
# A broken guard re-execs forever (unbounded copies, hung run); a guard that
# regressed the other way skips the re-exec entirely (zero copies), which
# resurrects the AC1 mid-run rewrite failure.

@test "real orchestrator: re-exec creates exactly one private copy per invocation" {
	make_scripts_copy
	isolate_tmpdir

	run "$ORCH_COPY"

	local copy_count
	copy_count="$(count_private_copies "$REEXEC_TMPDIR")"
	expect_ok "exactly one private copy was created" \
		[ "$copy_count" -eq 1 ]
}

@test "real orchestrator: an inherited guard suppresses a second re-exec" {
	make_scripts_copy
	isolate_tmpdir

	# Simulate the guard arriving from an ancestor shell that already
	# re-exec'd. The run must NOT copy itself again.
	export _IMPLEMENT_ISSUE_ORCHESTRATOR_REEXECED=1
	export _IMPLEMENT_ISSUE_ORCHESTRATOR_SCRIPT_DIR="$TEST_TMP/scripts_copy"

	run "$ORCH_COPY"

	local copy_count
	copy_count="$(count_private_copies "$REEXEC_TMPDIR")"
	expect_ok "no additional private copy was created" \
		[ "$copy_count" -eq 0 ]
	# The carried-across SCRIPT_DIR is still honoured, so the run still
	# resolves its siblings and reaches usage.
	expect_glob "$output" '*--issue <number>*' "usage text was reached"
}

# =============================================================================
# AC4: the private copy is removed by the EXIT/TERM traps
# =============================================================================
#
# The snapshot must not accumulate in $TMPDIR across runs. Cleanup is wired
# into the same EXIT trap that already writes terminal state, and called
# explicitly from the TERM trap.

@test "real orchestrator: the private copy is removed when a signalled run exits" {
	make_scripts_copy
	isolate_tmpdir

	# git must NOT block here: the EXIT/TERM traps are registered well
	# after the CONFIGURATION block, so a run parked on the early git call
	# would be killed by the default SIGTERM disposition and prove nothing.
	# Park it on the first gh/claude call instead, which is past both traps.
	local mock_bin="$TEST_TMP/mockbin"
	mkdir -p "$mock_bin"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$mock_bin/git"
	local cmd
	for cmd in gh claude; do
		cat > "$mock_bin/$cmd" << MOCKCMD
#!/usr/bin/env bash
touch "$TEST_TMP/cmd_ready"
i=0
while [[ ! -f "$TEST_TMP/cmd_release" ]] && ((i++ < 300)); do
	sleep 0.1
done
exit 0
MOCKCMD
		chmod +x "$mock_bin/$cmd"
	done
	chmod +x "$mock_bin/git"
	export PATH="$mock_bin:$PATH"

	(
		cd "$TEST_TMP" || exit 1
		exec "$ORCH_COPY" --issue 999999 --branch test
	) > "$TEST_TMP/orch.out" 2>&1 &
	local pid=$!

	local i=0
	while [[ ! -f "$TEST_TMP/cmd_ready" ]] && ((i++ < 300)); do
		sleep 0.1
	done
	expect_ok "run reached a stage command past the trap registration" \
		[ -f "$TEST_TMP/cmd_ready" ]

	# The snapshot exists while the run is alive -- otherwise "removed on
	# exit" below would pass vacuously.
	local during
	during="$(count_private_copies "$REEXEC_TMPDIR")"
	expect_ok "private copy exists during the run" [ "$during" -eq 1 ]

	# bash defers trap handling until the running foreground command
	# returns, so release the stub right after signalling.
	kill -TERM "$pid" 2>/dev/null
	touch "$TEST_TMP/cmd_release"

	local exit_status=0
	wait "$pid" || exit_status=$?

	expect_ok "TERM produced the 128+15 exit status" \
		[ "$exit_status" -eq 143 ]

	local after
	after="$(count_private_copies "$REEXEC_TMPDIR")"
	expect_ok "private copy was removed once the run exited" \
		[ "$after" -eq 0 ]
}

# =============================================================================
# Usage text must name a runnable path, not the deleted snapshot
# =============================================================================
#
# After the re-exec $0 is the temp snapshot, which this run deletes on exit.
# Printing it in usage() would tell an operator to re-run a path that no
# longer exists.

@test "real orchestrator: usage names the real script path, not the temp copy" {
	make_scripts_copy
	isolate_tmpdir

	run "$ORCH_COPY"

	expect_glob "$output" "*Usage: $ORCH_COPY --issue*" \
		"usage names the invoked script path"
	expect_no_substring "$output" "Usage: $REEXEC_TMPDIR/" \
		"usage does not name the private temp copy"
}
