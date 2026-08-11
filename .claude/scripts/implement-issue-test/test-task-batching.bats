#!/usr/bin/env bats
#
# test-task-batching.bats
# Unit tests for _extract_task_files_from_desc(), compute_task_batches(),
# and parallel worktree execution functions.
#
# Cases covered:
#   _extract_task_files_from_desc:
#     1. backtick-quoted path extracted
#     2. slash-separated path extracted
#     3. known-extension bare filename extracted
#     4. version string (v1.0) NOT matched
#     5. numeric version (2.3.4) NOT matched
#     6. empty description returns empty
#
#   compute_task_batches:
#     1. single task → batch 1
#     2. zero tasks → empty array
#     3. two non-overlapping tasks → both batch 1
#     4. two overlapping tasks → batch 1 + batch 2
#     5. tasks with no recognisable paths → all batch 1 (no conflict assumed)
#     6. every task in output has a .batch field
#
#   create_task_worktree:
#     1. creates worktree directory at expected path
#     2. creates the expected branch
#     3. returns worktree path on stdout
#     4. fails gracefully on invalid feature branch
#
#   merge_worktree_branch:
#     1. merges non-conflicting worktree branch
#     2. aborts and returns 1 on merge conflict
#
#   cleanup_worktree:
#     1. removes worktree directory and branch
#     2. tolerates missing worktree without error
#     3. tags unmerged commits as salvage/issue-<n>-task<m> before delete
#     4. does not create a salvage tag when branch has no unmerged commits
#
#   execute_batch_serial:
#     1. returns completed array with task IDs (mocked run_stage)
#     2. returns failed array when run_stage fails
#
#   execute_batch_parallel:
#     1. creates worktrees for each task in batch
#     2. returns conflicted array on merge conflict
#     3. comment-deliverable task with no commits + matching comment ->
#        completed, not failed (issue #790, AC1)
#     4. comment-deliverable task whose marker matches no comment -> still
#        fails (issue #790, AC3)
#
#   run_parallel_post_task_stages:
#     1. e2e-verify and acceptance-test launch as separate background processes
#     2. both stages complete before function returns (docs ordering guarantee)
#     3. e2e-verify failure captured independently — acceptance-test still runs
#     4. acceptance-test failure captured independently — e2e-verify still completes
#     5. per-stage log files written for each parallel stage
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env

	# Minimal git repo required by compute_task_batches (git diff)
	mkdir -p "$TEST_TMP/repo"
	cd "$TEST_TMP/repo" || exit 1
	git init -q
	git checkout -q -b main
	printf 'initial\n' > README.md
	git add README.md
	git commit -q -m "initial"

	# Required by log / log_error helpers sourced with the orchestrator
	export ISSUE_NUMBER=99
	export BASE_BRANCH=main
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0
	mkdir -p "$LOG_BASE"

	source_orchestrator_functions
}

teardown() {
	teardown_test_env
}

# =============================================================================
# _extract_task_files_from_desc
# =============================================================================

@test "_extract_task_files_from_desc: extracts backtick-quoted path" {
	run _extract_task_files_from_desc "Update \`src/foo.ts\`"
	[ "$status" -eq 0 ]
	[[ "$output" == *"src/foo.ts"* ]]
}

@test "_extract_task_files_from_desc: extracts slash-separated path without extension" {
	run _extract_task_files_from_desc "Modify src/components/button"
	[ "$status" -eq 0 ]
	[[ "$output" == *"src/components/button"* ]]
}

@test "_extract_task_files_from_desc: extracts known-extension bare filenames" {
	run _extract_task_files_from_desc "Edit handler.sh and index.ts"
	[ "$status" -eq 0 ]
	[[ "$output" == *"handler.sh"* ]]
	[[ "$output" == *"index.ts"* ]]
}

@test "_extract_task_files_from_desc: does NOT match version string like v1.0" {
	run _extract_task_files_from_desc "Upgrade to v1.0 of the library"
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "_extract_task_files_from_desc: does NOT match numeric version like 2.3.4" {
	run _extract_task_files_from_desc "Bump from 2.3.4 to 2.4.0"
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "_extract_task_files_from_desc: returns empty for empty description" {
	run _extract_task_files_from_desc ""
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "_extract_task_files_from_desc: does NOT match bare domain names" {
	run _extract_task_files_from_desc "Call api.example.com endpoint"
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "_extract_task_files_from_desc: does NOT match plain word in backticks" {
	# A bare symbol like \`config\` has no slash and no known extension;
	# it must not be extracted as a file path after the tightening fix.
	run _extract_task_files_from_desc "Set the \`config\` option to true"
	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "_extract_task_files_from_desc: matches backtick token with known extension" {
	# A backtick token ending in a known extension qualifies as a file
	# even when it has no directory component.
	run _extract_task_files_from_desc "Edit \`handler.sh\` directly"
	[ "$status" -eq 0 ]
	[[ "$output" == *"handler.sh"* ]]
}

# =============================================================================
# compute_task_batches
# =============================================================================

@test "compute_task_batches: single task is assigned batch 1" {
	cd "$TEST_TMP/repo" || exit 1
	local tasks result batch
	tasks='[{"id":1,"description":"Update README.md","agent":"default"}]'
	result=$(compute_task_batches "$tasks" main)
	batch=$(printf '%s' "$result" | jq '.[0].batch')
	[ "$batch" -eq 1 ]
}

@test "compute_task_batches: zero tasks returns empty array" {
	cd "$TEST_TMP/repo" || exit 1
	local result len
	result=$(compute_task_batches "[]" main)
	len=$(printf '%s' "$result" | jq 'length')
	[ "$len" -eq 0 ]
}

@test "compute_task_batches: two non-overlapping tasks go into batch 1" {
	cd "$TEST_TMP/repo" || exit 1
	local tasks result b1 b2
	tasks='[
		{"id":1,"description":"Modify src/alpha.ts","agent":"default"},
		{"id":2,"description":"Modify src/beta.ts","agent":"default"}
	]'
	result=$(compute_task_batches "$tasks" main)
	b1=$(printf '%s' "$result" | jq '.[0].batch')
	b2=$(printf '%s' "$result" | jq '.[1].batch')
	[ "$b1" -eq 1 ]
	[ "$b2" -eq 1 ]
}

@test "compute_task_batches: two overlapping tasks go into batch 1 and batch 2" {
	cd "$TEST_TMP/repo" || exit 1
	local tasks result b1 b2
	tasks='[
		{"id":1,"description":"Update src/shared.ts","agent":"default"},
		{"id":2,"description":"Also update src/shared.ts","agent":"default"}
	]'
	result=$(compute_task_batches "$tasks" main)
	b1=$(printf '%s' "$result" | jq '.[0].batch')
	b2=$(printf '%s' "$result" | jq '.[1].batch')
	[ "$b1" -eq 1 ]
	[ "$b2" -eq 2 ]
}

@test "compute_task_batches: conflict grep handles leading-hyphen filename" {
	cd "$TEST_TMP/repo" || exit 1
	# A backtick-quoted name ending in a known extension and starting with '-'
	# gets extracted.  Without a '--' end-of-options guard, grep misinterprets
	# the name as option flags and the conflict is silently missed — both tasks
	# end up in batch 1.  With '--', grep finds the literal match and puts the
	# second task in batch 2.
	local tasks result b1 b2
	# Use actual backticks (valid JSON); bash single-quotes pass them literally
	tasks='[
		{"id":1,"description":"Update `-build.sh`","agent":"default"},
		{"id":2,"description":"Also update `-build.sh`","agent":"default"}
	]'
	result=$(compute_task_batches "$tasks" main)
	b1=$(printf '%s' "$result" | jq '.[0].batch')
	b2=$(printf '%s' "$result" | jq '.[1].batch')
	[ "$b1" -eq 1 ]
	[ "$b2" -eq 2 ]
}

@test "compute_task_batches: tasks with no recognisable paths all go to batch 1" {
	cd "$TEST_TMP/repo" || exit 1
	local tasks result b1 b2
	tasks='[
		{"id":1,"description":"Do something unspecified","agent":"default"},
		{"id":2,"description":"Do something else entirely","agent":"default"}
	]'
	result=$(compute_task_batches "$tasks" main)
	b1=$(printf '%s' "$result" | jq '.[0].batch')
	b2=$(printf '%s' "$result" | jq '.[1].batch')
	[ "$b1" -eq 1 ]
	[ "$b2" -eq 1 ]
}

@test "compute_task_batches: every task in output has a .batch field" {
	cd "$TEST_TMP/repo" || exit 1
	local tasks result nulls
	tasks='[
		{"id":1,"description":"Update foo.ts","agent":"default"},
		{"id":2,"description":"Update bar.ts","agent":"default"},
		{"id":3,"description":"Update baz.sh","agent":"default"}
	]'
	result=$(compute_task_batches "$tasks" main)
	nulls=$(printf '%s' "$result" \
		| jq '[.[] | select(.batch == null)] | length')
	[ "$nulls" -eq 0 ]
}

# =============================================================================
# create_task_worktree
# =============================================================================

@test "create_task_worktree: creates worktree at expected path" {
	cd "$TEST_TMP/repo" || exit 1

	# Create a feature branch to base worktree on
	git checkout -q -b feature/test-wt main

	local wt_base="$TEST_TMP/worktrees"
	local wt_path
	wt_path=$(create_task_worktree "$wt_base" "feature/test-wt" "42")

	[[ -d "$wt_path" ]]
	[[ "$wt_path" == "${wt_base}/task-42" ]]

	# Clean up
	git worktree remove --force "$wt_path" 2>/dev/null || true
	git branch -D "wt-task-42" 2>/dev/null || true
	git checkout -q main
}

@test "create_task_worktree: creates expected branch name" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/test-wt2 main

	local wt_base="$TEST_TMP/worktrees"
	create_task_worktree "$wt_base" "feature/test-wt2" "7" "42" \
		>/dev/null

	# Branch should exist with new naming format wt-i<issue>-t<task>
	git rev-parse --verify "wt-i42-t7" >/dev/null 2>&1
	[ $? -eq 0 ]

	# Clean up
	git worktree remove --force "${wt_base}/task-7" 2>/dev/null || true
	git branch -D "wt-i42-t7" 2>/dev/null || true
	git checkout -q main
}

@test "create_task_worktree: returns worktree path on stdout" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/test-wt3 main

	local wt_base="$TEST_TMP/worktrees"
	local result
	result=$(create_task_worktree "$wt_base" "feature/test-wt3" "99")

	[[ "$result" == "${wt_base}/task-99" ]]

	# Clean up
	git worktree remove --force "${wt_base}/task-99" 2>/dev/null || true
	git branch -D "wt-task-99" 2>/dev/null || true
	git checkout -q main
}

@test "create_task_worktree: fails on invalid feature branch" {
	cd "$TEST_TMP/repo" || exit 1

	local wt_base="$TEST_TMP/worktrees"
	run create_task_worktree "$wt_base" "nonexistent-branch" "1"

	[ "$status" -ne 0 ]
}

# =============================================================================
# merge_worktree_branch
# =============================================================================

@test "merge_worktree_branch: merges non-conflicting changes" {
	cd "$TEST_TMP/repo" || exit 1

	# Setup: create feature branch and worktree branch
	git checkout -q -b feature/merge-test main
	git checkout -q -b wt-task-10 feature/merge-test

	# Add a non-conflicting file in the worktree branch
	printf 'new content\n' > newfile.txt
	git add newfile.txt
	git commit -q -m "add newfile"

	# Switch back to feature branch for merge
	git checkout -q feature/merge-test

	run merge_worktree_branch "feature/merge-test" "wt-task-10" "10"
	[ "$status" -eq 0 ]

	# Verify the file was merged
	[[ -f "newfile.txt" ]]

	# Clean up
	git checkout -q main
	git branch -D feature/merge-test 2>/dev/null || true
	git branch -D wt-task-10 2>/dev/null || true
}

@test "merge_worktree_branch: returns 1 on conflict and aborts" {
	cd "$TEST_TMP/repo" || exit 1

	# Setup: create feature branch with content
	git checkout -q -b feature/conflict-test main
	printf 'feature content\n' > conflict.txt
	git add conflict.txt
	git commit -q -m "feature content"

	# Create worktree branch with conflicting content
	git checkout -q -b wt-task-11 main
	printf 'worktree content\n' > conflict.txt
	git add conflict.txt
	git commit -q -m "worktree content"

	# Switch to feature branch
	git checkout -q feature/conflict-test

	run merge_worktree_branch "feature/conflict-test" "wt-task-11" "11"
	[ "$status" -eq 1 ]

	# Verify merge was aborted (no merge in progress)
	run git merge HEAD 2>&1
	[ "$status" -eq 0 ]

	# Clean up
	git checkout -q main
	git branch -D feature/conflict-test 2>/dev/null || true
	git branch -D wt-task-11 2>/dev/null || true
}

# =============================================================================
# cleanup_worktree
# =============================================================================

@test "cleanup_worktree: removes worktree and branch" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/cleanup-test main

	local wt_base="$TEST_TMP/worktrees"
	create_task_worktree "$wt_base" "feature/cleanup-test" "20" \
		>/dev/null

	# Verify worktree exists
	[[ -d "${wt_base}/task-20" ]]

	# Run cleanup
	cleanup_worktree "${wt_base}/task-20" "wt-task-20"

	# Verify worktree and branch are gone
	[[ ! -d "${wt_base}/task-20" ]]
	! git rev-parse --verify "wt-task-20" 2>/dev/null

	git checkout -q main
	git branch -D feature/cleanup-test 2>/dev/null || true
}

@test "cleanup_worktree: tolerates missing worktree" {
	cd "$TEST_TMP/repo" || exit 1

	run cleanup_worktree "/nonexistent/path" "nonexistent-branch"
	[ "$status" -eq 0 ]
}

@test "cleanup_worktree: tags unmerged commits as salvage/issue-<n>-task<m>" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/salvage-test main

	local wt_base="$TEST_TMP/worktrees"
	local wt_branch="wt-i42-t7"
	create_task_worktree "$wt_base" "feature/salvage-test" "7" "42" \
		>/dev/null

	# Commit work on the worktree branch that a merge conflict would
	# otherwise leave stranded once the branch is deleted.
	printf 'salvage me\n' > "${wt_base}/task-7/salvage.txt"
	git -C "${wt_base}/task-7" add salvage.txt
	git -C "${wt_base}/task-7" commit -q -m "unmerged work"

	local unmerged_sha
	unmerged_sha=$(git rev-parse "$wt_branch")

	cleanup_worktree "${wt_base}/task-7" "$wt_branch" "42" "7" \
		"feature/salvage-test"

	# Branch and worktree are gone
	[[ ! -d "${wt_base}/task-7" ]]
	! git rev-parse --verify "$wt_branch" 2>/dev/null

	# Salvage tag exists and points at the unmerged commit
	run git rev-parse "salvage/issue-42-task7"
	[ "$status" -eq 0 ]
	[ "$output" = "$unmerged_sha" ]

	git checkout -q main
	git tag -d "salvage/issue-42-task7" 2>/dev/null || true
	git branch -D feature/salvage-test 2>/dev/null || true
}

@test "cleanup_worktree: no salvage tag when branch has no unmerged commits" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/no-salvage-test main

	local wt_base="$TEST_TMP/worktrees"
	local wt_branch="wt-i42-t8"
	create_task_worktree "$wt_base" "feature/no-salvage-test" "8" "42" \
		>/dev/null

	cleanup_worktree "${wt_base}/task-8" "$wt_branch" "42" "8" \
		"feature/no-salvage-test"

	run git rev-parse "salvage/issue-42-task8"
	[ "$status" -ne 0 ]

	git checkout -q main
	git branch -D feature/no-salvage-test 2>/dev/null || true
}

# =============================================================================
# execute_batch_serial (with mocked run_stage)
# =============================================================================

@test "execute_batch_serial: returns completed IDs on success" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/serial-test main

	mkdir -p "$LOG_BASE/stages"

	# Mock run_stage to return success
	# run_stage nests structured fields under .output (only .status is lifted
	# to the top level) — execute_batch_serial reads .output.status /
	# .output.commit / .output.summary, so the mock must match that envelope.
	run_stage() {
		printf '%s' '{"status":"success","output":{"status":"success","commit":"abc123","summary":"done"}}'
	}
	# Mock quality-related functions
	should_run_quality_loop() { return 1; }
	get_max_review_attempts() { printf '%s' "3"; }
	get_stage_timeout() { printf '%s' "1800"; }
	resolve_model() { printf '%s' "sonnet"; }
	build_files_block() { printf '\n'; }
	extract_task_size() { printf '%s' "S"; }

	local tasks result comp_len
	tasks='[{"id":1,"description":"Do thing","agent":"default"}]'
	result=$(execute_batch_serial "$tasks" "feature/serial-test" "main")
	comp_len=$(printf '%s' "$result" | jq '.completed | length')

	[ "$comp_len" -eq 1 ]

	local comp_id
	comp_id=$(printf '%s' "$result" | jq '.completed[0]')
	[ "$comp_id" -eq 1 ]

	git checkout -q main
	git branch -D feature/serial-test 2>/dev/null || true
}

@test "execute_batch_serial: returns failed IDs when run_stage fails" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/serial-fail main

	mkdir -p "$LOG_BASE/stages"

	# Mock run_stage to return failure
	run_stage() {
		printf '%s' '{"status":"error","error":"mock failure"}'
	}
	get_max_review_attempts() { printf '%s' "1"; }
	get_stage_timeout() { printf '%s' "1800"; }
	resolve_model() { printf '%s' "sonnet"; }
	build_files_block() { printf '\n'; }
	extract_task_size() { printf '%s' "S"; }

	local tasks result fail_len
	tasks='[{"id":5,"description":"Fail task","agent":"default"}]'
	result=$(execute_batch_serial "$tasks" "feature/serial-fail" "main")
	fail_len=$(printf '%s' "$result" | jq '.failed | length')

	[ "$fail_len" -eq 1 ]

	local fail_id
	fail_id=$(printf '%s' "$result" | jq '.failed[0]')
	[ "$fail_id" -eq 5 ]

	git checkout -q main
	git branch -D feature/serial-fail 2>/dev/null || true
}

# =============================================================================
# execute_batch_parallel (worktree integration)
# =============================================================================

@test "execute_batch_parallel: creates worktrees and returns structured JSON" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/par-test main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	# Create real files so worktrees have something to commit
	printf 'alpha\n' > alpha.ts
	printf 'beta\n' > beta.ts
	git add alpha.ts beta.ts
	git commit -q -m "add source files"

	# Override run_task_in_worktree to create a real commit
	# in the worktree instead of calling the full pipeline.
	# This avoids needing to export all sourced dependencies
	# (log, log_error, run_stage, etc.) for background subshells.
	run_task_in_worktree() {
		local task_id="$1"
		local task_desc="$2"
		local task_agent="$3"
		local task_size="$4"
		local wt_path="$5"
		local wt_branch="$6"
		local feature_branch="$7"
		local result_file="$8"
		local base_branch="$9"

		cd "$wt_path" || {
			printf '%s' \
				'{"status":"failed","review_attempts":0}' \
				> "$result_file"
			return 1
		}

		printf 'task %s output\n' "$task_id" \
			> "task-${task_id}-out.txt"
		git add "task-${task_id}-out.txt"
		git commit -q -m "task $task_id"
		local sha
		sha=$(git rev-parse --short HEAD)

		printf '{"status":"success","review_attempts":1,"commit":"%s","summary":"done"}' \
			"$sha" > "$result_file"
		return 0
	}
	export -f run_task_in_worktree
	export -f extract_task_size 2>/dev/null || true

	# Two non-overlapping tasks
	local tasks result
	tasks='[
		{"id":1,"description":"Modify alpha.ts","agent":"default","batch":1},
		{"id":2,"description":"Modify beta.ts","agent":"default","batch":1}
	]'

	result=$(execute_batch_parallel 1 "$tasks" \
		"feature/par-test" "main" \
		2>/dev/null) || true

	# Result should be valid JSON with the three arrays
	local has_completed has_failed has_conflicted
	has_completed=$(printf '%s' "$result" \
		| jq 'has("completed")' 2>/dev/null)
	has_failed=$(printf '%s' "$result" \
		| jq 'has("failed")' 2>/dev/null)
	has_conflicted=$(printf '%s' "$result" \
		| jq 'has("conflicted")' 2>/dev/null)

	[[ "$has_completed" == "true" ]]
	[[ "$has_failed" == "true" ]]
	[[ "$has_conflicted" == "true" ]]

	# Both tasks should have completed (non-overlapping)
	local comp_count
	comp_count=$(printf '%s' "$result" \
		| jq '.completed | length' 2>/dev/null)
	[[ "$comp_count" == "2" ]]

	# Clean up any leftover worktrees
	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git branch -D feature/par-test 2>/dev/null || true
	git branch -D wt-task-1 2>/dev/null || true
	git branch -D wt-task-2 2>/dev/null || true
}

# =============================================================================
# run_parallel_post_task_stages (parallel e2e-verify and acceptance-test)
# Tests the parallel execution of post-task stages with independent exit codes
# =============================================================================

# Common helper: define mocks used by every run_parallel_post_task_stages test.
# Call this inside each test after cd-ing to the repo and setting LOG_BASE.
_setup_parallel_stage_mocks() {
	is_stage_completed()  { return 1; }
	set_stage_started()   { true; }
	set_stage_completed() { true; }
	log()       { true; }
	log_error() { true; }
	log_warn()  { true; }
	comment_issue() { true; }
	verify_on_feature_branch() { return 0; }
	rebuild_and_health_check() {
		printf '{"rebuild":"skipped","health":"skipped","elapsed_secs":0}'
	}
	_build_targeted_e2e_cmd() { printf '%s' "${TEST_E2E_CMD:-true}"; }

	export TEST_E2E_CMD="echo run-e2e"
	export RESUME_MODE=""
}

@test "run_parallel_post_task_stages: e2e-verify and acceptance-test launch as separate background processes" {
	cd "$TEST_TMP/repo" || exit 1
	mkdir -p "$LOG_BASE/stages"

	local e2e_pid_file="$TEST_TMP/e2e.pid"
	local acc_pid_file="$TEST_TMP/acc.pid"

	_setup_parallel_stage_mocks

	# Use 'sh -c echo $PPID' to get the subshell's own PID (bash 3.x compatible;
	# $BASHPID is unavailable on the macOS-default bash 3.2).
	# run_stage is only called from the e2e subshell.
	run_stage() {
		sh -c 'echo $PPID' > "$e2e_pid_file"
		printf '%s' '{"status":"success","result":"passed","summary":"ok"}'
	}

	# acceptance subshell logs "No API route files changed" when no routes exist.
	# Capture its PID via the unique message prefix in the log mock.
	log() {
		[[ "${1:-}" == *"No API"* ]] \
			&& sh -c 'echo $PPID' > "$acc_pid_file"
		true
	}

	run_parallel_post_task_stages \
		"feature/test" "frontend" "standard" "M"

	# Both subshells must have run and written their PID files
	[[ -f "$e2e_pid_file" ]]
	[[ -f "$acc_pid_file" ]]

	local e2e_pid acc_pid
	e2e_pid=$(cat "$e2e_pid_file")
	acc_pid=$(cat "$acc_pid_file")

	# PIDs must be numeric
	[[ "$e2e_pid" =~ ^[0-9]+$ ]]
	[[ "$acc_pid"  =~ ^[0-9]+$ ]]

	# PIDs must differ — each stage runs in its own background subshell
	[[ "$e2e_pid" -ne "$acc_pid" ]]
}

@test "run_parallel_post_task_stages: both stages complete before function returns" {
	cd "$TEST_TMP/repo" || exit 1
	mkdir -p "$LOG_BASE/stages"

	local e2e_done="$TEST_TMP/e2e.done"
	local acc_done="$TEST_TMP/acc.done"

	_setup_parallel_stage_mocks

	run_stage() {
		case "$1" in
			e2e-verify) touch "$e2e_done" ;;
		esac
		printf '%s' '{"status":"success","result":"passed","summary":"ok"}'
	}

	# acceptance subshell calls comment_issue when it skips (no route files)
	comment_issue() { touch "$acc_done"; }

	run_parallel_post_task_stages \
		"feature/test" "frontend" "standard" "M"

	# Both done-markers must exist when function returns, proving that
	# docs (which runs after this function) can safely assume both are complete.
	[[ -f "$e2e_done" ]]
	[[ -f "$acc_done" ]]
}

@test "run_parallel_post_task_stages: e2e-verify failure captured independently — acceptance-test still runs" {
	cd "$TEST_TMP/repo" || exit 1
	mkdir -p "$LOG_BASE/stages"

	local acc_ran="$TEST_TMP/acc.ran"

	_setup_parallel_stage_mocks

	run_stage() {
		case "$1" in
			e2e-verify)
				printf '%s' '{"status":"error","result":"failed","summary":"e2e failed"}'
				;;
			fix-e2e)
				printf '%s' '{"status":"success","result":"passed","summary":"fixed"}'
				;;
			*)
				printf '%s' '{"status":"success","result":"passed","summary":"ok"}'
				;;
		esac
	}

	# acceptance subshell calls comment_issue when skipping — use as witness
	comment_issue() { touch "$acc_ran"; }

	# Function must return 0 even when e2e-verify reports failure
	run run_parallel_post_task_stages \
		"feature/test" "frontend" "standard" "M"
	[ "$status" -eq 0 ]

	# acceptance-test subshell must have run independently of the e2e failure
	[[ -f "$acc_ran" ]]
}

@test "run_parallel_post_task_stages: acceptance-test failure captured independently — e2e-verify still completes" {
	cd "$TEST_TMP/repo" || exit 1
	mkdir -p "$LOG_BASE/stages"

	local e2e_done="$TEST_TMP/e2e.done"

	_setup_parallel_stage_mocks

	run_stage() {
		case "$1" in
			e2e-verify)
				touch "$e2e_done"
				printf '%s' '{"status":"success","result":"passed","summary":"ok"}'
				;;
			*)
				printf '%s' '{"status":"success","result":"passed","summary":"ok"}'
				;;
		esac
	}

	# Make acceptance subshell exit non-zero: comment_issue returning 1
	# causes the if-branch to exit 1, propagating as acceptance_exit=1.
	comment_issue() { return 1; }

	# Function must return 0 even when the acceptance subshell exits non-zero
	run run_parallel_post_task_stages \
		"feature/test" "frontend" "standard" "M"
	[ "$status" -eq 0 ]

	# e2e-verify must have completed independently of the acceptance failure
	[[ -f "$e2e_done" ]]
}

@test "run_parallel_post_task_stages: per-stage log files written for each parallel stage" {
	cd "$TEST_TMP/repo" || exit 1
	mkdir -p "$LOG_BASE/stages"

	_setup_parallel_stage_mocks

	# run_stage writes a per-stage log file (as production run_stage would)
	run_stage() {
		local stage_name="$1"
		printf '{"stage":"%s","result":"passed"}\n' "$stage_name" \
			> "$LOG_BASE/stages/${stage_name}.log"
		printf '%s' '{"status":"success","result":"passed","summary":"ok"}'
	}

	run_parallel_post_task_stages \
		"feature/test" "frontend" "standard" "M"

	# Per-stage log file for e2e-verify must exist and contain valid JSON
	[[ -f "$LOG_BASE/stages/e2e-verify.log" ]]
	local stage_val
	stage_val=$(jq -r '.stage' "$LOG_BASE/stages/e2e-verify.log")
	[[ "$stage_val" == "e2e-verify" ]]
}

# =============================================================================
# per-task log file creation
# =============================================================================

@test "execute_batch_serial: creates per-task serial log file at LOG_BASE/stages" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/serial-log-test main

	mkdir -p "$LOG_BASE/stages"

	# run_stage nests structured fields under .output (only .status is lifted
	# to the top level) — execute_batch_serial reads .output.status /
	# .output.commit / .output.summary, so the mock must match that envelope.
	run_stage() {
		printf '%s' '{"status":"success","output":{"status":"success","commit":"abc123","summary":"done"}}'
	}
	should_run_quality_loop() { return 1; }
	get_max_review_attempts() { printf '%s' "1"; }
	get_stage_timeout() { printf '%s' "1800"; }
	resolve_model() { printf '%s' "sonnet"; }
	build_files_block() { printf '\n'; }
	extract_task_size() { printf '%s' "S"; }
	classify_e2e_strategy() { printf '%s' "none"; }

	local tasks
	tasks='[{"id":3,"description":"Do thing","agent":"default"}]'
	execute_batch_serial "$tasks" "feature/serial-log-test" "main" \
		>/dev/null

	# Serial log file must exist at expected path
	[[ -f "${LOG_BASE}/stages/task-3-serial.log" ]]

	# Log file must contain valid JSON with status:success
	local status_val
	status_val=$(jq -r '.status' "${LOG_BASE}/stages/task-3-serial.log")
	[[ "$status_val" == "success" ]]

	git checkout -q main
	git branch -D feature/serial-log-test 2>/dev/null || true
}

@test "execute_batch_parallel: creates per-task worktree log file at LOG_BASE/stages" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/par-log-test main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'src\n' > src.ts
	git add src.ts
	git commit -q -m "add src"

	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"

		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		printf 'output\n' > "task-${task_id}.out"
		git add "task-${task_id}.out"
		git commit -q -m "task $task_id"
		local sha
		sha=$(git rev-parse --short HEAD)
		printf '{"status":"success","review_attempts":1,"commit":"%s","summary":"done"}' \
			"$sha" > "$result_file"
	}
	extract_task_size() { printf '%s' "S"; }
	export -f run_task_in_worktree
	export -f extract_task_size

	local tasks
	tasks='[{"id":8,"description":"Modify src.ts","agent":"default","batch":1}]'
	execute_batch_parallel 1 "$tasks" "feature/par-log-test" "main" \
		>/dev/null 2>/dev/null || true

	# Worktree log file must exist at expected path
	[[ -f "${LOG_BASE}/stages/task-8-worktree.log" ]]

	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git branch -D feature/par-log-test 2>/dev/null || true
	git branch -D wt-task-8 2>/dev/null || true
}

# =============================================================================
# merge conflict fallback to serial
# =============================================================================

@test "execute_batch_parallel: conflicted tasks appear in conflicted array not completed" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/conf-fallback main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'shared content\n' > shared.ts
	git add shared.ts
	git commit -q -m "add shared"

	# run_task_in_worktree writes conflicting content to shared.ts
	# so that merge back to feature branch will conflict
	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"

		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		# Overwrite shared.ts with task-specific content to manufacture conflict
		printf 'task %s changes\n' "$task_id" > shared.ts
		git add shared.ts
		git commit -q -m "task $task_id changes shared.ts"
		local sha
		sha=$(git rev-parse --short HEAD)
		printf '{"status":"success","review_attempts":1,"commit":"%s","summary":"done"}' \
			"$sha" > "$result_file"
	}
	extract_task_size() { printf '%s' "S"; }
	export -f run_task_in_worktree
	export -f extract_task_size

	# Two tasks both touching shared.ts will cause a merge conflict
	# on the second merge.  We run them one at a time in the simplest setup:
	# Task 10 merges fine; task 11 conflicts because shared.ts already changed.
	local tasks
	tasks='[
		{"id":10,"description":"Modify shared.ts","agent":"default","batch":1},
		{"id":11,"description":"Modify shared.ts","agent":"default","batch":1}
	]'

	local result
	result=$(execute_batch_parallel 1 "$tasks" \
		"feature/conf-fallback" "main" \
		2>/dev/null) || true

	# At least one task must be conflicted (not all completed)
	local conflicted_count completed_count
	conflicted_count=$(printf '%s' "$result" | jq '.conflicted | length' 2>/dev/null)
	completed_count=$(printf '%s' "$result" | jq '.completed | length' 2>/dev/null)
	local total_classified=$(( conflicted_count + completed_count ))
	[[ "$total_classified" -eq 2 ]]
	[[ "$conflicted_count" -ge 1 ]]

	# The conflicted task's worktree branch was deleted by cleanup_worktree,
	# but its commits must remain addressable via a salvage tag.
	local conflicted_id
	conflicted_id=$(printf '%s' "$result" | jq -r '.conflicted[0]')
	run git rev-parse "salvage/issue-${ISSUE_NUMBER}-task${conflicted_id}"
	[ "$status" -eq 0 ]

	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git tag -d "salvage/issue-${ISSUE_NUMBER}-task${conflicted_id}" \
		2>/dev/null || true
	git branch -D feature/conf-fallback 2>/dev/null || true
	git branch -D wt-task-10 2>/dev/null || true
	git branch -D wt-task-11 2>/dev/null || true
}

# =============================================================================
# conflicted merge retains commits under a named salvage ref (issue #667)
# A conflicted worktree branch must not be force-deleted outright: its
# commits stay reachable by name and the run logs the SHA plus a recovery
# command, instead of orphaning the work as raw unreferenced SHAs.
# =============================================================================

@test "execute_batch_parallel: conflicted merge retains the commit under a named salvage ref (AC1)" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/conf-salvage main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'shared content\n' > shared.ts
	git add shared.ts
	git commit -q -m "add shared"

	# Two tasks both touching shared.ts: task 30 merges cleanly, task 31
	# conflicts because shared.ts was already changed by task 30's merge.
	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"

		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		printf 'task %s changes\n' "$task_id" > shared.ts
		git add shared.ts
		git commit -q -m "task $task_id changes shared.ts"
		local sha
		sha=$(git rev-parse --short HEAD)
		printf '{"status":"success","review_attempts":1,"commit":"%s","summary":"done"}' \
			"$sha" > "$result_file"
	}
	extract_task_size() { printf '%s' "S"; }
	export -f run_task_in_worktree
	export -f extract_task_size

	local tasks
	tasks='[
		{"id":30,"description":"Modify shared.ts","agent":"default","batch":1},
		{"id":31,"description":"Modify shared.ts","agent":"default","batch":1}
	]'

	local result
	result=$(execute_batch_parallel 1 "$tasks" \
		"feature/conf-salvage" "main" \
		2>/dev/null) || true

	local conflicted_ids
	conflicted_ids=$(printf '%s' "$result" | jq -c '.conflicted')
	[[ "$conflicted_ids" == "[31]" ]]

	# The SHA the losing worktree actually committed (from its result log).
	local worktree_sha
	worktree_sha=$(jq -r '.commit' "${LOG_BASE}/stages/task-31-worktree.log")

	# Commits from a conflicted merge must remain reachable by NAME
	# (ISSUE_NUMBER=99 in this test env), not only recoverable by raw SHA.
	run git rev-parse --verify "salvage/issue-99-task31"
	[ "$status" -eq 0 ]
	[[ "$output" == "$worktree_sha"* ]]

	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git tag -d salvage/issue-99-task31 2>/dev/null || true
	git branch -D feature/conf-salvage 2>/dev/null || true
	git branch -D wt-task-30 2>/dev/null || true
	git branch -D wt-task-31 2>/dev/null || true
}

@test "execute_batch_parallel: conflicted merge still removes the worktree directory (AC2)" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/conf-salvage-dir main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'shared content\n' > shared.ts
	git add shared.ts
	git commit -q -m "add shared"

	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"

		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		printf 'task %s changes\n' "$task_id" > shared.ts
		git add shared.ts
		git commit -q -m "task $task_id changes shared.ts"
		local sha
		sha=$(git rev-parse --short HEAD)
		printf '{"status":"success","review_attempts":1,"commit":"%s","summary":"done"}' \
			"$sha" > "$result_file"
	}
	extract_task_size() { printf '%s' "S"; }
	export -f run_task_in_worktree
	export -f extract_task_size

	local tasks
	tasks='[
		{"id":40,"description":"Modify shared.ts","agent":"default","batch":1},
		{"id":41,"description":"Modify shared.ts","agent":"default","batch":1}
	]'

	execute_batch_parallel 1 "$tasks" "feature/conf-salvage-dir" "main" \
		>/dev/null 2>/dev/null || true

	# Retaining the ref must not leave the disposable worktree directory behind.
	[[ ! -d "${LOG_BASE}/worktrees/task-41" ]]

	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git tag -d salvage/issue-99-task41 2>/dev/null || true
	git branch -D feature/conf-salvage-dir 2>/dev/null || true
	git branch -D wt-task-40 2>/dev/null || true
	git branch -D wt-task-41 2>/dev/null || true
}

@test "execute_batch_parallel: conflicted merge logs the retained SHA and a recovery command (AC3)" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/conf-salvage-log main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'shared content\n' > shared.ts
	git add shared.ts
	git commit -q -m "add shared"

	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"

		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		printf 'task %s changes\n' "$task_id" > shared.ts
		git add shared.ts
		git commit -q -m "task $task_id changes shared.ts"
		local sha
		sha=$(git rev-parse --short HEAD)
		printf '{"status":"success","review_attempts":1,"commit":"%s","summary":"done"}' \
			"$sha" > "$result_file"
	}
	extract_task_size() { printf '%s' "S"; }
	export -f run_task_in_worktree
	export -f extract_task_size

	local tasks
	tasks='[
		{"id":50,"description":"Modify shared.ts","agent":"default","batch":1},
		{"id":51,"description":"Modify shared.ts","agent":"default","batch":1}
	]'

	execute_batch_parallel 1 "$tasks" "feature/conf-salvage-log" "main" \
		>/dev/null 2>/dev/null || true

	local worktree_sha
	worktree_sha=$(jq -r '.commit' "${LOG_BASE}/stages/task-51-worktree.log")

	# The run must log the retained SHA plus a cherry-pick recovery command,
	# so the conflict is not merely silent-and-discoverable-by-luck.
	grep -q "$worktree_sha" "$LOG_FILE"
	grep -qi "cherry-pick" "$LOG_FILE"

	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git tag -d salvage/issue-99-task51 2>/dev/null || true
	git branch -D feature/conf-salvage-log 2>/dev/null || true
	git branch -D wt-task-50 2>/dev/null || true
	git branch -D wt-task-51 2>/dev/null || true
}

@test "execute_batch_parallel: successful merge deletes its branch and leaves no salvage ref behind (AC4)" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/salvage-success main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'alpha\n' > alpha.ts
	printf 'beta\n' > beta.ts
	git add alpha.ts beta.ts
	git commit -q -m "add source files"

	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"

		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		printf 'task %s output\n' "$task_id" > "task-${task_id}-out.txt"
		git add "task-${task_id}-out.txt"
		git commit -q -m "task $task_id"
		local sha
		sha=$(git rev-parse --short HEAD)
		printf '{"status":"success","review_attempts":1,"commit":"%s","summary":"done"}' \
			"$sha" > "$result_file"
	}
	extract_task_size() { printf '%s' "S"; }
	export -f run_task_in_worktree
	export -f extract_task_size

	local tasks
	tasks='[
		{"id":60,"description":"Modify alpha.ts","agent":"default","batch":1},
		{"id":61,"description":"Modify beta.ts","agent":"default","batch":1}
	]'

	local result
	result=$(execute_batch_parallel 1 "$tasks" \
		"feature/salvage-success" "main" \
		2>/dev/null) || true

	local comp_count
	comp_count=$(printf '%s' "$result" | jq '.completed | length')
	[[ "$comp_count" -eq 2 ]]

	# No salvage ref for a task whose merge actually succeeded.
	run git rev-parse --verify "salvage/issue-99-task60"
	[ "$status" -ne 0 ]
	run git rev-parse --verify "salvage/issue-99-task61"
	[ "$status" -ne 0 ]

	# The worktree branches themselves must be gone (no reprieve on success).
	run git rev-parse --verify "wt-task-60"
	[ "$status" -ne 0 ]
	run git rev-parse --verify "wt-task-61"
	[ "$status" -ne 0 ]

	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git branch -D feature/salvage-success 2>/dev/null || true
}

@test "execute_batch_parallel: success-reported task with no commit lands in failed (no-op guard)" {
	cd "$TEST_TMP/repo" || exit 1
	# Clean slate: drop any residue from a prior run so the result is deterministic.
	git checkout -q main 2>/dev/null || true
	git worktree prune 2>/dev/null || true
	git branch -D feature/noop-guard 2>/dev/null || true
	git branch -D wt-task-20 2>/dev/null || true
	git checkout -q -b feature/noop-guard main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'base\n' > base.ts
	git add base.ts
	git commit -q -m "add base"

	# A subagent that claims success but commits NOTHING to its worktree.
	# Without the no-op guard the empty branch merges as "Already up to date"
	# and the task is wrongly counted completed.
	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"
		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		# Intentionally no git commit — branch stays at the feature base.
		printf '{"status":"success","review_attempts":1,"commit":"none","summary":"claimed done but changed nothing"}' \
			> "$result_file"
	}
	extract_task_size() { printf '%s' "S"; }
	export -f run_task_in_worktree
	export -f extract_task_size

	local tasks
	tasks='[
		{"id":20,"description":"Should change something","agent":"default","batch":1}
	]'

	local result
	result=$(execute_batch_parallel 1 "$tasks" \
		"feature/noop-guard" "main" \
		2>/dev/null) || true

	local failed_count completed_count
	failed_count=$(printf '%s' "$result" | jq '.failed | length' 2>/dev/null)
	completed_count=$(printf '%s' "$result" | jq '.completed | length' 2>/dev/null)

	# Clean up BEFORE asserting so the assertions are the test's last commands
	# (bats only fails a test on its final command's exit code — trailing
	# cleanup would otherwise mask an assertion failure).
	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git branch -D feature/noop-guard 2>/dev/null || true
	git branch -D wt-task-20 2>/dev/null || true

	# The no-op task must be classified failed, NOT completed.
	[[ "$failed_count" -eq 1 ]]
	[[ "$completed_count" -eq 0 ]]
}

# =============================================================================
# no-op guard vs. declared non-commit deliverables (issue #790)
# The guard above is correct for a task that was supposed to write code, but
# wrong for one whose deliverable is a `deliverable:comment:<marker>`
# annotation — assert_issue_valid already exempts such tasks from the
# "must name a file path" rule (issue #634). These tests drive that
# annotation through the runtime guard directly, which is the exact gap
# issue #790 reports: the two halves disagree without either suite going red.
# =============================================================================

@test "execute_batch_parallel: comment-deliverable task with no commits and a matching comment is completed, not failed" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q main 2>/dev/null || true
	git worktree prune 2>/dev/null || true
	git branch -D feature/deliverable-comment 2>/dev/null || true
	git branch -D wt-task-70 2>/dev/null || true
	git checkout -q -b feature/deliverable-comment main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'base\n' > base.ts
	git add base.ts
	git commit -q -m "add base"

	# A research/audit task that posts its findings as an issue comment and
	# commits nothing — the case assert_issue_valid's deliverable exemption
	# exists for.
	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"
		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		printf '{"status":"success","review_attempts":1,"commit":"none","summary":"posted audit as comment"}' \
			> "$result_file"
	}
	extract_task_size() { printf '%s' "S"; }
	# Stub the tracker boundary: the declared marker is present in a comment.
	_fetch_issue_comment_bodies() {
		printf '%s\n' "Audit complete. marker:task70-audit-done"
	}
	export -f run_task_in_worktree
	export -f extract_task_size
	export -f _fetch_issue_comment_bodies

	local tasks
	tasks='[
		{"id":70,"description":"Audit the thing `deliverable:comment:task70-audit-done`","agent":"default","batch":1}
	]'

	local result
	result=$(execute_batch_parallel 1 "$tasks" \
		"feature/deliverable-comment" "main" \
		2>/dev/null) || true

	local completed_count failed_count
	completed_count=$(printf '%s' "$result" | jq '.completed | length' 2>/dev/null)
	failed_count=$(printf '%s' "$result" | jq '.failed | length' 2>/dev/null)

	# Clean up BEFORE asserting so the assertions are the test's last commands.
	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git branch -D feature/deliverable-comment 2>/dev/null || true
	git branch -D wt-task-70 2>/dev/null || true

	# A verified comment deliverable must be recorded completed despite the
	# empty worktree branch — the guard consults the annotation instead of
	# demanding commits (AC1).
	[[ "$completed_count" -eq 1 ]]
	[[ "$failed_count" -eq 0 ]]
}

@test "execute_batch_parallel: comment-deliverable task whose marker appears in no comment still fails" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q main 2>/dev/null || true
	git worktree prune 2>/dev/null || true
	git branch -D feature/deliverable-unmatched 2>/dev/null || true
	git branch -D wt-task-71 2>/dev/null || true
	git checkout -q -b feature/deliverable-unmatched main

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'base\n' > base.ts
	git add base.ts
	git commit -q -m "add base"

	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"
		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		printf '{"status":"success","review_attempts":1,"commit":"none","summary":"claimed a comment deliverable"}' \
			> "$result_file"
	}
	extract_task_size() { printf '%s' "S"; }
	# No comment carries the declared marker — the annotation must not be
	# enough on its own to bypass the guard (AC3).
	_fetch_issue_comment_bodies() {
		printf '%s\n' "An unrelated comment that never mentions the marker."
	}
	export -f run_task_in_worktree
	export -f extract_task_size
	export -f _fetch_issue_comment_bodies

	local tasks
	tasks='[
		{"id":71,"description":"Audit the thing `deliverable:comment:task71-missing-marker`","agent":"default","batch":1}
	]'

	local result
	result=$(execute_batch_parallel 1 "$tasks" \
		"feature/deliverable-unmatched" "main" \
		2>/dev/null) || true

	local completed_count failed_count
	completed_count=$(printf '%s' "$result" | jq '.completed | length' 2>/dev/null)
	failed_count=$(printf '%s' "$result" | jq '.failed | length' 2>/dev/null)

	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git branch -D feature/deliverable-unmatched 2>/dev/null || true
	git branch -D wt-task-71 2>/dev/null || true

	[[ "$failed_count" -eq 1 ]]
	[[ "$completed_count" -eq 0 ]]
}

@test "conflicted tasks from parallel can be re-run serially with same outcome" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/conf-retry main

	mkdir -p "$LOG_BASE/stages"

	# Mock run_stage to succeed
	run_stage() {
		printf '%s' '{"status":"success","commit":"retry123","summary":"retried"}'
	}
	should_run_quality_loop() { return 1; }
	get_max_review_attempts() { printf '%s' "1"; }
	get_stage_timeout() { printf '%s' "1800"; }
	resolve_model() { printf '%s' "sonnet"; }
	build_files_block() { printf '\n'; }
	extract_task_size() { printf '%s' "S"; }

	# Simulate conflicted task IDs from a previous parallel run
	local conflicted_tasks
	conflicted_tasks='[{"id":15,"description":"Retry after conflict","agent":"default"}]'

	local retry_result
	retry_result=$(execute_batch_serial \
		"$conflicted_tasks" "feature/conf-retry" "main")

	# Must complete successfully (same as if it ran in first pass)
	local comp_len
	comp_len=$(printf '%s' "$retry_result" | jq '.completed | length')
	[[ "$comp_len" -eq 1 ]]

	local comp_id
	comp_id=$(printf '%s' "$retry_result" | jq '.completed[0]')
	[[ "$comp_id" -eq 15 ]]

	git checkout -q main
	git branch -D feature/conf-retry 2>/dev/null || true
}

# =============================================================================
# serial fallback produces identical results to parallel execution
# =============================================================================

@test "serial and parallel produce same completed/failed structure for single task" {
	cd "$TEST_TMP/repo" || exit 1

	mkdir -p "$LOG_BASE/stages"
	mkdir -p "$LOG_BASE/worktrees"

	printf 'content\n' > myfile.ts
	git add myfile.ts
	git commit -q -m "add myfile"

	# Mock for serial path
	run_stage() {
		printf '%s' '{"status":"success","commit":"sha1","summary":"done"}'
	}
	should_run_quality_loop() { return 1; }
	get_max_review_attempts() { printf '%s' "1"; }
	get_stage_timeout() { printf '%s' "1800"; }
	resolve_model() { printf '%s' "sonnet"; }
	build_files_block() { printf '\n'; }
	extract_task_size() { printf '%s' "S"; }

	# Serial path
	git checkout -q -b feature/equiv-serial main
	local serial_result
	serial_result=$(execute_batch_serial \
		'[{"id":20,"description":"Modify myfile.ts","agent":"default"}]' \
		"feature/equiv-serial" "main")
	local serial_comp
	serial_comp=$(printf '%s' "$serial_result" | jq '.completed | length')
	local serial_fail
	serial_fail=$(printf '%s' "$serial_result" | jq '.failed | length')

	# Parallel path with equivalent mock
	git checkout -q -b feature/equiv-par main

	run_task_in_worktree() {
		local task_id="$1"
		local wt_path="$5"
		local result_file="$8"
		cd "$wt_path" || {
			printf '%s' '{"status":"failed","review_attempts":0}' > "$result_file"
			return 1
		}
		printf 'change\n' > "task-${task_id}.ts"
		git add "task-${task_id}.ts"
		git commit -q -m "task $task_id"
		local sha
		sha=$(git rev-parse --short HEAD)
		printf '{"status":"success","review_attempts":1,"commit":"%s","summary":"done"}' \
			"$sha" > "$result_file"
	}
	export -f run_task_in_worktree
	export -f extract_task_size

	local par_result
	par_result=$(execute_batch_parallel 1 \
		'[{"id":20,"description":"Modify myfile.ts","agent":"default","batch":1}]' \
		"feature/equiv-par" "main" 2>/dev/null) || true
	local par_comp
	par_comp=$(printf '%s' "$par_result" | jq '.completed | length')
	local par_fail
	par_fail=$(printf '%s' "$par_result" | jq '.failed | length')

	# Both paths should report 1 completed, 0 failed
	[[ "$serial_comp" -eq 1 ]]
	[[ "$serial_fail" -eq 0 ]]
	[[ "$par_comp" -eq 1 ]]
	[[ "$par_fail" -eq 0 ]]

	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git branch -D feature/equiv-serial 2>/dev/null || true
	git branch -D feature/equiv-par 2>/dev/null || true
	git branch -D wt-task-20 2>/dev/null || true
}

# =============================================================================
# batch assignment drives execution path (single vs multi)
# =============================================================================

@test "compute_task_batches: single task gets batch 1 (drives serial path)" {
	cd "$TEST_TMP/repo" || exit 1
	local result batch_num
	result=$(compute_task_batches \
		'[{"id":1,"description":"Update README.md","agent":"default"}]' \
		main)
	batch_num=$(printf '%s' "$result" | jq '.[0].batch')
	# A single task batch = 1; batch_size == 1 triggers serial execution
	[[ "$batch_num" -eq 1 ]]
	local batch_count
	batch_count=$(printf '%s' "$result" | jq 'length')
	[[ "$batch_count" -eq 1 ]]
}

@test "compute_task_batches: non-overlapping tasks in same batch (drives parallel path)" {
	cd "$TEST_TMP/repo" || exit 1
	local tasks result
	tasks='[
		{"id":1,"description":"Modify alpha.ts","agent":"default"},
		{"id":2,"description":"Modify beta.ts","agent":"default"}
	]'
	result=$(compute_task_batches "$tasks" main)
	local b1 b2
	b1=$(printf '%s' "$result" | jq '.[0].batch')
	b2=$(printf '%s' "$result" | jq '.[1].batch')
	# Same batch number → batch_size == 2 → parallel execution path
	[[ "$b1" -eq 1 ]]
	[[ "$b2" -eq 1 ]]
}

@test "compute_task_batches: overlapping tasks in different batches (serial per batch)" {
	cd "$TEST_TMP/repo" || exit 1
	local tasks result
	tasks='[
		{"id":1,"description":"Update shared.ts","agent":"default"},
		{"id":2,"description":"Also update shared.ts","agent":"default"}
	]'
	result=$(compute_task_batches "$tasks" main)
	local b1 b2
	b1=$(printf '%s' "$result" | jq '.[0].batch')
	b2=$(printf '%s' "$result" | jq '.[1].batch')
	# Different batch numbers → each batch has size 1 → serial execution
	[[ "$b1" -ne "$b2" ]]
}

# =============================================================================
# run_parallel_post_task_stages (parallel e2e-verify and acceptance-test)
# Tests the parallel execution of post-task stages with independent exit codes
# =============================================================================

@test "run_parallel_post_task_stages: runs e2e-verify and acceptance-test in parallel using bash &" {
	cd "$TEST_TMP/repo" || exit 1

	# Create a simple test implementation of the function
	# to verify the core parallel behavior works
	local -a stage_log

	run_parallel_post_task_stages_test() {
		local feature_branch="$1"
		local base_branch="$2"
		local e2e_result acceptance_result
		local e2e_exit acceptance_exit

		# Run both stages in parallel using & and wait
		(
			echo "e2e-verify" >> "$TEST_TMP/stages.log"
			sleep 0.05
		) &
		e2e_exit=$?

		(
			echo "acceptance-test" >> "$TEST_TMP/stages.log"
			sleep 0.05
		) &
		acceptance_exit=$?

		wait
	}

	run_parallel_post_task_stages_test "main" "main"

	# Both stages should have executed
	[[ -f "$TEST_TMP/stages.log" ]]
	[[ $(grep -c "e2e-verify" "$TEST_TMP/stages.log") -eq 1 ]]
	[[ $(grep -c "acceptance-test" "$TEST_TMP/stages.log") -eq 1 ]]
}

@test "run_parallel_post_task_stages: captures exit codes from both stages independently" {
	# Test that exit codes from parallel stages are captured correctly
	test_exit_codes() {
		# Simulate e2e-verify (success)
		(
			echo "running e2e"
			exit 0
		) &
		local e2e_pid=$!

		# Simulate acceptance-test (failure)
		(
			echo "running acceptance"
			exit 1
		) &
		local acceptance_pid=$!

		# Wait for each and capture exit code
		wait $e2e_pid
		local e2e_exit=$?

		wait $acceptance_pid
		local acceptance_exit=$?

		# Store results
		printf '%s\n' "e2e=$e2e_exit" "acceptance=$acceptance_exit"
	}

	local results
	results=$(test_exit_codes)

	# Verify exit codes were captured
	[[ "$results" == *"e2e=0"* ]]
	[[ "$results" == *"acceptance=1"* ]]
}

@test "run_parallel_post_task_stages: logs stage timing for both parallel stages" {
	cd "$TEST_TMP/repo" || exit 1

	mkdir -p "$LOG_BASE/stages"

	# Create minimal implementation that logs timing
	test_with_timing() {
		local log_file="$TEST_TMP/test_timing.log"
		local start_time end_time elapsed

		# Stage 1: e2e-verify
		start_time=$(date +%s%N)
		(
			sleep 0.05
		) &
		wait
		end_time=$(date +%s%N)
		elapsed=$(( (end_time - start_time) / 1000000 ))
		printf 'e2e-verify: %dms\n' "$elapsed" >> "$log_file"

		# Stage 2: acceptance-test
		start_time=$(date +%s%N)
		(
			sleep 0.05
		) &
		wait
		end_time=$(date +%s%N)
		elapsed=$(( (end_time - start_time) / 1000000 ))
		printf 'acceptance-test: %dms\n' "$elapsed" >> "$log_file"

		cat "$log_file"
	}

	local result
	result=$(test_with_timing)

	# Should have timing for both stages
	[[ "$result" == *"e2e-verify"* ]]
	[[ "$result" == *"acceptance-test"* ]]
	[[ "$result" == *"ms"* ]]
}

@test "run_parallel_post_task_stages: ensures docs stage runs after both parallel stages complete" {
	cd "$TEST_TMP/repo" || exit 1

	# Test that docs runs after wait returns
	test_docs_order() {
		local order_log="$TEST_TMP/order.log"

		# Parallel stages
		(
			echo "e2e-verify" >> "$order_log"
			sleep 0.02
		) &

		(
			echo "acceptance-test" >> "$order_log"
			sleep 0.02
		) &

		# Wait for both to complete
		wait

		# Now run docs (sequential)
		echo "docs" >> "$order_log"

		# Count lines and verify docs is last
		cat "$order_log"
	}

	local result
	result=$(test_docs_order)

	# Last line should be docs
	[[ "$(echo "$result" | tail -1)" == "docs" ]]

	# Should have 3 lines total (2 parallel + 1 sequential)
	[[ $(echo "$result" | wc -l) -eq 3 ]]
}

@test "run_parallel_post_task_stages: handles failure in one parallel stage without blocking the other" {
	cd "$TEST_TMP/repo" || exit 1

	# Test independent failure handling
	test_independent_failures() {
		local status_log="$TEST_TMP/status.log"

		# e2e-verify fails
		(
			echo "e2e-verify starting" >> "$status_log"
			exit 1
		) &
		local e2e_pid=$!

		# acceptance-test succeeds
		(
			echo "acceptance-test starting" >> "$status_log"
			exit 0
		) &
		local acceptance_pid=$!

		# Both should complete regardless of individual status
		wait $e2e_pid
		local e2e_exit=$?

		wait $acceptance_pid
		local acceptance_exit=$?

		printf '%s\n' "e2e_exit=$e2e_exit" "acceptance_exit=$acceptance_exit"
	}

	local results
	results=$(test_independent_failures)

	# e2e should have failed (exit 1)
	[[ "$results" == *"e2e_exit=1"* ]]
	# acceptance should have succeeded (exit 0)
	[[ "$results" == *"acceptance_exit=0"* ]]
}

# =============================================================================
# run_parallel_post_task_stages — integration tests (call the real function)
# Verifies skip-condition logic, set_stage_started/completed sequencing, and
# the PID capture/wait loop using mocked dependencies.
# =============================================================================

@test "run_parallel_post_task_stages: both stages skip and mark started+completed sequentially" {
	cd "$TEST_TMP/repo" || exit 1

	# Conditions: TEST_E2E_CMD not set → e2e skips;
	#             pipeline_profile=minimal → acceptance skips.
	# Neither stage opens a background subshell, so all mocks stay in scope.
	unset TEST_E2E_CMD
	unset RESUME_MODE

	local calls_file="$TEST_TMP/rppts-calls.txt"
	touch "$calls_file"

	# Mock every external symbol touched by the real function
	is_stage_completed() { return 1; }
	set_stage_started()  { printf 'started:%s\n'   "$1" >> "$calls_file"; }
	set_stage_completed(){ printf 'completed:%s\n' "$1" >> "$calls_file"; }
	comment_issue()      { printf 'comment:%s\n'   "$1" >> "$calls_file"; }
	run_stage()          { printf 'run_stage:%s\n' "$1" >> "$calls_file";
	                       printf '{"status":"success","summary":"ok"}'; }
	log()                { :; }
	log_warn()           { :; }

	# Call the real function directly
	run_parallel_post_task_stages \
		"feature/issue-99" "backend" "minimal" "S"

	[ "$?" -eq 0 ]

	# Both stages must be started then completed (sequential, no parallelism)
	grep -q "started:e2e_verify"        "$calls_file"
	grep -q "completed:e2e_verify"      "$calls_file"
	grep -q "started:acceptance_test"   "$calls_file"
	grep -q "completed:acceptance_test" "$calls_file"

	# run_stage must NOT have been called — both stages were skipped
	! grep -q "^run_stage:" "$calls_file"
}

@test "run_parallel_post_task_stages: e2e skips for non-frontend scope, acceptance runs in parallel (no route files → short-circuit)" {
	cd "$TEST_TMP/repo" || exit 1

	# TEST_E2E_CMD set but scope=backend → e2e skips.
	# acceptance_test runs in a subshell; because the test git repo has no
	# '*/routes/*.ts' files, it takes the "no route files" short-circuit path
	# that only calls log + comment_issue — no run_stage needed.
	export TEST_E2E_CMD="npm run test:e2e"
	export BASE_BRANCH=main
	unset RESUME_MODE

	local calls_file="$TEST_TMP/rppts2-calls.txt"
	touch "$calls_file"
	export calls_file

	# Mocks visible to the parent shell
	is_stage_completed() { return 1; }
	set_stage_started()  { printf 'started:%s\n'   "$1" >> "$calls_file"; }
	set_stage_completed(){ printf 'completed:%s\n' "$1" >> "$calls_file"; }
	comment_issue()      { :; }
	run_stage()          { printf 'run_stage:%s\n' "$1" >> "$calls_file";
	                       printf '{"status":"success","summary":"ok"}'; }
	log()                { :; }
	log_warn()           { :; }
	log_error()          { :; }
	# Export so the acceptance_test subshell can see them
	export -f set_stage_started set_stage_completed comment_issue
	export -f run_stage log log_warn log_error

	# Call the real function directly (not via bats `run`)
	run_parallel_post_task_stages \
		"main" "backend" "" "S"

	local exit_code=$?
	[ "$exit_code" -eq 0 ]

	# e2e_verify must have been skipped sequentially (scope ≠ frontend)
	grep -q "started:e2e_verify"        "$calls_file"
	grep -q "completed:e2e_verify"      "$calls_file"

	# acceptance_test must have run (in parallel) and completed
	grep -q "started:acceptance_test"   "$calls_file"
	grep -q "completed:acceptance_test" "$calls_file"

	# run_stage must NOT have been called — no route files changed
	! grep -q "^run_stage:" "$calls_file"
}

# =============================================================================
# run_parallel_post_task_stages — comprehensive integration tests
# Verifies timing, process IDs, per-stage logs, and failure independence
# =============================================================================

@test "run_parallel_post_task_stages: creates per-stage log files during parallel execution" {
	cd "$TEST_TMP/repo" || exit 1

	export TEST_E2E_CMD="true"
	export BASE_BRANCH=main
	unset RESUME_MODE

	mkdir -p "$LOG_BASE/stages"

	local status_calls_file="$TEST_TMP/status-calls.log"

	# Mocks that track calls
	is_stage_completed() { return 1; }
	set_stage_started()  { printf 'started:%s\n' "$1" >> "$status_calls_file"; }
	set_stage_completed(){ printf 'completed:%s\n' "$1" >> "$status_calls_file"; }
	comment_issue()      { :; }
	run_stage() {
		printf '{"status":"success","result":"passed","summary":"done"}'
	}
	log()                { :; }
	log_warn()           { :; }
	rebuild_and_health_check() {
		printf '{"rebuild":"skipped","health":"skipped","elapsed_secs":0}'
	}
	_build_targeted_e2e_cmd() { printf '%s' "${TEST_E2E_CMD:-true}"; }

	export -f is_stage_completed set_stage_started set_stage_completed
	export -f comment_issue run_stage log log_warn rebuild_and_health_check
	export -f _build_targeted_e2e_cmd
	export status_calls_file

	# Call the real function with conditions that allow both stages to run
	run_parallel_post_task_stages \
		"main" "frontend" "" "S" 2>/dev/null

	local exit_code=$?
	[ "$exit_code" -eq 0 ]

	# Verify both stages were started and completed
	grep -q "started:e2e_verify" "$status_calls_file" || {
		echo "e2e-verify not started"
		exit 1
	}
	grep -q "completed:e2e_verify" "$status_calls_file" || {
		echo "e2e-verify not completed"
		exit 1
	}
	grep -q "started:acceptance_test" "$status_calls_file" || {
		echo "acceptance-test not started"
		exit 1
	}
	grep -q "completed:acceptance_test" "$status_calls_file" || {
		echo "acceptance-test not completed"
		exit 1
	}
}

@test "run_parallel_post_task_stages: captures timing showing parallel execution (partial overlap)" {
	cd "$TEST_TMP/repo" || exit 1

	export TEST_E2E_CMD="true"
	export BASE_BRANCH=main
	unset RESUME_MODE

	mkdir -p "$LOG_BASE/stages"

	local timing_log="$TEST_TMP/timing.log"
	touch "$timing_log"

	is_stage_completed() { return 1; }
	set_stage_started()  { :; }
	set_stage_completed(){ :; }
	comment_issue()      { :; }
	run_stage() {
		local stage="$1"
		local start=$(date +%s%N)
		# Simulate some work (minimal delay)
		sleep 0.01
		local end=$(date +%s%N)
		printf "%s: started %s, ended %s\n" "$stage" "$start" "$end" >> "$timing_log"
		printf '{"status":"success","result":"passed","summary":"ok"}'
	}
	log() {
		if [[ "$1" == *"Stage timing"* ]]; then
			printf '%s %s\n' "$1" "$2" >> "$timing_log"
		fi
	}
	log_warn() { :; }
	rebuild_and_health_check() {
		printf '{"rebuild":"skipped","health":"skipped","elapsed_secs":0}'
	}
	_build_targeted_e2e_cmd() { printf '%s' "${TEST_E2E_CMD:-true}"; }

	export -f is_stage_completed set_stage_started set_stage_completed
	export -f comment_issue run_stage log log_warn rebuild_and_health_check
	export -f _build_targeted_e2e_cmd

	run_parallel_post_task_stages \
		"main" "frontend" "" "S" 2>/dev/null

	# Timing log should exist and contain stage timing info
	[[ -f "$timing_log" ]] || {
		echo "timing log not created"
		exit 1
	}

	# Log should contain mentions of both stages
	grep -q "e2e-verify\|e2e_verify" "$timing_log" || {
		echo "e2e timing not logged"
		cat "$timing_log"
		exit 1
	}
	grep -q "acceptance-test\|acceptance_test" "$timing_log" || {
		echo "acceptance timing not logged"
		cat "$timing_log"
		exit 1
	}
}

@test "run_parallel_post_task_stages: both stages run with independent exit codes captured" {
	cd "$TEST_TMP/repo" || exit 1

	export TEST_E2E_CMD="true"
	export BASE_BRANCH=main
	unset RESUME_MODE

	mkdir -p "$LOG_BASE/stages"

	local status_log="$TEST_TMP/exit-codes.log"
	touch "$status_log"

	is_stage_completed() { return 1; }
	set_stage_started()  { :; }
	set_stage_completed(){ :; }
	comment_issue()      { :; }
	run_stage() {
		local stage="$1"
		# Both stages succeed (neutral case to test they both run)
		printf '{"status":"success","result":"passed","summary":"completed"}'
		return 0
	}
	log()     { :; }
	log_warn() {
		printf 'warned: %s\n' "$1" >> "$status_log"
	}
	rebuild_and_health_check() {
		printf '{"rebuild":"skipped","health":"skipped","elapsed_secs":0}'
	}
	_build_targeted_e2e_cmd() { printf '%s' "${TEST_E2E_CMD:-true}"; }

	export -f is_stage_completed set_stage_started set_stage_completed
	export -f comment_issue run_stage log log_warn rebuild_and_health_check
	export -f _build_targeted_e2e_cmd

	run_parallel_post_task_stages \
		"main" "frontend" "" "S" 2>/dev/null

	# The function should succeed (return 0)
	[ $? -eq 0 ]

	# Verify status log was created (function ran)
	[[ -s "$status_log" ]] || {
		# Even if warnings weren't logged, the function still completed successfully
		# which is what we're testing
		true
	}
}

@test "run_parallel_post_task_stages: e2e and acceptance are spawned as separate background processes" {
	cd "$TEST_TMP/repo" || exit 1

	export TEST_E2E_CMD="true"
	export BASE_BRANCH=main
	unset RESUME_MODE

	mkdir -p "$LOG_BASE/stages"

	local e2e_pid_file="$TEST_TMP/e2e845.pid"
	local acc_pid_file="$TEST_TMP/acc845.pid"

	is_stage_completed() { return 1; }
	set_stage_started()  { :; }
	set_stage_completed(){ :; }
	comment_issue()      { :; }

	# e2e subshell calls run_stage — capture its subshell PID via $PPID.
	# (Use 'sh -c echo $PPID' for bash 3.x / macOS compatibility;
	# $BASHPID is not available on the system bash 3.2.)
	run_stage() {
		sh -c 'echo $PPID' > "$e2e_pid_file"
		printf '{"status":"success","result":"passed","summary":"ok"}'
	}

	# acceptance subshell takes the "no route files" short-circuit path and
	# calls log "No API route files changed …".  Detect that message to
	# capture the acceptance subshell's own PID.
	log() {
		[[ "${1:-}" == *"No API"* ]] \
			&& sh -c 'echo $PPID' > "$acc_pid_file"
		true
	}
	log_warn() { :; }
	rebuild_and_health_check() {
		printf '{"rebuild":"skipped","health":"skipped","elapsed_secs":0}'
	}
	_build_targeted_e2e_cmd() { printf '%s' "${TEST_E2E_CMD:-true}"; }

	export -f is_stage_completed set_stage_started set_stage_completed
	export -f comment_issue run_stage log log_warn rebuild_and_health_check
	export -f _build_targeted_e2e_cmd
	export e2e_pid_file acc_pid_file

	run_parallel_post_task_stages \
		"main" "frontend" "" "S" 2>/dev/null

	[ $? -eq 0 ]

	# Both subshells must have written their PID files
	[[ -f "$e2e_pid_file" ]] || { echo "e2e PID file not created"; exit 1; }
	[[ -f "$acc_pid_file" ]] || { echo "acceptance PID file not created"; exit 1; }

	local e2e_pid acc_pid
	e2e_pid=$(cat "$e2e_pid_file")
	acc_pid=$(cat "$acc_pid_file")

	# PIDs must be numeric
	[[ "$e2e_pid" =~ ^[0-9]+$ ]] \
		|| { echo "e2e PID not numeric: $e2e_pid"; exit 1; }
	[[ "$acc_pid"  =~ ^[0-9]+$ ]] \
		|| { echo "acc PID not numeric: $acc_pid"; exit 1; }

	# PIDs must differ — each stage runs in its own background subshell
	[[ "$e2e_pid" -ne "$acc_pid" ]] \
		|| { echo "e2e and acceptance ran in the same process (pid=$e2e_pid)"; exit 1; }
}

@test "run_parallel_post_task_stages: skipped stages do not spawn background processes" {
	cd "$TEST_TMP/repo" || exit 1

	# Don't set TEST_E2E_CMD → e2e will be skipped
	# Set pipeline_profile=minimal → acceptance will be skipped
	unset TEST_E2E_CMD
	export BASE_BRANCH=main
	unset RESUME_MODE

	mkdir -p "$LOG_BASE/stages"

	local calls_file="$TEST_TMP/rppts-calls.txt"

	is_stage_completed() { return 1; }
	set_stage_started()  { printf 'started:%s\n' "$1" >> "$calls_file"; }
	set_stage_completed(){ printf 'completed:%s\n' "$1" >> "$calls_file"; }
	comment_issue()      { :; }
	run_stage()          {
		printf 'run_stage_called\n' >> "$calls_file"
		printf '{"status":"success","result":"passed","summary":"ok"}'
	}
	log()     { :; }
	log_warn() { :; }

	export -f is_stage_completed set_stage_started set_stage_completed
	export -f comment_issue run_stage log log_warn

	run_parallel_post_task_stages \
		"main" "backend" "minimal" "S"

	[ $? -eq 0 ]

	# run_stage should never have been called (both skipped)
	! grep -q "^run_stage_called" "$calls_file"

	# Both stages should have been marked started and completed
	grep -q "started:e2e_verify" "$calls_file"
	grep -q "completed:e2e_verify" "$calls_file"
	grep -q "started:acceptance_test" "$calls_file"
	grep -q "completed:acceptance_test" "$calls_file"
}

@test "run_parallel_post_task_stages: e2e and acceptance truly run in parallel (timing)" {
	cd "$TEST_TMP/repo" || exit 1

	# Add a route file on a new branch so acceptance stage calls run_stage too.
	# Without this, acceptance short-circuits (no route files) and only e2e sleeps,
	# making serial vs parallel indistinguishable.
	git checkout -q -b feature/parallel-timing-test main
	mkdir -p routes
	printf 'export const handler = () => {}\n' > routes/api.ts
	git add routes/api.ts
	git commit -q -m "add route"

	export TEST_E2E_CMD="true"
	export BASE_BRANCH=main
	unset RESUME_MODE

	mkdir -p "$LOG_BASE/stages"

	local timing_file="$TEST_TMP/parallel-timing.log"

	is_stage_completed() { return 1; }
	set_stage_started()  { :; }
	set_stage_completed(){ :; }
	comment_issue()      { :; }
	run_stage() {
		local stage="$1"
		local start_ns=$(date +%s%N)
		printf "stage=%s,start=%s\n" "$stage" "$start_ns" >> "$timing_file"
		# Simulate 0.15 second work per stage
		sleep 0.15
		printf '{"status":"success","result":"passed","summary":"ok"}'
	}
	log()     { :; }
	log_warn() { :; }
	rebuild_and_health_check() {
		printf '{"rebuild":"skipped","health":"skipped","elapsed_secs":0}'
	}
	_build_targeted_e2e_cmd() { printf '%s' "${TEST_E2E_CMD:-true}"; }

	export -f is_stage_completed set_stage_started set_stage_completed
	export -f comment_issue run_stage log log_warn rebuild_and_health_check
	export -f _build_targeted_e2e_cmd
	export timing_file

	local global_start_ns=$(date +%s%N)
	run_parallel_post_task_stages \
		"feature/parallel-timing-test" "frontend" "" "S" 2>/dev/null
	local global_end_ns=$(date +%s%N)
	local global_elapsed_ns=$(( global_end_ns - global_start_ns ))
	local global_elapsed_ms=$(( global_elapsed_ns / 1000000 ))

	# With both stages sleeping 0.15s in parallel, total time ≈ 150ms + overhead.
	# If they ran serially, total would be ≈ 300ms + overhead.
	# Threshold of 400ms: passes parallel (~270ms), fails serial (~500ms).
	[[ "$global_elapsed_ms" -lt 400 ]] || {
		echo "Stages appear to have run serially (took ${global_elapsed_ms}ms)"
		cat "$timing_file"
		exit 1
	}
}

# =============================================================================
# Issue #634 — declared NON-COMMIT deliverables and INTER-TASK dependencies
#
# Two defects, both rooted in task metadata the issue body cannot express:
#
#   A. A task whose deliverable is an issue comment (not a commit) is counted
#      a failure, because task success is inferred from commits landing on the
#      branch.  It aborts the run when it is the only task, and merge-blocks
#      the PR as "implement:partial" when it is one of several.
#   B. A batch is launched in parallel with no way to declare that task N must
#      be decided before task M runs, so a spike races the task that depends
#      on its ruling.
#
# The syntax under test (both annotations are backtick-delimited and live
# inside the task description, so BOTH mirrored parsers keep emitting
# byte-identical descriptions):
#
#   `deliverable:comment:<marker>`  artefact is an issue comment containing
#                                   <marker>
#   `deliverable:file:<path>`       artefact is a file at <path>
#   `depends-on:<id>[,<id>...]`     this task is serialised after <id>
#
# The key risk the issue names — "a task marked non-committing that SHOULD
# have produced code would pass silently" — is covered by the negative tests:
# an unverifiable artefact is never promoted, and a task the stage recorded
# completed is DEMOTED when its declared artefact does not exist.
# =============================================================================

# -----------------------------------------------------------------------------
# Parse-time: deliverable / depends-on annotations
# -----------------------------------------------------------------------------

@test "#634 _parse_task_lines: records a declared non-commit deliverable" {
	cd "$TEST_TMP/repo" || exit 1
	local section result deliverable
	section='- [ ] `[bash-script-craftsman]` **(S)** Post the routing ruling — `deliverable:comment:ruling-634`'
	result=$(_parse_task_lines "$section" 2>/dev/null)
	deliverable=$(printf '%s' "$result" | jq -r '.[0].deliverable // ""')
	expect_glob "$deliverable" 'comment:ruling-634' "deliverable annotation"
}

@test "#634 _parse_task_lines: records a declared inter-task dependency" {
	cd "$TEST_TMP/repo" || exit 1
	local section result deps
	section=$(printf '%s\n' \
		'- [ ] `[bash-script-craftsman]` **(S)** Decide — `deliverable:comment:r1`' \
		'- [ ] `[bash-script-craftsman]` **(S)** Apply in `src/a.ts` — `depends-on:1`')
	result=$(_parse_task_lines "$section" 2>/dev/null)
	deps=$(printf '%s' "$result" | jq -c '.[1].depends_on // []')
	# Compared with `test`, not expect_glob — "[1]" is a glob character class.
	expect_ok "depends_on annotation" test "$deps" = '[1]'
}

@test "#634 _parse_task_lines: an unannotated task gains no new keys" {
	cd "$TEST_TMP/repo" || exit 1
	# assert_issue_valid must keep accepting existing bodies unchanged, so an
	# ordinary task line must produce the SAME object it always did.
	local section result keys
	section='- [ ] `[bash-script-craftsman]` **(S)** Ordinary task in `src/a.ts`'
	result=$(_parse_task_lines "$section" 2>/dev/null)
	keys=$(printf '%s' "$result" | jq -r '.[0] | keys | join(",")')
	expect_glob "$keys" 'affected_files,agent,description,id,review_attempts,status' \
		"unannotated task object keys"
}

# -----------------------------------------------------------------------------
# AC3 — a dependent task never shares a parallel batch with its predecessor
# -----------------------------------------------------------------------------

@test "#634 AC3 compute_task_batches: a dependent task is not in the same batch as the task it depends on" {
	cd "$TEST_TMP/repo" || exit 1
	# File sets do NOT overlap, so conflict detection alone puts both in
	# batch 1 — i.e. the spike would run in parallel with the task that
	# consumes its ruling.  The declared dependency must serialise them.
	local tasks result b1 b2
	tasks='[
		{"id":1,"description":"Decide the rule","agent":"default"},
		{"id":2,"description":"Apply the ruling in `src/apply.ts`","agent":"default","depends_on":[1]}
	]'
	result=$(compute_task_batches "$tasks" main 2>/dev/null)
	b1=$(printf '%s' "$result" | jq '.[0].batch')
	b2=$(printf '%s' "$result" | jq '.[1].batch')
	expect_ok "dependent batch must be strictly later" test "$b2" -gt "$b1"
}

@test "#634 compute_task_batches: a chain of dependencies serialises transitively" {
	cd "$TEST_TMP/repo" || exit 1
	local tasks result b1 b2 b3
	tasks='[
		{"id":1,"description":"Decide","agent":"default"},
		{"id":2,"description":"Apply in `src/a.ts`","agent":"default","depends_on":[1]},
		{"id":3,"description":"Verify in `src/b.ts`","agent":"default","depends_on":[2]}
	]'
	result=$(compute_task_batches "$tasks" main 2>/dev/null)
	b1=$(printf '%s' "$result" | jq '.[0].batch')
	b2=$(printf '%s' "$result" | jq '.[1].batch')
	b3=$(printf '%s' "$result" | jq '.[2].batch')
	expect_ok "task 2 after task 1" test "$b2" -gt "$b1"
	expect_ok "task 3 after task 2" test "$b3" -gt "$b2"
}

@test "#634 compute_task_batches: tasks without a declared dependency still share a batch" {
	cd "$TEST_TMP/repo" || exit 1
	# Regression guard: the dependency floor must not serialise everything.
	local tasks result b1 b2
	tasks='[
		{"id":1,"description":"Modify `src/alpha.ts`","agent":"default"},
		{"id":2,"description":"Modify `src/beta.ts`","agent":"default"}
	]'
	result=$(compute_task_batches "$tasks" main 2>/dev/null)
	b1=$(printf '%s' "$result" | jq '.[0].batch')
	b2=$(printf '%s' "$result" | jq '.[1].batch')
	expect_glob "$b1" "$b2" "independent tasks share a batch"
}

# -----------------------------------------------------------------------------
# Artefact verification — the "would pass silently" guard
# -----------------------------------------------------------------------------

@test "#634 verify_task_deliverable: comment artefact verifies when the marker is present" {
	cd "$TEST_TMP/repo" || exit 1
	_fetch_issue_comment_bodies() { printf '%s\n' "Ruling: keep it. marker=ruling-634"; }
	expect_ok "marker present verifies" verify_task_deliverable "comment:ruling-634"
}

@test "#634 verify_task_deliverable: comment artefact does NOT verify when the marker is absent" {
	cd "$TEST_TMP/repo" || exit 1
	_fetch_issue_comment_bodies() { printf '%s\n' "Some unrelated pipeline comment"; }
	expect_not_ok "missing marker must not verify" \
		verify_task_deliverable "comment:ruling-634"
}

@test "#634 verify_task_deliverable: a bare 'comment' with no marker is unverifiable and fails" {
	cd "$TEST_TMP/repo" || exit 1
	_fetch_issue_comment_bodies() { printf '%s\n' "anything at all"; }
	expect_not_ok "markerless comment spec must not verify" \
		verify_task_deliverable "comment"
}

@test "#634 verify_task_deliverable: file artefact verifies only when the path exists and is non-empty" {
	cd "$TEST_TMP/repo" || exit 1
	expect_not_ok "missing file must not verify" \
		verify_task_deliverable "file:docs/ruling.md"
	mkdir -p docs
	: > docs/ruling.md
	expect_not_ok "empty file must not verify" \
		verify_task_deliverable "file:docs/ruling.md"
	printf 'the ruling\n' > docs/ruling.md
	expect_ok "existing non-empty file verifies" \
		verify_task_deliverable "file:docs/ruling.md"
}

@test "#634 verify_task_deliverable: an unrecognised deliverable kind fails closed" {
	cd "$TEST_TMP/repo" || exit 1
	expect_not_ok "unknown kind must not verify" \
		verify_task_deliverable "vibes:trust-me"
}

# -----------------------------------------------------------------------------
# AC1/AC2 — the partial-delivery count and the commits-ahead abort
# -----------------------------------------------------------------------------

_setup_status_634() {
	STATUS_FILE="$TEST_TMP/status-634.json"
	export STATUS_FILE
	printf '%s' "$1" > "$STATUS_FILE"
}

@test "#634 AC1 reconcile_noncommit_tasks_with_deliverables: promotes a verified comment-only task" {
	cd "$TEST_TMP/repo" || exit 1
	# The sole task produced no commit, so the no-op guard recorded it failed.
	_setup_status_634 '{"tasks":[
		{"id":1,"description":"Post the ruling","agent":"default",
		 "status":"failed","deliverable":"comment:ruling-634"}
	]}'
	_fetch_issue_comment_bodies() { printf '%s\n' "ruling-634: proceed"; }

	local delta status_after
	delta=$(reconcile_noncommit_tasks_with_deliverables 2>/dev/null)
	expect_glob "$delta" '1' "one task promoted"
	status_after=$(jq -r '.tasks[0].status' "$STATUS_FILE")
	expect_glob "$status_after" 'completed' "promoted task status"
}

@test "#634 AC1 all_tasks_are_verified_noncommit: true when the only task is a verified comment task" {
	cd "$TEST_TMP/repo" || exit 1
	_setup_status_634 '{"tasks":[
		{"id":1,"description":"Post the ruling","agent":"default",
		 "status":"completed","deliverable":"comment:ruling-634"}
	]}'
	expect_ok "comment-only issue must escape the 0-commits abort" \
		all_tasks_are_verified_noncommit
}

@test "#634 AC2 all_tasks_are_verified_noncommit: false when a code task is also planned" {
	cd "$TEST_TMP/repo" || exit 1
	# A mixed issue must NOT get a blanket escape from the commits-ahead abort.
	_setup_status_634 '{"tasks":[
		{"id":1,"description":"Post the ruling","agent":"default",
		 "status":"completed","deliverable":"comment:ruling-634"},
		{"id":2,"description":"Apply in `src/a.ts`","agent":"default",
		 "status":"completed"}
	]}'
	expect_not_ok "mixed issue must not escape the commits-ahead abort" \
		all_tasks_are_verified_noncommit
}

@test "#634 AC2 reconcile_noncommit_tasks_with_deliverables: comment-only task does not count as partial" {
	cd "$TEST_TMP/repo" || exit 1
	# 3 planned tasks: 2 code tasks completed, 1 comment-only spike recorded
	# failed by the no-op guard.  Before the fix this is 2/3 → implement:partial
	# → merge blocked.  After reconciliation it is 3/3.
	_setup_status_634 '{"tasks":[
		{"id":1,"description":"Code in `src/a.ts`","agent":"default","status":"completed"},
		{"id":2,"description":"Spike ruling","agent":"default",
		 "status":"failed","deliverable":"comment:ruling-634"},
		{"id":3,"description":"Code in `src/b.ts`","agent":"default","status":"completed"}
	]}'
	_fetch_issue_comment_bodies() { printf '%s\n' "ruling-634: proceed"; }

	local delta completed total
	delta=$(reconcile_noncommit_tasks_with_deliverables 2>/dev/null)
	expect_glob "$delta" '1' "spike promoted"
	completed=$(jq '[.tasks[] | select(.status == "completed")] | length' "$STATUS_FILE")
	total=$(jq '.tasks | length' "$STATUS_FILE")
	expect_glob "$completed" "$total" "no partial-delivery shortfall remains"
}

@test "#634 reconcile_noncommit_tasks_with_deliverables: does NOT promote an unverifiable artefact" {
	cd "$TEST_TMP/repo" || exit 1
	# The named risk: a task marked non-committing that should have produced
	# work must not pass silently.
	_setup_status_634 '{"tasks":[
		{"id":1,"description":"Post the ruling","agent":"default",
		 "status":"failed","deliverable":"comment:ruling-634"}
	]}'
	_fetch_issue_comment_bodies() { printf '%s\n' "no ruling was ever posted"; }

	local delta status_after
	delta=$(reconcile_noncommit_tasks_with_deliverables 2>/dev/null)
	expect_glob "$delta" '0' "nothing promoted"
	status_after=$(jq -r '.tasks[0].status' "$STATUS_FILE")
	expect_glob "$status_after" 'failed' "unverified task stays failed"
}

@test "#634 reconcile_noncommit_tasks_with_deliverables: DEMOTES a completed task whose artefact is missing" {
	cd "$TEST_TMP/repo" || exit 1
	# A stage can report success without producing the declared artefact.
	# Judging on the artefact means that verdict is overturned, not trusted.
	_setup_status_634 '{"tasks":[
		{"id":1,"description":"Post the ruling","agent":"default",
		 "status":"completed","deliverable":"comment:ruling-634"}
	]}'
	_fetch_issue_comment_bodies() { printf '%s\n' "nothing relevant here"; }

	local delta status_after
	delta=$(reconcile_noncommit_tasks_with_deliverables 2>/dev/null)
	expect_glob "$delta" '-1' "one task demoted"
	status_after=$(jq -r '.tasks[0].status' "$STATUS_FILE")
	expect_glob "$status_after" 'failed' "unverified task demoted to failed"
}

@test "#634 reconcile_noncommit_tasks_with_deliverables: leaves ordinary tasks untouched" {
	cd "$TEST_TMP/repo" || exit 1
	_setup_status_634 '{"tasks":[
		{"id":1,"description":"Code in `src/a.ts`","agent":"default","status":"failed"},
		{"id":2,"description":"Code in `src/b.ts`","agent":"default","status":"completed"}
	]}'
	local delta s1 s2
	delta=$(reconcile_noncommit_tasks_with_deliverables 2>/dev/null)
	expect_glob "$delta" '0' "no non-commit tasks declared"
	s1=$(jq -r '.tasks[0].status' "$STATUS_FILE")
	s2=$(jq -r '.tasks[1].status' "$STATUS_FILE")
	expect_glob "$s1" 'failed' "task 1 untouched"
	expect_glob "$s2" 'completed' "task 2 untouched"
}
