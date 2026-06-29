#!/usr/bin/env bats
#
# test-orchestrator-composition.bats
# Tests for composition routing: standard vs isolated subprocess dispatch
#
# This file covers the composition backend added by issue #179 and updated
# in issue #199 to remove the misleading "Skill-tool path" terminology.
#
# ARCHITECTURAL CONSTRAINT: bash cannot invoke the Skill tool.
# Both dispatch paths are `claude -p` subprocess calls.  The distinction is
# only in whether --dangerously-skip-permissions is forwarded:
#   - standard (isolated=false): no --dangerously-skip-permissions; for
#     decision/review tasks like process-pr
#   - isolated subprocess (isolated=true): with --dangerously-skip-permissions;
#     for worktree-isolated implementation tasks
#
# Cases covered:
#
#   (a) Standard subprocess path — non-isolated cases:
#     1. dispatch_composition with isolated=false routes to standard path by default
#     2. Standard path does NOT invoke the isolated subprocess
#     3. dispatch_composition with no second arg defaults to standard path
#
#   (b) Isolated subprocess path — worktree/isolated cases:
#     1. dispatch_composition with isolated=true routes to isolated subprocess by default
#     2. Isolated subprocess path invokes run_composition_subprocess
#     3. batch-runner.sh implement-issue call is still an isolated subprocess invocation
#        (worktree isolation is the point)
#
#   (c) Kill-switch — COMPOSITION_BACKEND env var overrides routing:
#     1. COMPOSITION_BACKEND=subprocess forces isolated subprocess even when isolated=false
#     2. COMPOSITION_BACKEND=skill forces standard path even when isolated=true
#        NOTE: "skill" is a legacy value name; it selects run_composition_standard(),
#        not the Skill tool (bash cannot invoke the Skill tool)
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
	# Note: run_composition_skill() was renamed to run_composition_standard()
	# (architectural constraint: bash cannot invoke the Skill tool).
	awk '
		/^dispatch_composition\(\) \{$/,/^\}$/        { print; next }
		/^run_composition_subprocess\(\) \{$/,/^\}$/  { print; next }
		/^run_composition_standard\(\) \{$/,/^\}$/    { print; next }
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
# run_composition_standard.  Each mock writes the supplied prompt to a
# sentinel file so tests can assert which path was taken.
#
# Note: run_composition_skill() was renamed to run_composition_standard()
# because bash cannot invoke the Skill tool — both composition paths are
# plain `claude -p` subprocess calls; the distinction is only in whether
# --dangerously-skip-permissions is forwarded.
#
# After calling, check:
#   "$TEST_TMP/subprocess_called"  — exists iff isolated subprocess path was taken
#   "$TEST_TMP/standard_called"    — exists iff standard subprocess path was taken
#   "$TEST_TMP/subprocess_prompt"  — prompt passed to isolated subprocess path
#   "$TEST_TMP/standard_prompt"    — prompt passed to standard subprocess path
install_composition_mocks() {
	run_composition_subprocess() {
		printf '%s' "$1" > "$TEST_TMP/subprocess_prompt"
		touch "$TEST_TMP/subprocess_called"
		return 0
	}
	export -f run_composition_subprocess

	run_composition_standard() {
		printf '%s' "$1" > "$TEST_TMP/standard_prompt"
		touch "$TEST_TMP/standard_called"
		return 0
	}
	export -f run_composition_standard
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
# (a) STANDARD SUBPROCESS PATH — non-isolated cases
# =============================================================================

@test "(a) dispatch_composition isolated=false routes to standard path by default" {
	require_dispatch_composition

	dispatch_composition "/process-pr 123 456 main" "false"

	[ -f "$TEST_TMP/standard_called" ]
}

@test "(a) dispatch_composition isolated=false does NOT invoke isolated subprocess" {
	require_dispatch_composition

	dispatch_composition "/process-pr 123 456 main" "false"

	[ ! -f "$TEST_TMP/subprocess_called" ]
}

@test "(a) standard path receives the prompt unchanged" {
	require_dispatch_composition

	dispatch_composition "/process-pr 99 77 feature" "false"

	[ -f "$TEST_TMP/standard_prompt" ]
	local actual
	actual=$(< "$TEST_TMP/standard_prompt")
	[[ "$actual" == "/process-pr 99 77 feature" ]]
}

@test "(a) dispatch_composition with no isolated arg defaults to standard path" {
	require_dispatch_composition

	# Omitting the second arg should behave the same as isolated=false.
	dispatch_composition "/process-pr 1 2 main"

	[ -f "$TEST_TMP/standard_called" ]
	[ ! -f "$TEST_TMP/subprocess_called" ]
}

@test "(a) dispatch_composition exits 0 on standard path" {
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

@test "(b) dispatch_composition isolated=true does NOT invoke standard path" {
	require_dispatch_composition

	dispatch_composition "/implement-issue 123 main" "true"

	[ ! -f "$TEST_TMP/standard_called" ]
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
	[ ! -f "$TEST_TMP/standard_called" ]
}

@test "(c) COMPOSITION_BACKEND=subprocess prompt is passed to subprocess path" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="subprocess"

	dispatch_composition "/process-pr 7 8 main" "false"

	local actual
	actual=$(< "$TEST_TMP/subprocess_prompt")
	[[ "$actual" == "/process-pr 7 8 main" ]]
}

@test "(c) COMPOSITION_BACKEND=skill forces standard path even when isolated=true" {
	# NOTE: COMPOSITION_BACKEND=skill is a legacy value name; it routes to
	# run_composition_standard() (the non-sandboxed subprocess path).
	# It does NOT invoke the Skill tool — bash cannot do that.
	require_dispatch_composition
	export COMPOSITION_BACKEND="skill"

	dispatch_composition "/implement-issue 123 main" "true"

	[ -f "$TEST_TMP/standard_called" ]
	[ ! -f "$TEST_TMP/subprocess_called" ]
}

@test "(c) COMPOSITION_BACKEND=skill prompt is passed to standard path" {
	require_dispatch_composition
	export COMPOSITION_BACKEND="skill"

	dispatch_composition "/implement-issue 9 feature" "true"

	local actual
	actual=$(< "$TEST_TMP/standard_prompt")
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

@test "(c) unset COMPOSITION_BACKEND leaves auto-routing in effect for standard path" {
	require_dispatch_composition
	unset COMPOSITION_BACKEND

	dispatch_composition "/process-pr 1 2 main" "false"

	# Auto-routing: non-isolated → standard subprocess
	[ -f "$TEST_TMP/standard_called" ]
	[ ! -f "$TEST_TMP/subprocess_called" ]
}

@test "(c) unset COMPOSITION_BACKEND leaves auto-routing in effect for subprocess path" {
	require_dispatch_composition
	unset COMPOSITION_BACKEND

	dispatch_composition "/implement-issue 123 main" "true"

	# Auto-routing: isolated → subprocess
	[ -f "$TEST_TMP/subprocess_called" ]
	[ ! -f "$TEST_TMP/standard_called" ]
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

# =============================================================================
# (d) CONTEXT MODE WIRING — context_mode_claude_args (issue #542)
# =============================================================================
#
# The ab-harness exports CONTEXT_MODE_ENABLED per arm (0 = control,
# 1 = treatment).  batch-orchestrator must translate that env var into
# claude(1) MCP flags so the control arm suppresses the context-mode plugin
# (--strict-mcp-config) while the treatment arm keeps it.  Without this both
# arms invoke claude identically and the A/B experiment is a no-op.

# Source only context_mode_claude_args from batch-orchestrator.sh.  Soft
# failure (skip) if the helper has not been added yet.
source_context_mode_args() {
	local body
	body=$(_extract_function_body context_mode_claude_args \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	if [[ -z "$body" ]]; then
		return 1
	fi
	eval "$body"
	return 0
}

require_context_mode_args() {
	source_context_mode_args \
		|| skip "context_mode_claude_args() not yet implemented"
}

@test "(d) context_mode_claude_args prints nothing when enabled (treatment)" {
	require_context_mode_args

	CONTEXT_MODE_ENABLED=1 run context_mode_claude_args

	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "(d) context_mode_claude_args suppresses MCP when disabled (control)" {
	require_context_mode_args

	CONTEXT_MODE_ENABLED=0 run context_mode_claude_args

	[ "$status" -eq 0 ]
	[[ "$output" == "--strict-mcp-config" ]]
}

@test "(d) context_mode_claude_args defaults to suppression when unset" {
	require_context_mode_args
	unset CONTEXT_MODE_ENABLED

	run context_mode_claude_args

	[ "$status" -eq 0 ]
	[[ "$output" == "--strict-mcp-config" ]]
}

@test "(d) context_mode_claude_args treats any non-1 value as disabled" {
	require_context_mode_args

	# Only the exact string "1" enables; everything else suppresses.
	CONTEXT_MODE_ENABLED=true run context_mode_claude_args

	[[ "$output" == "--strict-mcp-config" ]]
}

@test "(d) both claude-invoking paths splice in context_mode_claude_args" {
	# Structural: the helper must be defined AND consulted by both
	# run_composition paths, so the per-arm flag actually reaches claude.
	grep -q "^context_mode_claude_args() {$" "$BATCH_ORCHESTRATOR_SCRIPT"

	# definition + one call site in each of the two run_composition functions
	local count
	count=$(grep -c "context_mode_claude_args" "$BATCH_ORCHESTRATOR_SCRIPT")
	[ "$count" -ge 3 ]
}
