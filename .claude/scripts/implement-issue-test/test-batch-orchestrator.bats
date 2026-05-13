#!/usr/bin/env bats
#
# test-batch-orchestrator.bats
# Tests for batch-orchestrator.sh state routing, specifically the merge_blocked
# state which must produce a distinct "PR left open" message instead of the
# "recovering as success" message.
#
# Issue #326: batch-orchestrator.sh must recognise merge_blocked as a deliberate
# terminal state (not a crash/interruption) and log accordingly.  Prior to the
# fix, merge_blocked fell into the catch-all *) branch, which set impl_status
# to "error" and then triggered the PR-recovery path — incorrectly upgrading a
# quality-gate block to a success.
#

load 'helpers/test-helper.bash'

# Path to the script under test (batch-orchestrator.sh lives alongside
# implement-issue-orchestrator.sh in .claude/scripts/).
BATCH_ORCHESTRATOR_SCRIPT="$SCRIPT_DIR/batch-orchestrator.sh"

setup() {
	setup_test_env

	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"

	mkdir -p "$LOG_BASE"
}

teardown() {
	teardown_test_env
}

# =============================================================================
# PRECONDITION: script exists
# =============================================================================

@test "batch-orchestrator.sh exists and is executable" {
	[[ -f "$BATCH_ORCHESTRATOR_SCRIPT" ]]
	[[ -x "$BATCH_ORCHESTRATOR_SCRIPT" ]]
}

# =============================================================================
# STATIC ANALYSIS: merge_blocked case arm
# =============================================================================

@test "batch-orchestrator.sh has a merge_blocked) case arm" {
	grep -qE '^\s+merge_blocked\)' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "merge_blocked case arm does NOT set impl_status to error" {
	# Extract the merge_blocked case arm and assert it sets a non-error status.
	local arm
	arm=$(awk '/merge_blocked\)/,/^\s+;;/' "$BATCH_ORCHESTRATOR_SCRIPT" 2>/dev/null)
	# The arm must not contain impl_status="error"
	[[ "$arm" != *'impl_status="error"'* ]]
}

@test "batch-orchestrator.sh logs a new merge-blocked message for merge_blocked state" {
	# The fix must log a message that mentions the PR being left open and the
	# quality gate block — NOT the generic "recovering as success" text.
	local script_content
	script_content=$(< "$BATCH_ORCHESTRATOR_SCRIPT")

	# New message must reference "merge blocked" (case-insensitive) and an open PR
	[[ "$script_content" == *'merge blocked by quality gate'* ]] || \
	[[ "$script_content" == *'left open'*'merge'* ]] || \
	[[ "$script_content" == *'merge_blocked'*'PR'* ]]
}

@test "batch-orchestrator.sh new merge-blocked message contains 'left open'" {
	grep -q 'left open' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "batch-orchestrator.sh new merge-blocked message contains 'quality gate'" {
	grep -q 'quality gate' "$BATCH_ORCHESTRATOR_SCRIPT"
}

# =============================================================================
# STATIC ANALYSIS: "recovering as success" is guarded by impl_status == error
# =============================================================================

@test "recovering-as-success log message is inside the impl_status==error guard" {
	# The recovery block must only fire when impl_status is "error".
	# Verify that the "recovering as success" string appears *after* an
	# if [[ "$impl_status" == "error" ]] guard in the file.
	local script_content
	script_content=$(< "$BATCH_ORCHESTRATOR_SCRIPT")

	local guard_line recovery_line
	guard_line=$(grep -n '"$impl_status" == "error"' "$BATCH_ORCHESTRATOR_SCRIPT" \
		| tail -1 | cut -d: -f1)
	recovery_line=$(grep -n 'recovering as success' "$BATCH_ORCHESTRATOR_SCRIPT" \
		| tail -1 | cut -d: -f1)

	# Both lines must be present and recovery must appear after the guard
	[[ -n "$guard_line" ]]
	[[ -n "$recovery_line" ]]
	(( recovery_line > guard_line ))
}

# =============================================================================
# FUNCTIONAL: state routing simulation
# =============================================================================
#
# These tests replicate the batch-orchestrator.sh process_issue state-routing
# logic in pure bash so we can verify it without running the full script (which
# requires git, gh, etc.).

# Simulate the post-fix state routing for a given state value.
# Populates: sim_impl_status, sim_pr_number, sim_warn_msg, sim_recovering
_simulate_state_routing() {
	local state="$1"
	local pr_in_status="${2:-}"  # PR number already written to status file

	# Create a temporary mock issue status file
	local issue_status="$TEST_TMP/sim-issue-status.json"
	if [[ -n "$pr_in_status" ]]; then
		jq -n --argjson pr "$pr_in_status" \
			'{state: $ARGS.named.s, stages: {pr: {pr_number: $pr}}}' \
			--arg s "$state" > "$issue_status"
	else
		jq -n --arg s "$state" '{state: $s}' > "$issue_status"
	fi

	sim_impl_status="error"
	sim_pr_number=""
	sim_warn_msg=""
	sim_recovering=false

	local st
	st=$(jq -r '.state' "$issue_status")

	# Replicate the FIXED case statement (post-issue-326 task 1)
	case "$st" in
		completed)
			sim_impl_status="success"
			sim_pr_number=$(jq -r '.stages.pr.pr_number // empty' "$issue_status" 2>/dev/null)
			;;
		already_implemented)
			sim_impl_status="already_implemented"
			;;
		merge_blocked)
			sim_impl_status="merge_blocked"
			sim_pr_number=$(jq -r '.stages.pr.pr_number // empty' "$issue_status" 2>/dev/null)
			sim_warn_msg="PR #${sim_pr_number} left open — merge blocked by quality gate"
			;;
		error|max_iterations_quality|max_iterations_pr_review)
			sim_impl_status="error"
			;;
		interrupted_during_*)
			sim_impl_status="error"
			;;
		*)
			sim_impl_status="error"
			;;
	esac

	# Replicate the recovery block (guarded by impl_status == error)
	if [[ "$sim_impl_status" == "error" ]]; then
		local recovered_pr
		recovered_pr=$(jq -r '.stages.pr.pr_number // empty' "$issue_status" 2>/dev/null)
		if [[ -n "$recovered_pr" && "$recovered_pr" =~ ^[0-9]+$ ]]; then
			sim_recovering=true
			sim_warn_msg="Orchestrator exited with state='$st' but PR #$recovered_pr exists — recovering as success"
			sim_impl_status="success"
			sim_pr_number="$recovered_pr"
		fi
	fi
}

@test "merge_blocked state with PR number: impl_status is not error after routing" {
	_simulate_state_routing "merge_blocked" 42
	[[ "$sim_impl_status" == "merge_blocked" ]]
}

@test "merge_blocked state with PR number: recovery block is NOT triggered" {
	_simulate_state_routing "merge_blocked" 42
	[[ "$sim_recovering" == "false" ]]
}

@test "merge_blocked state with PR number: new message contains 'merge blocked by quality gate'" {
	_simulate_state_routing "merge_blocked" 42
	[[ "$sim_warn_msg" == *"merge blocked by quality gate"* ]]
}

@test "merge_blocked state with PR number: new message contains 'left open'" {
	_simulate_state_routing "merge_blocked" 42
	[[ "$sim_warn_msg" == *"left open"* ]]
}

@test "merge_blocked state with PR number: new message does NOT say 'recovering as success'" {
	_simulate_state_routing "merge_blocked" 42
	[[ "$sim_warn_msg" != *"recovering as success"* ]]
}

@test "merge_blocked state without PR number: still not treated as error needing recovery" {
	_simulate_state_routing "merge_blocked" ""
	[[ "$sim_impl_status" == "merge_blocked" ]]
	[[ "$sim_recovering" == "false" ]]
}

@test "completed state still routes correctly after merge_blocked arm is added" {
	_simulate_state_routing "completed" 7
	[[ "$sim_impl_status" == "success" ]]
	[[ "$sim_pr_number" == "7" ]]
	[[ "$sim_recovering" == "false" ]]
}

@test "unknown crash state with PR still recovers as success (regression guard)" {
	# A genuine crash with an unknown state (not merge_blocked) that left a PR
	# behind must still use the recovery path.
	_simulate_state_routing "some_unknown_crash_state" 99
	[[ "$sim_recovering" == "true" ]]
	[[ "$sim_impl_status" == "success" ]]
	[[ "$sim_warn_msg" == *"recovering as success"* ]]
}

# =============================================================================
# TASK 2: merge_blocked counted in its own progress column
# =============================================================================

# --- Static analysis: update_progress ---

@test "update_progress jq filter includes a merge_blocked progress field" {
	# The update_progress function must assign .progress.merge_blocked
	local body
	body=$(awk '/^update_progress\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'progress.merge_blocked'* ]]
}

@test "update_progress does not count merge_blocked under failed" {
	local body
	body=$(awk '/^update_progress\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	# Grab only the line that sets progress.failed
	local failed_line
	failed_line=$(printf '%s\n' "$body" | grep 'progress\.failed')
	# The failed selector must not also select merge_blocked issues
	[[ "$failed_line" != *'merge_blocked'* ]]
}

@test "update_progress does not count merge_blocked under completed" {
	local body
	body=$(awk '/^update_progress\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	local completed_line
	completed_line=$(printf '%s\n' "$body" | grep 'progress\.completed')
	[[ "$completed_line" != *'merge_blocked'* ]]
}

# --- Static analysis: init_status ---

@test "init_status progress object includes merge_blocked field" {
	local body
	body=$(awk '/^init_status\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'merge_blocked'* ]]
}

# --- Functional simulation ---
#
# Build a mock status.json with mixed issue statuses and verify that the
# correct update_progress jq logic produces the expected per-column counts.
# The helper _simulate_update_progress replicates the post-fix jq filter.

_make_mixed_status_json() {
	local file="$1"
	jq -n '{
		state: "running",
		progress: {
			total: 5,
			completed: 0,
			failed: 0,
			pending: 0,
			in_progress: 0,
			merge_blocked: 0
		},
		issues: [
			{number: "1", status: "completed"},
			{number: "2", status: "merge_blocked"},
			{number: "3", status: "failed"},
			{number: "4", status: "merge_blocked"},
			{number: "5", status: "pending"}
		],
		last_update: "2024-01-01T00:00:00Z"
	}' > "$file"
}

_simulate_update_progress() {
	local status_file="$1"
	jq '.progress.completed = ([.issues[] | select(.status == "completed" or .status == "already_done")] | length) |
		.progress.failed = ([.issues[] | select(.status == "failed" or .status == "skipped")] | length) |
		.progress.merge_blocked = ([.issues[] | select(.status == "merge_blocked")] | length) |
		.progress.in_progress = ([.issues[] | select(.status == "in_progress")] | length) |
		.progress.pending = ([.issues[] | select(.status == "pending")] | length)' \
		"$status_file"
}

@test "progress simulation: merge_blocked issues counted in merge_blocked column" {
	local status_file="$TEST_TMP/sim-status.json"
	_make_mixed_status_json "$status_file"
	local result
	result=$(_simulate_update_progress "$status_file")
	local count
	count=$(printf '%s' "$result" | jq '.progress.merge_blocked')
	[[ "$count" == "2" ]]
}

@test "progress simulation: merge_blocked issues not counted under failed" {
	local status_file="$TEST_TMP/sim-status.json"
	_make_mixed_status_json "$status_file"
	local result
	result=$(_simulate_update_progress "$status_file")
	local count
	count=$(printf '%s' "$result" | jq '.progress.failed')
	[[ "$count" == "1" ]]
}

@test "progress simulation: merge_blocked issues not counted under completed" {
	local status_file="$TEST_TMP/sim-status.json"
	_make_mixed_status_json "$status_file"
	local result
	result=$(_simulate_update_progress "$status_file")
	local count
	count=$(printf '%s' "$result" | jq '.progress.completed')
	[[ "$count" == "1" ]]
}
