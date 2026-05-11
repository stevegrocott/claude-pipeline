#!/usr/bin/env bats
#
# test-adj-body-validation.bats
# Unit tests for _build_adj_body() — validates and synthesises the
# Implementation Tasks section for adjacent follow-up issues.
#
# Cases covered:
#   1. Body with valid canonical task line → returned unchanged
#   2. Body with Implementation Tasks section containing only prose → section
#      stripped, canonical line appended
#   3. Body with no Implementation Tasks section at all → canonical line appended
#   4. Empty body string → synthesised section only
#   5. Optional checkbox ([ ]) in task line regex is matched (bracket is optional)
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env

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
# Case 1: body already has a valid canonical task line → pass through unchanged
# =============================================================================

@test "_build_adj_body: valid canonical task line returns body unchanged" {
	local body
	body=$(printf 'Fix the bug.\n\n## Implementation Tasks\n\n- [ ] `[default]` **(M)** Patch the handler\n')
	run _build_adj_body "$body" "Fix the bug"
	[ "$status" -eq 0 ]
	[[ "$output" == *'`[default]`'* ]]
	[[ "$output" == *'Patch the handler'* ]]
	# Original body prefix must be present
	[[ "$output" == *'Fix the bug.'* ]]
}

# =============================================================================
# Case 2: Implementation Tasks section exists but contains only prose
# =============================================================================

@test "_build_adj_body: prose-only tasks section is stripped and canonical line appended" {
	local body
	body=$(printf 'Context here.\n\n## Implementation Tasks\n\nTask 1: do something\nTask 2: do another thing\n')
	run _build_adj_body "$body" "Improve the feature"
	[ "$status" -eq 0 ]
	# Prose lines must NOT appear in output
	[[ "$output" != *'Task 1:'* ]]
	# A synthesised canonical line using [default] must be present
	[[ "$output" == *'`[default]`'* ]]
	[[ "$output" == *'Improve the feature'* ]]
}

# =============================================================================
# Case 3: no Implementation Tasks section at all
# =============================================================================

@test "_build_adj_body: missing Implementation Tasks section gets one appended" {
	local body="Just a description with no tasks section."
	run _build_adj_body "$body" "Add retry logic"
	[ "$status" -eq 0 ]
	[[ "$output" == *'## Implementation Tasks'* ]]
	[[ "$output" == *'`[default]`'* ]]
	[[ "$output" == *'Add retry logic'* ]]
	# Original prose must be preserved before the section
	[[ "$output" == *'Just a description'* ]]
}

# =============================================================================
# Case 4: empty body string
# =============================================================================

@test "_build_adj_body: empty body produces only the synthesised section" {
	run _build_adj_body "" "Create the widget"
	[ "$status" -eq 0 ]
	[[ "$output" == *'## Implementation Tasks'* ]]
	[[ "$output" == *'`[default]`'* ]]
	[[ "$output" == *'Create the widget'* ]]
}

# =============================================================================
# Case 5: optional checkbox — task line without [ ] is still canonical
# =============================================================================

@test "_build_adj_body: canonical task line without checkbox bracket is accepted" {
	local body
	body=$(printf 'Desc.\n\n## Implementation Tasks\n\n- `[my-agent]` **(S)** Do the thing\n')
	run _build_adj_body "$body" "Do the thing"
	[ "$status" -eq 0 ]
	# Should be returned unchanged (valid task detected)
	[[ "$output" == *'`[my-agent]`'* ]]
	[[ "$output" == *'Do the thing'* ]]
	# Must NOT have a second synthesised section
	local section_count
	section_count=$(printf '%s' "$output" | grep -c '## Implementation Tasks' || true)
	[ "$section_count" -eq 1 ]
}
