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

# =============================================================================
# Case 6: synthesised body gains a stub Acceptance Criteria section
# =============================================================================
# NOTE: this bats setup only fails the test on the LAST command's status, so
# each assertion below is guarded with an explicit `|| return 1` to fail loudly.

@test "_build_adj_body: synthesised body includes Acceptance Criteria section" {
	local body="Just a description with no tasks section."
	run _build_adj_body "$body" "Add retry logic"
	[ "$status" -eq 0 ] || return 1
	# AC heading is appended
	[[ "$output" == *'## Acceptance Criteria'* ]] || return 1
	# At least one stub criterion checkbox is present
	[[ "$output" == *'- [ ]'* ]] || return 1
	# Criteria are derived from the title
	[[ "$output" == *'Add retry logic'* ]] || return 1
}

@test "_build_adj_body: empty body synthesises both sections with criteria" {
	run _build_adj_body "" "Create the widget"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *'## Implementation Tasks'* ]] || return 1
	[[ "$output" == *'## Acceptance Criteria'* ]] || return 1
	[[ "$output" == *'Create the widget'* ]] || return 1
	# Implementation Tasks must come before Acceptance Criteria
	local tasks_line ac_line
	tasks_line=$(printf '%s\n' "$output" | grep -n '## Implementation Tasks' | head -1 | cut -d: -f1)
	ac_line=$(printf '%s\n' "$output" | grep -n '## Acceptance Criteria' | head -1 | cut -d: -f1)
	[[ -n "$tasks_line" && -n "$ac_line" ]] || return 1
	[ "$tasks_line" -lt "$ac_line" ]
}

# =============================================================================
# Case 7: pass-through (valid task) does NOT gain an Acceptance Criteria stub
# =============================================================================

@test "_build_adj_body: valid task body is not given a synthesised AC section" {
	local body
	body=$(printf 'Fix the bug.\n\n## Implementation Tasks\n\n- [ ] `[default]` **(M)** Patch the handler\n')
	run _build_adj_body "$body" "Fix the bug"
	[ "$status" -eq 0 ] || return 1
	# Body had no AC section and is returned unchanged — none added
	[[ "$output" != *'## Acceptance Criteria'* ]]
}

# =============================================================================
# Case 8: existing Acceptance Criteria section is not duplicated
# =============================================================================

@test "_build_adj_body: existing AC section is preserved, not duplicated" {
	local body
	body=$(printf 'Context.\n\n## Acceptance Criteria\n\n- [ ] Custom criterion\n\n## Implementation Tasks\n\nprose only\n')
	run _build_adj_body "$body" "Improve the feature"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *'Custom criterion'* ]] || return 1
	# Only one Acceptance Criteria heading must exist
	local ac_count
	ac_count=$(printf '%s' "$output" | grep -c '## Acceptance Criteria' || true)
	[ "$ac_count" -eq 1 ]
}
