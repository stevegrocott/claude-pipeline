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

# =============================================================================
# TASK 3: pre-flight else-branch warns when session key is unset
# =============================================================================

@test "pre-flight block has an else branch" {
	# The if block at the session-key check must have a corresponding else
	# so operators receive a warning when CLAUDE_USAGE_SESSION_KEY is unset.
	local body
	body=$(awk '/Pre-flight usage check/,/^consecutive_failures/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'else'* ]]
}

@test "pre-flight else branch emits a log_warn call" {
	local body
	body=$(awk '/Pre-flight usage check/,/^consecutive_failures/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'log_warn'* ]]
}

@test "pre-flight else branch warns that session key is unset" {
	grep -q 'CLAUDE_USAGE_SESSION_KEY unset' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "pre-flight else branch includes export setup hint for session key" {
	grep -q 'export CLAUDE_USAGE_SESSION_KEY' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "pre-flight else branch includes export setup hint for org ID" {
	grep -q 'export CLAUDE_USAGE_ORG_ID' "$BATCH_ORCHESTRATOR_SCRIPT"
}

# =============================================================================
# TASK 5: --enrich-followups flag and post-batch needs-explore sweep
# =============================================================================

@test "--enrich-followups flag is recognised in argument parsing" {
	grep -qE '^\s+--enrich-followups\)' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "ENRICH_FOLLOWUPS variable is initialised before argument parsing" {
	grep -q 'ENRICH_FOLLOWUPS' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "usage documents the --enrich-followups flag" {
	local body
	body=$(awk '/^usage\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'enrich-followups'* ]]
}

@test "BATCH_START_TIME is captured before the main issue loop" {
	# Must be set before the main 'for issue in "${ISSUE_ARRAY[@]}"' loop so
	# that the sweep can filter to issues created during this batch run.
	# Pin to the ACTUAL assignment (BATCH_START_TIME=) — not comments — and
	# to the LAST occurrence of the for-loop, which is the main loop (other
	# matches are inside helper functions like init_status()).
	local start_line loop_line
	start_line=$(grep -n '^BATCH_START_TIME=' "$BATCH_ORCHESTRATOR_SCRIPT" \
		| head -1 | cut -d: -f1)
	loop_line=$(grep -n 'for issue in.*ISSUE_ARRAY' "$BATCH_ORCHESTRATOR_SCRIPT" \
		| tail -1 | cut -d: -f1)
	[[ -n "$start_line" ]]
	[[ -n "$loop_line" ]]
	(( start_line < loop_line ))
}

@test "sweep_enrich_followups function is defined in the script" {
	grep -qE '^sweep_enrich_followups\(\)' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "sweep_enrich_followups queries gh for needs-explore label" {
	local body
	body=$(awk '/^sweep_enrich_followups\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'needs-explore'* ]]
}

@test "sweep_enrich_followups filters by BATCH_START_TIME" {
	local body
	body=$(awk '/^sweep_enrich_followups\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'BATCH_START_TIME'* ]]
}

@test "sweep_enrich_followups invokes enrich-issue for each found issue" {
	local body
	body=$(awk '/^sweep_enrich_followups\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'enrich-issue'* ]]
}

@test "sweep_enrich_followups does not touch consecutive_failures" {
	# Enrichment errors must not trigger the circuit breaker.
	local body
	body=$(awk '/^sweep_enrich_followups\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" != *'consecutive_failures'* ]]
}

@test "main body calls sweep_enrich_followups when ENRICH_FOLLOWUPS is true" {
	# After the primary issue loop, the script must call the sweep function
	# conditionally on the flag.  Two independent file-wide greps would pass
	# even if the guard and call are in unrelated positions (e.g. inside the
	# function definition vs the call site).  Scope the assertion to the
	# post-loop section by capturing only the content after the LAST bare
	# 'done' line (which closes the main issue for-loop), then verifying both
	# the ENRICH_FOLLOWUPS conditional guard and the sweep_enrich_followups
	# call are present within that scoped block.
	local post_loop
	post_loop=$(awk 'BEGIN{n=0} /^done$/{n=NR} {lines[NR]=$0} END{for(i=n+1;i<=NR;i++) print lines[i]}' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$post_loop" == *'sweep_enrich_followups'* ]]
	[[ "$post_loop" == *'ENRICH_FOLLOWUPS'* ]]
}

# =============================================================================
# TASK 1 (i380): --no-enrich-followups opt-out flag
# TASK 2 (i385): ENRICH_FOLLOWUPS reverted to false (opt-in semantics)
# =============================================================================

@test "ENRICH_FOLLOWUPS defaults to false when no flag is passed" {
	# The default must be false so the sweep is opt-in.
	# Callers that want enrichment must pass --enrich-followups explicitly.
	grep -qE '^ENRICH_FOLLOWUPS=false' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "--no-enrich-followups flag is recognised in argument parsing" {
	grep -qE '^\s+--no-enrich-followups\)' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "--no-enrich-followups case sets ENRICH_FOLLOWUPS to false" {
	local body
	body=$(awk '/--no-enrich-followups\)/,/^\s+;;/' "$BATCH_ORCHESTRATOR_SCRIPT" 2>/dev/null)
	[[ "$body" == *'ENRICH_FOLLOWUPS=false'* ]]
}

@test "usage documents the --no-enrich-followups flag" {
	local body
	body=$(awk '/^usage\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'no-enrich-followups'* ]]
}

# =============================================================================
# TASK 2 (i393): up-front skip gate — closed issue OR merged PR via gh
# =============================================================================

@test "up-front skip gate: gh issue view check is present in main loop" {
	grep -qE "gh issue view.*--json state" "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "up-front skip gate: gh pr list merged check is present in main loop" {
	grep -qE "gh pr list.*--state merged" "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "up-front skip gate: gated on GIT_HOST=github" {
	# The check must be conditional on GIT_HOST to avoid running gh
	# commands on non-GitHub platforms (e.g. GitLab + Jira setups).
	grep -qE 'GIT_HOST.*github' "$BATCH_ORCHESTRATOR_SCRIPT"
}

# MAINTENANCE NOTE: the tests below anchor awk ranges and greps on exact log
# message text ('already closed on GitHub', 'already merged'). They will
# silently stop matching — passing vacuously or failing — if that wording is
# reworded in batch-orchestrator.sh. If you change a log string there, update
# the matching pattern here in lockstep. Where practical, prefer anchoring on
# code structure (e.g. 'gh issue view', 'status" "completed') over prose.
@test "up-front skip gate: closed issue triggers a log message" {
	grep -q 'already closed on GitHub' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "up-front skip gate: merged PR triggers a log message" {
	grep -q 'already merged' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "up-front skip gate: closed issue sets status to completed" {
	# Verify the closed-issue branch updates the issue to completed so
	# update_progress counts it correctly (not as failed/skipped).
	# Anchor on code structure (_upfront_issue_state == CLOSED condition)
	# rather than log message wording.
	local block
	block=$(awk '/_upfront_issue_state.*==.*CLOSED/,/continue/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" | head -10)
	[[ "$block" == *'update_issue_field'* ]]
	[[ "$block" == *'"status"'* ]]
	[[ "$block" == *'"completed"'* ]]
}

@test "up-front skip gate: merged PR sets status to completed" {
	# Anchor on code structure (_merged_pr detection block) not log wording.
	local block
	block=$(awk '/\[\[ -n.*_merged_pr/,/continue/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" | head -10)
	[[ "$block" == *'update_issue_field'* ]]
	[[ "$block" == *'"status"'* ]]
	[[ "$block" == *'"completed"'* ]]
}

@test "up-front skip gate: merged PR update also stores the PR number" {
	# The PR field must be written so handle-issues progress table shows it.
	# Anchor on code structure (_merged_pr detection block) not log wording.
	local block
	block=$(awk '/\[\[ -n.*_merged_pr/,/update_progress/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" | head -15)
	[[ "$block" == *'update_issue_field'* ]]
	[[ "$block" == *'"pr"'* ]]
}

@test "up-front skip gate: gh failures are non-fatal (|| true pattern)" {
	# Network errors from gh must not abort the batch; the gate must use
	# || true (or equivalent) to suppress non-zero exit codes.
	local block
	block=$(awk '/Up-front skip gate/,/fi.*#.*end.*GIT_HOST|^\s+fi$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" | head -40)
	[[ "$block" == *'|| true'* ]]
}

@test "up-front skip gate: appears before process_issue call in the loop" {
	local upfront_line process_line
	upfront_line=$(grep -n "gh issue view.*--json state" \
		"$BATCH_ORCHESTRATOR_SCRIPT" | tail -1 | cut -d: -f1)
	process_line=$(grep -n "if process_issue" \
		"$BATCH_ORCHESTRATOR_SCRIPT" | tail -1 | cut -d: -f1)
	[[ -n "$upfront_line" ]]
	[[ -n "$process_line" ]]
	(( upfront_line < process_line ))
}

@test "up-front skip gate: complements not replaces the status.json check" {
	# Both checks must be present: status.json line AND the gh gate.
	grep -qE 'current_status.*completed' "$BATCH_ORCHESTRATOR_SCRIPT"
	grep -qE "gh issue view.*--json state" "$BATCH_ORCHESTRATOR_SCRIPT"
}

# --- Functional simulation: update_progress after gh-skip ---
#
# When the up-front gate sets status=completed for a skipped issue,
# update_progress must count it under .progress.completed, not under
# .progress.failed.

_make_gh_skip_status_json() {
	local file="$1"
	jq -n '{
		state: "running",
		progress: {
			total: 3,
			completed: 0,
			failed: 0,
			pending: 0,
			in_progress: 0,
			merge_blocked: 0
		},
		issues: [
			{number: "10", status: "completed"},
			{number: "11", status: "completed"},
			{number: "12", status: "pending"}
		],
		last_update: "2024-01-01T00:00:00Z"
	}' > "$file"
}

@test "gh-skipped issues (status=completed) counted in progress.completed" {
	local status_file="$TEST_TMP/gh-skip-status.json"
	_make_gh_skip_status_json "$status_file"
	local result count
	result=$(_simulate_update_progress "$status_file")
	count=$(printf '%s' "$result" | jq '.progress.completed')
	[[ "$count" == "2" ]]
}

@test "gh-skipped issues (status=completed) not counted in progress.failed" {
	local status_file="$TEST_TMP/gh-skip-status.json"
	_make_gh_skip_status_json "$status_file"
	local result count
	result=$(_simulate_update_progress "$status_file")
	count=$(printf '%s' "$result" | jq '.progress.failed')
	[[ "$count" == "0" ]]
}
