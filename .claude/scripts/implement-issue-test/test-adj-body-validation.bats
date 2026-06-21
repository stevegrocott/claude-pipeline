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

bats_require_minimum_version 1.5.0

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

	# source_orchestrator_functions() sources the extracted func_file from
	# TEST_TMP, which causes the embedded SCRIPT_DIR= line to evaluate
	# BASH_SOURCE[0] as TEST_TMP/orchestrator_functions.bash — pointing
	# SCRIPT_DIR at TEST_TMP instead of the real .claude/scripts directory.
	# Restore it so _normalize_agent_name() can resolve agent .md files.
	# TEST_DIR (from test-helper.bash) is the implement-issue-test directory;
	# its parent is the real .claude/scripts directory.
	SCRIPT_DIR="${TEST_DIR}/.."
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

# =============================================================================
# Case 9: synthesised task carries a path suffix when body references a file
# =============================================================================

@test "_build_adj_body: synthesised task has path suffix when body references a file" {
	local body
	body=$(printf 'Fix the handler.\n\nSee \`src/handlers/auth.sh\` for context.\n')
	run _build_adj_body "$body" "Fix auth handler"
	[ "$status" -eq 0 ] || return 1
	# Task line must carry the path suffix
	[[ "$output" == *'— `src/handlers/auth.sh`'* ]] || return 1
	# Title must also appear in the task description
	[[ "$output" == *'Fix auth handler'* ]] || return 1
}

@test "_build_adj_body: synthesised task has no path suffix when body has no file reference" {
	local body="Just a plain description with no file references."
	run _build_adj_body "$body" "Add retry logic"
	[ "$status" -eq 0 ] || return 1
	# No fabricated path suffix (the em-dash + backtick pattern)
	[[ "$output" != *'— `'* ]] || return 1
	# Standard task line is still present
	[[ "$output" == *'Add retry logic'* ]] || return 1
}

# =============================================================================
# Case 10: _infer_agent_from_path extension→agent mapping
# =============================================================================

@test "_infer_agent_from_path: .sh maps to bash-script-craftsman" {
	run _infer_agent_from_path "scripts/deploy.sh"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "bash-script-craftsman" ]
}

@test "_infer_agent_from_path: .bats maps to bash-script-craftsman" {
	run _infer_agent_from_path "test/unit/feature.bats"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "bash-script-craftsman" ]
}

@test "_infer_agent_from_path: empty path returns default" {
	run _infer_agent_from_path ""
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "default" ]
}

@test "_infer_agent_from_path: unknown extension returns default" {
	run _infer_agent_from_path "readme.pdf"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "default" ]
}

@test "_infer_agent_from_path: JS/TS with no FRONTEND_PATH_PATTERNS returns default" {
	unset FRONTEND_PATH_PATTERNS
	run _infer_agent_from_path "src/app.ts"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "default" ]
}

@test "_infer_agent_from_path: .ts matching FRONTEND_PATH_PATTERNS maps to react-frontend-developer" {
	export FRONTEND_PATH_PATTERNS="src/components/*|src/pages/*"
	run _infer_agent_from_path "src/components/Button.tsx"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "react-frontend-developer" ]
}

@test "_infer_agent_from_path: .ts not matching FRONTEND_PATH_PATTERNS maps to fastify-backend-developer" {
	export FRONTEND_PATH_PATTERNS="src/components/*|src/pages/*"
	run _infer_agent_from_path "src/services/user.ts"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "fastify-backend-developer" ]
}

@test "_infer_agent_from_path: unknown extension returns default via case fallback" {
	run _infer_agent_from_path "some/config.nonexistent"
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "default" ]
}

@test "_infer_agent_from_path: absent agent .md file falls back to default" {
	# _normalize_agent_name() checks ${SCRIPT_DIR}/../agents/<name>.md.
	# Build a mock root: mock_root/scripts (SCRIPT_DIR) + mock_root/agents
	# (empty — no bash-script-craftsman.md).  With .sh inferring
	# bash-script-craftsman but no .md present, fallback must be "default".
	# Use --separate-stderr so that log_warn's diagnostic (stderr) does not
	# contaminate $output (stdout-only agent name returned by the function).
	local mock_root
	mock_root="$TEST_TMP/mock_root"
	mkdir -p "$mock_root/scripts" "$mock_root/agents"
	SCRIPT_DIR="$mock_root/scripts"
	run --separate-stderr _infer_agent_from_path "scripts/deploy.sh"
	SCRIPT_DIR="${TEST_DIR}/.."
	[ "$status" -eq 0 ] || return 1
	[ "$output" = "default" ]
}

# =============================================================================
# Case 11: synthesised task uses inferred agent from file path
# =============================================================================

@test "_build_adj_body: synthesised task uses bash-script-craftsman for .sh file in title" {
	local body="No tasks here."
	run _build_adj_body "$body" "Fix deploy.sh script"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *'`[bash-script-craftsman]`'* ]] || return 1
}

# =============================================================================
# Case 12: measurable ACs reference path when file is recoverable
# =============================================================================

@test "_build_adj_body: synthesised ACs reference file path when file is recoverable" {
	local body
	body=$(printf 'Update the handler.\n\nSee \`src/api/handler.sh\`.\n')
	run _build_adj_body "$body" "Fix handler"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *'## Acceptance Criteria'* ]] || return 1
	# ACs must reference the concrete file, not generic boilerplate
	[[ "$output" == *'src/api/handler.sh'* ]] || return 1
	# Generic boilerplate must not appear
	[[ "$output" != *'is implemented'$'\n'* ]] || return 1
}

@test "_build_adj_body: synthesised ACs are non-generic when no file is recoverable" {
	local body="A plain description with no file references."
	run _build_adj_body "$body" "Add logging"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *'## Acceptance Criteria'* ]] || return 1
	# Must not contain the exact generic boilerplate from the old synthesis
	[[ "$output" != *'Add logging is implemented'$'\n'* ]] || return 1
	[[ "$output" != *'Change is verified by tests'* ]] || return 1
}
