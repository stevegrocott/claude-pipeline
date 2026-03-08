#!/usr/bin/env bats
#
# test-task-batching.bats
# Unit tests for _extract_task_files_from_desc() and compute_task_batches().
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
