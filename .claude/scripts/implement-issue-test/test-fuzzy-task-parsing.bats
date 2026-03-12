#!/usr/bin/env bats
#
# test-fuzzy-task-parsing.bats
# Unit tests for _parse_task_lines() fuzzy parsing patterns.
#
# Cases covered:
#   Well-formed task lines:
#     1. standard checkbox format parses correctly
#     2. plain bullet (no checkbox) parses correctly
#     3. checked boxes [x] are skipped
#
#   Fuzzy / malformed task lines (parsed with warnings):
#     4. missing backticks around agent name
#     5. extra leading whitespace before bullet
#     6. asterisk bullet instead of dash
#     7. missing square brackets around agent name (backticks present)
#
#   Graceful failure:
#     8. completely unparseable content returns zero tasks
#     9. empty input returns zero tasks
#    10. mix of valid and unparseable lines parses valid ones
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env

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
# Well-formed task lines (baseline)
# =============================================================================

@test "_parse_task_lines: standard checkbox format parses correctly" {
	local input='- [ ] `[default]` **(S)** Implement the feature'
	run _parse_task_lines "$input"
	[ "$status" -eq 0 ]
	local count agent desc
	count=$(printf '%s' "$output" | jq 'length')
	agent=$(printf '%s' "$output" | jq -r '.[0].agent')
	desc=$(printf '%s' "$output" | jq -r '.[0].description')
	[ "$count" -eq 1 ]
	[ "$agent" = "default" ]
	[[ "$desc" == *"Implement the feature"* ]]
}

@test "_parse_task_lines: plain bullet without checkbox parses correctly" {
	local input='- `[my-agent]` Do something useful'
	run _parse_task_lines "$input"
	[ "$status" -eq 0 ]
	local count agent
	count=$(printf '%s' "$output" | jq 'length')
	agent=$(printf '%s' "$output" | jq -r '.[0].agent')
	[ "$count" -eq 1 ]
	[ "$agent" = "my-agent" ]
}

@test "_parse_task_lines: checked boxes are skipped" {
	local input='- [x] `[default]` Already done task'
	run _parse_task_lines "$input"
	[ "$status" -eq 0 ]
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[ "$count" -eq 0 ]
}

# =============================================================================
# Fuzzy / malformed task lines (parsed with warnings on stderr)
# =============================================================================

@test "_parse_task_lines: missing backticks around agent name parses with warning" {
	local input='- [ ] [default] **(S)** Implement without backticks'
	local result stderr_file
	stderr_file="$TEST_TMP/stderr.txt"
	result=$(_parse_task_lines "$input" 2>"$stderr_file")
	local count agent
	count=$(printf '%s' "$result" | jq 'length')
	agent=$(printf '%s' "$result" | jq -r '.[0].agent')
	[ "$count" -eq 1 ]
	[ "$agent" = "default" ]
	# Should have emitted a warning on stderr
	grep -qi "warning\|fuzzy" "$stderr_file"
}

@test "_parse_task_lines: extra leading whitespace parses with warning" {
	local input='  - [ ] `[default]` **(S)** Indented task line'
	local result stderr_file
	stderr_file="$TEST_TMP/stderr.txt"
	result=$(_parse_task_lines "$input" 2>"$stderr_file")
	local count agent
	count=$(printf '%s' "$result" | jq 'length')
	agent=$(printf '%s' "$result" | jq -r '.[0].agent')
	[ "$count" -eq 1 ]
	[ "$agent" = "default" ]
	grep -qi "warning\|fuzzy" "$stderr_file"
}

@test "_parse_task_lines: asterisk bullet instead of dash parses with warning" {
	local input='* [ ] `[default]` **(M)** Use star bullet'
	local result stderr_file
	stderr_file="$TEST_TMP/stderr.txt"
	result=$(_parse_task_lines "$input" 2>"$stderr_file")
	local count agent
	count=$(printf '%s' "$result" | jq 'length')
	agent=$(printf '%s' "$result" | jq -r '.[0].agent')
	[ "$count" -eq 1 ]
	[ "$agent" = "default" ]
	grep -qi "warning\|fuzzy" "$stderr_file"
}

@test "_parse_task_lines: missing brackets around agent name with backticks parses with warning" {
	local input='- [ ] `default` **(S)** Agent without square brackets'
	local result stderr_file
	stderr_file="$TEST_TMP/stderr.txt"
	result=$(_parse_task_lines "$input" 2>"$stderr_file")
	local count agent
	count=$(printf '%s' "$result" | jq 'length')
	agent=$(printf '%s' "$result" | jq -r '.[0].agent')
	[ "$count" -eq 1 ]
	[ "$agent" = "default" ]
	grep -qi "warning\|fuzzy" "$stderr_file"
}

# =============================================================================
# Graceful failure
# =============================================================================

@test "_parse_task_lines: completely unparseable content returns zero tasks" {
	local input='This is just some random text.
No task lines here at all.
Just paragraphs of content.'
	run _parse_task_lines "$input"
	[ "$status" -eq 0 ]
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[ "$count" -eq 0 ]
}

@test "_parse_task_lines: empty input returns zero tasks" {
	run _parse_task_lines ""
	[ "$status" -eq 0 ]
	local count
	count=$(printf '%s' "$output" | jq 'length')
	[ "$count" -eq 0 ]
}

@test "_parse_task_lines: mix of valid and unparseable lines parses only valid ones" {
	local input='Some header text
- [ ] `[default]` **(S)** Valid task one
This line is not a task
- [ ] `[custom-agent]` **(M)** Valid task two
Another random line'
	run _parse_task_lines "$input"
	[ "$status" -eq 0 ]
	local count a1 a2
	count=$(printf '%s' "$output" | jq 'length')
	a1=$(printf '%s' "$output" | jq -r '.[0].agent')
	a2=$(printf '%s' "$output" | jq -r '.[1].agent')
	[ "$count" -eq 2 ]
	[ "$a1" = "default" ]
	[ "$a2" = "custom-agent" ]
}

@test "_parse_task_lines: multiple tasks get sequential IDs" {
	local input='- [ ] `[alpha]` First task
- [ ] `[beta]` Second task
- [ ] `[gamma]` Third task'
	run _parse_task_lines "$input"
	[ "$status" -eq 0 ]
	local id1 id2 id3
	id1=$(printf '%s' "$output" | jq '.[0].id')
	id2=$(printf '%s' "$output" | jq '.[1].id')
	id3=$(printf '%s' "$output" | jq '.[2].id')
	[ "$id1" -eq 1 ]
	[ "$id2" -eq 2 ]
	[ "$id3" -eq 3 ]
}

@test "_parse_task_lines: escaped backticks are unescaped before parsing" {
	local input='- [ ] \`[default]\` **(S)** Task with escaped backticks'
	run _parse_task_lines "$input"
	[ "$status" -eq 0 ]
	local count agent
	count=$(printf '%s' "$output" | jq 'length')
	agent=$(printf '%s' "$output" | jq -r '.[0].agent')
	[ "$count" -eq 1 ]
	[ "$agent" = "default" ]
}

# =============================================================================
# COMPLEXITY DEFAULT ASSERTION (issue #90)
# =============================================================================

@test "complexity defaults to M when no hint is present" {
	local input='- [ ] `[default]` Wire fast-path flag'
	local result
	result=$(_parse_task_lines "$input")

	local desc
	desc=$(printf '%s' "$result" | jq -r '.[0].description')

	[[ "$desc" == "**(M)** Wire fast-path flag" ]]
}

@test "explicit complexity hint S is preserved" {
	local input='- [ ] `[default]` **(S)** Fix typo in readme'
	local result
	result=$(_parse_task_lines "$input")

	local desc
	desc=$(printf '%s' "$result" | jq -r '.[0].description')

	[[ "$desc" == "**(S)** Fix typo in readme" ]]
}

@test "explicit complexity hint L is preserved" {
	local input='- [ ] `[default]` **(L)** Refactor authentication module'
	local result
	result=$(_parse_task_lines "$input")

	local desc
	desc=$(printf '%s' "$result" | jq -r '.[0].description')

	[[ "$desc" == "**(L)** Refactor authentication module" ]]
}

@test "explicit complexity hint M is not doubled" {
	local input='- [ ] `[default]` **(M)** Add validation layer'
	local result
	result=$(_parse_task_lines "$input")

	local desc
	desc=$(printf '%s' "$result" | jq -r '.[0].description')

	[[ "$desc" == "**(M)** Add validation layer" ]]
}
