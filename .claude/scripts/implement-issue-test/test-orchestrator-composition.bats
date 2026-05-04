#!/usr/bin/env bats
#
# test-orchestrator-composition.bats
# Tests for composition routing: Skill-tool vs subprocess dispatch
#
# This file covers the composition backend added by issue #179:
# skills that orchestrate (decision-making, planning, routing) call
# sub-skills via the Skill tool; skills that delegate (worktree-isolated
# work, parallel fanout) keep subprocess invocation.
#
# Cases covered:
#
#   (a) Skill-tool path — non-isolated cases:
#     1. dispatch_composition with isolated=false routes to skill path by default
#     2. Skill path does NOT invoke the claude subprocess
#     3. dispatch_composition with no second arg defaults to skill path
#
#   (b) Subprocess path — worktree/isolated cases:
#     1. dispatch_composition with isolated=true routes to subprocess by default
#     2. Subprocess path invokes run_composition_subprocess
#     3. batch-runner.sh implement-issue call is still a subprocess invocation
#        (worktree isolation is the point)
#
#   (c) Kill-switch — COMPOSITION_BACKEND env var overrides routing:
#     1. COMPOSITION_BACKEND=subprocess forces subprocess even when isolated=false
#     2. COMPOSITION_BACKEND=skill forces skill path even when isolated=true
#     3. Unknown COMPOSITION_BACKEND value exits non-zero with an error message
#     4. Unset COMPOSITION_BACKEND leaves auto-routing in effect
#

load 'helpers/test-helper.bash'

# =============================================================================
# LOCAL STATE
# =============================================================================

BATCH_ORCHESTRATOR_SCRIPT=""
BATCH_RUNNER_SCRIPT=""

# Set to "true" once dispatch_composition() is sourced successfully.
# Unit tests skip when this is "false" (function not yet implemented).
DISPATCH_AVAILABLE="false"

# =============================================================================
# HELPER: source dispatch_composition from batch-orchestrator.sh
# =============================================================================

# Extract and source the dispatch_composition family of functions from
# batch-orchestrator.sh.  Mirrors the source_batch_emit_event() pattern in
# test-batch-events.bats, scoped to the composition functions.
#
# Returns 0 and sets DISPATCH_AVAILABLE=true on success.
# Returns 1 (without aborting) when the function is not yet in the script.
source_batch_dispatch_composition() {
	local func_file="$TEST_TMP/batch_dispatch_composition.bash"

	# Extract all three related function definitions using awk.
	awk '
		/^dispatch_composition\(\) \{$/,/^\}$/        { print; next }
		/^run_composition_subprocess\(\) \{$/,/^\}$/  { print; next }
		/^run_composition_skill\(\) \{$/,/^\}$/       { print; next }
	' "$BATCH_ORCHESTRATOR_SCRIPT" > "$func_file"

	if ! grep -q "dispatch_composition()" "$func_file" 2>/dev/null; then
		printf 'NOTE: dispatch_composition() not yet in %s — unit tests will skip\n' \
			"$BATCH_ORCHESTRATOR_SCRIPT" >&2
		DISPATCH_AVAILABLE="false"
		return 1
	fi

	# shellcheck disable=SC1090
	source "$func_file"
	DISPATCH_AVAILABLE="true"
	return 0
}

# Install call-tracking mocks for run_composition_subprocess and
# run_composition_skill.  Each mock writes the supplied prompt to a
# sentinel file so tests can assert which path was taken.
#
# After calling, check:
#   "$TEST_TMP/subprocess_called"  — exists iff subprocess path was taken
#   "$TEST_TMP/skill_called"       — exists iff skill path was taken
#   "$TEST_TMP/subprocess_prompt"  — prompt passed to subprocess path
#   "$TEST_TMP/skill_prompt"       — prompt passed to skill path
install_composition_mocks() {
	run_composition_subprocess() {
		printf '%s' "$1" > "$TEST_TMP/subprocess_prompt"
		touch "$TEST_TMP/subprocess_called"
		return 0
	}
	export -f run_composition_subprocess

	run_composition_skill() {
		printf '%s' "$1" > "$TEST_TMP/skill_prompt"
		touch "$TEST_TMP/skill_called"
		return 0
	}
	export -f run_composition_skill
}

# Skip the current test when dispatch_composition() has not yet been merged.
# Usage: require_dispatch_composition
require_dispatch_composition() {
	if [[ "$DISPATCH_AVAILABLE" != "true" ]]; then
		skip "dispatch_composition() not yet implemented (TDD)"
	fi
}

# =============================================================================
# SETUP / TEARDOWN
# =============================================================================

setup() {
	setup_test_env

	# SCRIPT_DIR is set by test-helper.bash to .claude/scripts/
	BATCH_ORCHESTRATOR_SCRIPT="$SCRIPT_DIR/batch-orchestrator.sh"
	BATCH_RUNNER_SCRIPT="$SCRIPT_DIR/batch-runner.sh"

	export LOG_BASE="$TEST_TMP/logs/batch-20240101-100000"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	mkdir -p "$LOG_BASE"

	# Clear any inherited kill-switch so tests start with auto-routing.
	unset COMPOSITION_BACKEND

	# Try to source dispatch_composition — soft failure if not implemented yet.
	source_batch_dispatch_composition || true
	install_composition_mocks
}

teardown() {
	teardown_test_env
}

# =============================================================================
# (a) SKILL-TOOL PATH — non-isolated cases
# =============================================================================

@test "(a) dispatch_composition isolated=false routes to skill path by default" {
	require_dispatch_composition

	dispatch_composition "/process-pr 123 456 main" "false"

	[ -f "$TEST_TMP/skill_called" ]
}

@test "(a) dispatch_composition isolated=false does NOT invoke subprocess" {
	require_dispatch_composition

	dispatch_composition "/process-pr 123 456 main" "false"

	[ ! -f "$TEST_TMP/subprocess_called" ]
}

@test "(a) skill path receives the prompt unchanged" {
	require_dispatch_composition

	dispatch_composition "/process-pr 99 77 feature" "false"

	[ -f "$TEST_TMP/skill_prompt" ]
	local actual
	actual=$(< "$TEST_TMP/skill_prompt")
	[[ "$actual" == "/process-pr 99 77 feature" ]]
}

@test "(a) dispatch_composition with no isolated arg defaults to skill path" {
	require_dispatch_composition

	# Omitting the second arg should behave the same as isolated=false.
	dispatch_composition "/process-pr 1 2 main"

	[ -f "$TEST_TMP/skill_called" ]
	[ ! -f "$TEST_TMP/subprocess_called" ]
}

@test "(a) dispatch_composition exits 0 on skill path" {
	require_dispatch_composition

	run dispatch_composition "/process-pr 1 2 main" "false"

	[ "$status" -eq 0 ]
}

# =============================================================================
# (b) SUBPROCESS PATH — worktree/isolated cases
# =============================================================================

@test "(b) dispatch_composition isolated=true routes to subprocess by default" {
	require_dispatch_composition

	dispatch_composition "/implement-issue 123 main" "true"

	[ -f "$TEST_TMP/subprocess_called" ]
}

@test "(b) dispatch_composition isolated=true does NOT invoke skill path" {
	require_dispatch_composition

	dispatch_composition "/implement-issue 123 main" "true"

	[ ! -f "$TEST_TMP/skill_called" ]
}

@test "(b) subprocess path receives the prompt unchanged" {
	require_dispatch_composition

	dispatch_composition "/implement-issue 456 feature" "true"

	[ -f "$TEST_TMP/subprocess_prompt" ]
	local actual
	actual=$(< "$TEST_TMP/subprocess_prompt")
	[[ "$actual" == "/implement-issue 456 feature" ]]
}

@test "(b) dispatch_composition exits 0 on subprocess path" {
	require_dispatch_composition

	run dispatch_composition "/implement-issue 123 main" "true"

	[ "$status" -eq 0 ]
}

@test "(b) batch-runner.sh implement-issue call is still a subprocess invocation" {
	# Structural test: the implement-issue invocation in batch-runner.sh must
	# remain a subprocess call — worktree isolation is the point.
	# This test does NOT require dispatch_composition() to be implemented.
	[ -f "$BATCH_RUNNER_SCRIPT" ] \
		|| { printf 'SKIP: batch-runner.sh not found at %s\n' \
			"$BATCH_RUNNER_SCRIPT" >&2; skip; }

	# Accept any line where claude -p and implement-issue appear together
	# (may be inline or wrapped in an if/timeout/env chain).
	local pattern
	pattern='claude[[:space:]].*-p.*implement-issue'
	grep -qE "$pattern" "$BATCH_RUNNER_SCRIPT"
}

# =============================================================================
# (c) KILL-SWITCH — COMPOSITION_BACKEND env var overrides
# =============================================================================

@test "(c) COMPOSITION_BACKEND=subprocess forces subprocess even when isolated=false" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="subprocess"

	dispatch_composition "/process-pr 123 456 main" "false"

	[ -f "$TEST_TMP/subprocess_called" ]
	[ ! -f "$TEST_TMP/skill_called" ]
}

@test "(c) COMPOSITION_BACKEND=subprocess prompt is passed to subprocess path" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="subprocess"

	dispatch_composition "/process-pr 7 8 main" "false"

	local actual
	actual=$(< "$TEST_TMP/subprocess_prompt")
	[[ "$actual" == "/process-pr 7 8 main" ]]
}

@test "(c) COMPOSITION_BACKEND=skill forces skill path even when isolated=true" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="skill"

	dispatch_composition "/implement-issue 123 main" "true"

	[ -f "$TEST_TMP/skill_called" ]
	[ ! -f "$TEST_TMP/subprocess_called" ]
}

@test "(c) COMPOSITION_BACKEND=skill prompt is passed to skill path" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="skill"

	dispatch_composition "/implement-issue 9 feature" "true"

	local actual
	actual=$(< "$TEST_TMP/skill_prompt")
	[[ "$actual" == "/implement-issue 9 feature" ]]
}

@test "(c) unknown COMPOSITION_BACKEND value exits non-zero" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="invalid-backend"

	run dispatch_composition "/process-pr 1 2 main" "false"

	[ "$status" -ne 0 ]
}

@test "(c) unknown COMPOSITION_BACKEND error message names the bad value" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="bogus"

	run dispatch_composition "/process-pr 1 2 main" "false" 2>&1

	[[ "$output" == *"bogus"* ]]
}

@test "(c) unset COMPOSITION_BACKEND leaves auto-routing in effect for skill path" {
	require_dispatch_composition
	unset COMPOSITION_BACKEND

	dispatch_composition "/process-pr 1 2 main" "false"

	# Auto-routing: non-isolated → skill
	[ -f "$TEST_TMP/skill_called" ]
	[ ! -f "$TEST_TMP/subprocess_called" ]
}

@test "(c) unset COMPOSITION_BACKEND leaves auto-routing in effect for subprocess path" {
	require_dispatch_composition
	unset COMPOSITION_BACKEND

	dispatch_composition "/implement-issue 123 main" "true"

	# Auto-routing: isolated → subprocess
	[ -f "$TEST_TMP/subprocess_called" ]
	[ ! -f "$TEST_TMP/skill_called" ]
}

@test "(c) COMPOSITION_BACKEND=subprocess exits 0" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="subprocess"

	run dispatch_composition "/process-pr 1 2 main" "false"

	[ "$status" -eq 0 ]
}

@test "(c) COMPOSITION_BACKEND=skill exits 0" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="skill"

	run dispatch_composition "/implement-issue 123 main" "true"

	[ "$status" -eq 0 ]
}
