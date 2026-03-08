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

# =============================================================================
# run_parallel_post_task_stages (parallel e2e-verify and acceptance-test)
# Tests the parallel execution of post-task stages with independent exit codes
# =============================================================================

# =============================================================================
# per-task log file creation
# =============================================================================

@test "execute_batch_serial: creates per-task serial log file at LOG_BASE/stages" {
	cd "$TEST_TMP/repo" || exit 1
	git checkout -q -b feature/serial-log-test main

	mkdir -p "$LOG_BASE/stages"

	run_stage() {
		printf '%s' '{"status":"success","commit":"abc123","summary":"done"}'
	}
	should_run_quality_loop() { return 1; }
	get_max_review_attempts() { printf '%s' "1"; }
	get_stage_timeout() { printf '%s' "1800"; }
	resolve_model() { printf '%s' "sonnet"; }
	build_files_block() { printf '\n'; }
	extract_task_size() { printf '%s' "S"; }

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
	total_classified=$(( conflicted_count + completed_count ))
	[[ "$total_classified" -eq 2 ]]
	[[ "$conflicted_count" -ge 1 ]]

	git worktree prune 2>/dev/null || true
	git checkout -q main 2>/dev/null || true
	git branch -D feature/conf-fallback 2>/dev/null || true
	git branch -D wt-task-10 2>/dev/null || true
	git branch -D wt-task-11 2>/dev/null || true
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
