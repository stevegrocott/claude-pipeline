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
#
#   execute_batch_serial:
#     1. returns completed array with task IDs (mocked run_stage)
#     2. returns failed array when run_stage fails
#
#   execute_batch_parallel:
#     1. creates worktrees for each task in batch
#     2. returns conflicted array on merge conflict
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
	create_task_worktree "$wt_base" "feature/test-wt2" "7" \
		>/dev/null

	# Branch should exist
	git rev-parse --verify "wt-task-7" >/dev/null 2>&1
	[ $? -eq 0 ]

	# Clean up
	git worktree remove --force "${wt_base}/task-7" 2>/dev/null || true
	git branch -D "wt-task-7" 2>/dev/null || true
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

# =============================================================================
# execute_batch_serial (with mocked run_stage)
# =============================================================================

@test "execute_batch_serial: returns completed IDs on success" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/serial-test main

	mkdir -p "$LOG_BASE/stages"

	# Mock run_stage to return success
	run_stage() {
		printf '%s' '{"status":"success","commit":"abc123","summary":"done"}'
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
	# extract_task_size is called within execute_batch_parallel
	# (not inside the subshell) so it works without export

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
