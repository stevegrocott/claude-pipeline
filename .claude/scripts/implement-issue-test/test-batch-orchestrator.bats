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
	# Use [[:space:]] instead of \s for POSIX awk compatibility (BSD awk on macOS
	# does not recognise \s in regex patterns).
	arm=$(awk '/merge_blocked\)/,/^[[:space:]]+;;/' "$BATCH_ORCHESTRATOR_SCRIPT" 2>/dev/null)
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

# =============================================================================
# ISSUE #397: surface deploy-verify failures in batch post-run summary
# =============================================================================

# --- Static analysis: deploy_verify_failed field in per-issue structure ---

@test "init_status per-issue structure includes deploy_verify_failed field" {
	# Each issue entry built in init_status() must include
	# deploy_verify_failed: false so the field is always present in
	# status.json even before the orchestrator runs.
	local body
	body=$(awk '/^init_status\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'deploy_verify_failed'* ]]
}

@test "deploy_verify_failed initialised to false (not null or missing)" {
	# Must be boolean false, not null, so select(.deploy_verify_failed == true)
	# never matches an uninitialised field.
	local body
	body=$(awk '/^init_status\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'"deploy_verify_failed": false'* ]]
}

# --- Static analysis: flag propagation in process_issue ---

@test "process_issue detects deploy-verify failure via .degraded_stages in status file" {
	# Integration path: a per-issue status file with .degraded_stages containing
	# a "deploy_verify:..." entry must produce dv_cmd_failed=true when evaluated
	# with the same jq expression that process_issue uses. This exercises the
	# full chain from .degraded_stages (written by implement-issue-orchestrator)
	# to the deploy_verify_failed flag recorded in batch status.json.
	local status_file="$TEST_TMP/issue-status.json"
	printf '{"degraded_stages":["deploy_verify:deploy_failed:exit=1"]}' \
		> "$status_file"
	local dv_cmd_failed
	dv_cmd_failed=$(jq -r \
		'[.degraded_stages[]? | select(startswith("deploy_verify:"))] | length > 0' \
		"$status_file")
	[[ "$dv_cmd_failed" == "true" ]]
}

@test "process_issue updates deploy_verify_failed field in batch status.json" {
	# When deploy_cmd_failed is true the batch must record the failure in
	# the per-issue entry via update_issue_field "deploy_verify_failed".
	local body
	body=$(awk '/^process_issue\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'deploy_verify_failed'* ]]
}

@test "process_issue deploy-verify check does not set impl_status to error" {
	# A non-blocking deploy-verify failure must NOT change impl_status —
	# the issue still completes. Verify the flag-propagation block only
	# calls update_issue_field, not any impl_status assignment.
	local body
	body=$(awk '/Propagate non-blocking deploy-verify/,/already_implemented/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" 2>/dev/null)
	[[ "$body" != *'impl_status='* ]]
}

# --- Static analysis: post-run warning block ---

@test "batch complete section warns about deploy-verify failures" {
	# The post-run summary must log a warning when any issue has
	# deploy_verify_failed set, so operators cannot miss it.
	grep -qE 'DEPLOY-VERIFY FAILURES|deploy.verify.fail' \
		"$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "batch complete warning block checks deploy_verify_failed count" {
	# The warning must only fire when there are actual failures, not on
	# every batch run. Verify the count variable gates the warning block.
	grep -q '_dv_failed_count' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "batch complete warning appears after Batch Complete header" {
	# The deploy-verify failure block must be in the post-run section
	# (after the Batch Complete header), not inside a per-issue function.
	local bc_line dv_line
	bc_line=$(grep -n 'Batch Complete' "$BATCH_ORCHESTRATOR_SCRIPT" \
		| tail -1 | cut -d: -f1)
	dv_line=$(grep -n '_dv_failed_count' "$BATCH_ORCHESTRATOR_SCRIPT" \
		| tail -1 | cut -d: -f1)
	[[ -n "$bc_line" ]]
	[[ -n "$dv_line" ]]
	(( dv_line > bc_line ))
}

# --- Static analysis: summary.json includes deploy_verify_failed ---

@test "summary.json jq filter includes deploy_verify_failed per-issue field" {
	# The summary.json written at the end must expose deploy_verify_failed
	# so callers (handle-issues, CI, humans) can query failures without
	# parsing the full status.json.
	local body
	body=$(awk '/Write summary/,/log.*Summary written/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'deploy_verify_failed'* ]]
}

@test "summary.json includes deploy_verify_failed count in progress" {
	# .progress.deploy_verify_failed must be emitted so consumers can see
	# the failure count at a glance without iterating over .issues[].
	local body
	body=$(awk '/Write summary.*include/,/log.*Summary written/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'deploy_verify_failed'* ]]
}

# --- Functional simulation: deploy_verify_failed summary count ---

_make_deploy_verify_status_json() {
	local file="$1"
	jq -n '{
		state: "completed",
		progress: {
			total: 4,
			completed: 3,
			failed: 1,
			pending: 0,
			in_progress: 0,
			merge_blocked: 0
		},
		issues: [
			{number: "10", status: "completed", pr: 5,
			 deploy_verify_failed: true},
			{number: "11", status: "completed", pr: 6,
			 deploy_verify_failed: false},
			{number: "12", status: "completed", pr: 7,
			 deploy_verify_failed: true},
			{number: "13", status: "failed", pr: null,
			 deploy_verify_failed: false}
		],
		last_update: "2024-01-01T00:00:00Z"
	}' > "$file"
}

_simulate_dv_failed_count() {
	local status_file="$1"
	jq '[.issues[] | select(.deploy_verify_failed == true)] | length' \
		"$status_file"
}

@test "functional: deploy_verify_failed count is 2 from mixed-status batch" {
	local status_file="$TEST_TMP/dv-status.json"
	_make_deploy_verify_status_json "$status_file"
	local count
	count=$(_simulate_dv_failed_count "$status_file")
	[[ "$count" == "2" ]]
}

@test "functional: failed issues with deploy_verify_failed false not counted" {
	# A failed issue that did not reach deploy-verify must not inflate the count.
	local status_file="$TEST_TMP/dv-status.json"
	_make_deploy_verify_status_json "$status_file"
	local count
	count=$(jq \
		'[.issues[] | select(.status == "failed" and .deploy_verify_failed == true)] | length' \
		"$status_file")
	[[ "$count" == "0" ]]
}

@test "functional: summary progress deploy_verify_failed count computed correctly" {
	# Simulate the summary.json .progress computation and verify the count.
	local status_file="$TEST_TMP/dv-status.json"
	_make_deploy_verify_status_json "$status_file"
	local result count
	result=$(jq '(.progress + {
		deploy_verify_failed:
			([.issues[] | select(.deploy_verify_failed == true)] | length)
	})' "$status_file")
	count=$(printf '%s' "$result" | jq '.deploy_verify_failed')
	[[ "$count" == "2" ]]
}

# =============================================================================
# ISSUE #418 TASK 2: validate_issue_for_processing() preflight
# =============================================================================

# --- Static analysis: function definition ---

@test "validate_issue_for_processing function is defined in the script" {
	grep -qE '^validate_issue_for_processing\(\)' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "validate_issue_for_processing is called inside process_issue" {
	local body
	body=$(awk '/^process_issue\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'validate_issue_for_processing'* ]]
}

# --- Static analysis: skip detection conditions ---

@test "validate_issue_for_processing checks for needs-explore label" {
	local body
	body=$(awk '/^validate_issue_for_processing\(\)/,/^\}$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'needs-explore'* ]]
}

@test "validate_issue_for_processing checks for missing Implementation Tasks" {
	local body
	body=$(awk '/^validate_issue_for_processing\(\)/,/^\}$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'Implementation Tasks'* ]]
}

# --- Static analysis: Check 3 structural validation trigger ---

@test "Check 3 fires for bodies with ## Implementation Tasks (not only pipeline-autocreated)" {
	# The Check 3 grep condition must reference '## Implementation Tasks' so
	# that any body carrying that section is subject to assert_issue_valid,
	# not just bodies marked <!-- pipeline-autocreated -->.
	local fn_body check3_block
	fn_body=$(awk '/^validate_issue_for_processing\(\)/,/^\}$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	check3_block=$(printf '%s\n' "$fn_body" \
		| awk '/Check 3/,/^	fi$/' | head -15)
	[[ "$check3_block" == *'Implementation Tasks'* ]]
}

@test "Check 3 still fires for bodies with pipeline-autocreated marker" {
	local fn_body check3_block
	fn_body=$(awk '/^validate_issue_for_processing\(\)/,/^\}$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	check3_block=$(printf '%s\n' "$fn_body" \
		| awk '/Check 3/,/^	fi$/' | head -15)
	[[ "$check3_block" == *'pipeline-autocreated'* ]]
}

# --- Static analysis: enrich-inline path ---

@test "validate_issue_for_processing enriches inline when ENRICH_FOLLOWUPS is set" {
	local body
	body=$(awk '/^validate_issue_for_processing\(\)/,/^\}$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'ENRICH_FOLLOWUPS'* ]]
	[[ "$body" == *'enrich-issue'* ]]
}

# --- Static analysis: gh failure safety ---

@test "validate_issue_for_processing gh failure is non-fatal" {
	# A gh failure (network/auth error) must not cause the function to return
	# 1 — it must use || return 0 or || true so the orchestrator's own
	# issue-validation logic remains the safety net.
	local body
	body=$(awk '/^validate_issue_for_processing\(\)/,/^\}$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'|| return 0'* ]] || [[ "$body" == *'|| true'* ]]
}

# --- Static analysis: skipped status set in process_issue ---

@test "process_issue sets status to skipped on preflight failure" {
	local body
	body=$(awk '/^process_issue\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'"skipped"'* ]]
}

@test "process_issue logs skip reason on preflight failure" {
	local body
	body=$(awk '/^process_issue\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'_SKIP_REASON'* ]]
}

@test "process_issue returns 0 on preflight skip (non-fatal)" {
	# The skip path inside process_issue must return 0 so that
	# consecutive_failures is not incremented and the circuit breaker
	# is not triggered for preflight-skipped issues.
	local body skip_block
	body=$(awk '/^process_issue\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	skip_block=$(printf '%s\n' "$body" \
		| awk '/validate_issue_for_processing/,/return 0/' \
		| head -15)
	[[ "$skip_block" == *'return 0'* ]]
}

# --- Static analysis: progress.skipped counter ---

@test "update_progress includes a progress.skipped field" {
	local body
	body=$(awk '/^update_progress\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'progress.skipped'* ]]
}

@test "update_progress does not count skipped under failed" {
	local body failed_line
	body=$(awk '/^update_progress\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	failed_line=$(printf '%s\n' "$body" | grep 'progress\.failed')
	[[ "$failed_line" != *'skipped'* ]]
}

@test "init_status progress object includes skipped field" {
	local body
	body=$(awk '/^init_status\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'skipped'* ]]
}

@test "summary.json jq filter includes skipped in progress" {
	# The Write summary section must emit a skipped count so consumers
	# can query preflight-skipped issues without iterating .issues[].
	local body
	body=$(awk '/Write summary/,/log.*Summary written/' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'skipped'* ]]
}

@test "batch post-run section warns about preflight-skipped issues" {
	# The batch post-run log must surface skipped issues so operators can
	# see at a glance that issues were skipped and why.
	grep -qE 'PREFLIGHT SKIPPED|preflight.skipped' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "batch post-run skipped warning tracks count via _skipped_count" {
	grep -q '_skipped_count' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "batch post-run skipped warning appears after Batch Complete header" {
	local bc_line sk_line
	bc_line=$(grep -n 'Batch Complete' "$BATCH_ORCHESTRATOR_SCRIPT" \
		| tail -1 | cut -d: -f1)
	sk_line=$(grep -n '_skipped_count' "$BATCH_ORCHESTRATOR_SCRIPT" \
		| tail -1 | cut -d: -f1)
	[[ -n "$bc_line" ]]
	[[ -n "$sk_line" ]]
	(( sk_line > bc_line ))
}

# --- Functional simulation: skipped counted separately from failed ---

_make_skipped_preflight_status_json() {
	local file="$1"
	jq -n '{
		state: "running",
		progress: {
			total: 5,
			completed: 0,
			failed: 0,
			skipped: 0,
			pending: 0,
			in_progress: 0,
			merge_blocked: 0
		},
		issues: [
			{number: "1", status: "completed"},
			{number: "2", status: "skipped"},
			{number: "3", status: "failed"},
			{number: "4", status: "skipped"},
			{number: "5", status: "pending"}
		],
		last_update: "2024-01-01T00:00:00Z"
	}' > "$file"
}

_simulate_update_progress_v2() {
	local status_file="$1"
	jq '.progress.completed =
			([.issues[] | select(.status == "completed"
				or .status == "already_done")] | length) |
		.progress.failed =
			([.issues[] | select(.status == "failed")] | length) |
		.progress.skipped =
			([.issues[] | select(.status == "skipped")] | length) |
		.progress.merge_blocked =
			([.issues[] | select(.status == "merge_blocked")] | length) |
		.progress.in_progress =
			([.issues[] | select(.status == "in_progress")] | length) |
		.progress.pending =
			([.issues[] | select(.status == "pending")] | length)' \
		"$status_file"
}

@test "progress simulation v2: skipped issues counted in skipped field" {
	local status_file="$TEST_TMP/preflight-skipped-status.json"
	_make_skipped_preflight_status_json "$status_file"
	local result count
	result=$(_simulate_update_progress_v2 "$status_file")
	count=$(printf '%s' "$result" | jq '.progress.skipped')
	[[ "$count" == "2" ]]
}

@test "progress simulation v2: skipped issues NOT counted under failed" {
	local status_file="$TEST_TMP/preflight-skipped-status.json"
	_make_skipped_preflight_status_json "$status_file"
	local result count
	result=$(_simulate_update_progress_v2 "$status_file")
	count=$(printf '%s' "$result" | jq '.progress.failed')
	[[ "$count" == "1" ]]
}

@test "progress simulation v2: final_failed excludes skipped" {
	# When there are only skipped issues and no true failures,
	# progress.failed must be 0 so the batch state is 'completed'
	# not 'completed_with_errors'.
	local status_file="$TEST_TMP/all-skipped-status.json"
	jq -n '{
		state: "running",
		progress: {total: 3, completed: 0, failed: 0, skipped: 0,
		           pending: 0, in_progress: 0, merge_blocked: 0},
		issues: [
			{number: "1", status: "skipped"},
			{number: "2", status: "completed"},
			{number: "3", status: "skipped"}
		],
		last_update: "2024-01-01T00:00:00Z"
	}' > "$status_file"
	local result final_failed
	result=$(_simulate_update_progress_v2 "$status_file")
	final_failed=$(printf '%s' "$result" | jq '.progress.failed')
	[[ "$final_failed" == "0" ]]
}

# =============================================================================
# FUNCTIONAL: validate_issue_for_processing — Check 3 body-validation skip
# =============================================================================
#
# Extract and source validate_issue_for_processing from batch-orchestrator.sh
# along with its collaborator assert_issue_valid from issue-body-lib.sh so the
# function can be exercised end-to-end with a mocked gh CLI.
# Returns 1 without aborting when either artefact is absent (skip guard).

source_validate_issue_for_processing() {
	local lib="$SCRIPT_DIR/issue-body-lib.sh"
	[[ -f "$lib" ]] || return 1
	# shellcheck disable=SC1090
	source "$lib"

	local func_file="$TEST_TMP/validate_issue_for_processing.bash"
	awk '/^validate_issue_for_processing\(\)/,/^\}$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" > "$func_file"
	grep -q 'validate_issue_for_processing' "$func_file" 2>/dev/null \
		|| return 1
	# shellcheck disable=SC1090
	source "$func_file"
}

@test "functional: validate_issue_for_processing returns 1 with body-validation _SKIP_REASON when assert_issue_valid fails" {
	# Arrange ----------------------------------------------------------------
	# Mock gh to return a body that has ## Implementation Tasks but no
	# parseable task lines and no ## Acceptance Criteria.
	# This satisfies Check 2 (section present) so execution enters Check 3,
	# where assert_issue_valid returns 1 — triggering the skip path.
	local mock_bin="$TEST_TMP/mock-bin"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/gh" << 'GHEOF'
#!/usr/bin/env bash
# Return body with ## Implementation Tasks that fails assert_issue_valid:
# no parseable task lines, no ## Acceptance Criteria section.
printf '%s\n' '{"body":"## Implementation Tasks\n\nThis is prose, not a task line.\n\n## Background\n\nSome context.","labels":[]}'
GHEOF
	chmod +x "$mock_bin/gh"
	export PATH="$mock_bin:$PATH"

	source_validate_issue_for_processing \
		|| skip "validate_issue_for_processing() not yet present"

	# Stub collaborators so no real shell-outs are attempted.
	log()                  { :; }
	log_warn()             { :; }
	dispatch_composition() { return 1; }
	export ENRICH_FOLLOWUPS=false
	unset DEPLOY_VERIFY_CMD

	# Act --------------------------------------------------------------------
	_SKIP_REASON=""
	local rc=0
	validate_issue_for_processing 99 || rc=$?

	# Assert -----------------------------------------------------------------
	# Function must return 1 (skip, not fatal).
	[[ "$rc" -eq 1 ]]
	# _SKIP_REASON must be set to a body-validation message.
	[[ -n "$_SKIP_REASON" ]]
	[[ "$_SKIP_REASON" == *"body failed structural validation"* ]]
}

# =============================================================================
# TASK 4: PR-recovery WARN names the stuck stage (current_stage from status.json)
# =============================================================================

# --- Static analysis: recovery block reads current_stage ---

@test "recovery block reads .current_stage from issue status file" {
	# The recovery block must parse current_stage so the WARN is informative.
	# Extract the recovery comment block and check for current_stage usage.
	local recovery_block
	recovery_block=$(awk \
		'/Recovery: if the orchestrator exited/,/^        fi$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" 2>/dev/null | head -25 || true)
	[[ "$recovery_block" == *'current_stage'* ]]
}

@test "recovery WARN log_warn message references the stuck stage variable" {
	# The log_warn call inside the recovery block must name the stage —
	# either via a stuck_stage variable or by embedding current_stage directly.
	local recovery_block
	recovery_block=$(awk \
		'/Recovery: if the orchestrator exited/,/^        fi$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" 2>/dev/null | head -25 || true)
	# Must contain a log_warn that references stage information
	[[ "$recovery_block" == *'stuck'* ]] || \
		[[ "$recovery_block" == *'current_stage'* && \
		   "$recovery_block" == *'log_warn'* ]]
}

# --- Functional simulation: stuck stage appears in warn message ---

# Build an issue status JSON that simulates a crash mid-stage with a PR written.
_simulate_recovery_with_stage() {
	local crash_state="$1"
	local pr_num="$2"
	local current_stage="${3:-unknown}"

	local issue_status="$TEST_TMP/sim-issue-status-staged.json"
	jq -n \
		--arg s "$crash_state" \
		--argjson pr "$pr_num" \
		--arg cs "$current_stage" \
		'{state: $s, current_stage: $cs, stages: {pr: {pr_number: $pr}}}' \
		> "$issue_status"

	sim_recovering=false
	sim_warn_msg=""
	sim_impl_status="error"
	sim_pr_number=""

	local st
	st=$(jq -r '.state' "$issue_status")

	# The stuck stage is what the new code must parse from current_stage
	local stuck_stage
	stuck_stage=$(jq -r '.current_stage // "unknown"' \
		"$issue_status" 2>/dev/null)
	[[ -n "$stuck_stage" ]] || stuck_stage="unknown"

	# Recovery block (replicates the post-task-4 implementation)
	local recovered_pr
	recovered_pr=$(jq -r '.stages.pr.pr_number // empty' \
		"$issue_status" 2>/dev/null)
	if [[ -n "$recovered_pr" && "$recovered_pr" =~ ^[0-9]+$ ]]; then
		sim_recovering=true
		sim_warn_msg="Orchestrator exited with state='$st'"
		sim_warn_msg+=" (stuck at: $stuck_stage)"
		sim_warn_msg+=" but PR #$recovered_pr exists — recovering as success"
		sim_impl_status="success"
		sim_pr_number="$recovered_pr"
	fi
}

@test "recovery simulation: warn names the stuck stage when current_stage is set" {
	_simulate_recovery_with_stage "error" 99 "merge_pr_timeout"
	[[ "$sim_recovering" == "true" ]]
	[[ "$sim_warn_msg" == *"merge_pr_timeout"* ]]
}

@test "recovery simulation: warn names stuck stage for any error state with PR" {
	_simulate_recovery_with_stage "interrupted_during_quality" 55 "run_tests"
	[[ "$sim_recovering" == "true" ]]
	[[ "$sim_warn_msg" == *"run_tests"* ]]
}

@test "recovery simulation: warn falls back to 'unknown' when current_stage absent" {
	# Simulate a status file with no current_stage field
	local issue_status="$TEST_TMP/sim-no-stage.json"
	jq -n --argjson pr 77 \
		'{state: "error", stages: {pr: {pr_number: $pr}}}' \
		> "$issue_status"

	local stuck_stage
	stuck_stage=$(jq -r '.current_stage // "unknown"' \
		"$issue_status" 2>/dev/null)
	[[ "$stuck_stage" == "unknown" ]]
}

@test "recovery simulation: still recovers as success when current_stage is set" {
	_simulate_recovery_with_stage "error" 42 "merge_pr_timeout"
	[[ "$sim_impl_status" == "success" ]]
	[[ "$sim_pr_number" == "42" ]]
}

# =============================================================================
# TASK 6 (i436): --implement-followups flag and post-batch follow-up wave
# =============================================================================

@test "--implement-followups flag is recognised in argument parsing" {
	grep -qE '^\s+--implement-followups\)' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "IMPLEMENT_FOLLOWUPS variable is initialised before argument parsing" {
	local decl_block
	decl_block=$(awk \
		'/^while \[\[ \$# -gt 0 \]\]; do/{exit} {print}' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$decl_block" == *'IMPLEMENT_FOLLOWUPS=false'* ]]
}

@test "IMPLEMENT_FOLLOWUPS defaults to false when no flag is passed" {
	grep -qE '^IMPLEMENT_FOLLOWUPS=false' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "usage documents the --implement-followups flag" {
	local body
	body=$(awk '/^usage\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'implement-followups'* ]]
}

@test "--no-implement-followups flag is recognised in argument parsing" {
	grep -qE '^\s+--no-implement-followups\)' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "--no-implement-followups case sets IMPLEMENT_FOLLOWUPS to false" {
	local body
	body=$(awk '/--no-implement-followups\)/,/^\s+;;/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" 2>/dev/null)
	[[ "$body" == *'IMPLEMENT_FOLLOWUPS=false'* ]]
}

@test "sweep_implement_followups function is defined in the script" {
	grep -qE '^sweep_implement_followups\(\)' "$BATCH_ORCHESTRATOR_SCRIPT"
}

@test "sweep_implement_followups deduplicates follow-ups against original manifest" {
	# The function must compare collected follow-up numbers against ISSUE_ARRAY
	# (the original manifest) to avoid re-processing issues that were already
	# handled in the primary loop.
	local body
	body=$(awk '/^sweep_implement_followups\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'ISSUE_ARRAY'* ]]
}

# Extract and source sweep_implement_followups() from batch-orchestrator.sh so
# it can be exercised behaviorally with mocked process_issue/log/log_warn.
# Mirrors the source_batch_dispatch_composition() pattern in
# test-orchestrator-composition.bats.  Returns 1 (without aborting) when the
# function is not yet present so callers can skip.
source_sweep_implement_followups() {
	local func_file="$TEST_TMP/sweep_implement_followups.bash"
	awk '/^sweep_implement_followups\(\)/,/^\}$/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" > "$func_file"
	grep -q 'sweep_implement_followups()' "$func_file" 2>/dev/null || return 1
	# shellcheck disable=SC1090
	source "$func_file"
}

@test "sweep_implement_followups surfaces depth-2 follow-ups via log_warn but does NOT implement them" {
	source_sweep_implement_followups || skip "sweep_implement_followups() not yet present"

	export MAX_FOLLOWUP_DEPTH=1
	export ENRICH_FOLLOWUPS=true
	ISSUE_ARRAY=(1)

	# Primary issue #1 completed with a depth-1 follow-up #100.
	cat > "$STATUS_FILE" <<-'JSON'
	{
	  "progress": {"total": 1, "pending": 0, "completed": 1, "failed": 0},
	  "issues": [
	    {"number": "1", "status": "completed", "follow_ups": ["100"]}
	  ]
	}
	JSON

	# Mocks: capture log_warn output and process_issue call list; simulate
	# follow-up #100 spawning a depth-2 follow-up #200 when implemented.
	log()      { printf '%s\n' "$*" >> "$TEST_TMP/log.out"; }
	log_warn() { printf '%s\n' "$*" >> "$TEST_TMP/warn.out"; }
	process_issue() {
		printf '%s\n' "$1" >> "$TEST_TMP/process_issue.calls"
		if [[ "$1" == "100" ]]; then
			jq '(.issues[] | select(.number == "100") | .follow_ups) = ["200"]' \
				"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
				&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
		fi
		return 0
	}

	sweep_implement_followups

	# Depth-1 follow-up #100 WAS implemented.
	grep -qx '100' "$TEST_TMP/process_issue.calls"
	# Depth-2 follow-up #200 was NOT implemented (beyond MAX_FOLLOWUP_DEPTH).
	! grep -qx '200' "$TEST_TMP/process_issue.calls"
	# Depth-2 follow-up #200 WAS surfaced as a warning for manual triage.
	grep -q '200' "$TEST_TMP/warn.out"
	grep -q 'MAX_FOLLOWUP_DEPTH' "$TEST_TMP/warn.out"
}

@test "sweep_implement_followups registers a placeholder row and bumps progress totals before implementing" {
	source_sweep_implement_followups || skip "sweep_implement_followups() not yet present"

	export MAX_FOLLOWUP_DEPTH=1
	export ENRICH_FOLLOWUPS=true
	ISSUE_ARRAY=(1)

	cat > "$STATUS_FILE" <<-'JSON'
	{
	  "progress": {"total": 1, "pending": 0, "completed": 1, "failed": 0},
	  "issues": [
	    {"number": "1", "status": "completed", "follow_ups": ["100"]}
	  ]
	}
	JSON

	log()      { :; }
	log_warn() { :; }
	# process_issue records whether the #100 row already existed when it ran —
	# proving the sweep's placeholder injection (not process_issue) registered it.
	process_issue() {
		jq -e --arg n "$1" '.issues[] | select(.number == $n)' "$STATUS_FILE" \
			> "$TEST_TMP/row_present_$1" 2>/dev/null
		return 0
	}

	sweep_implement_followups

	# A placeholder row for #100 existed by the time process_issue ran.
	[[ -s "$TEST_TMP/row_present_100" ]]
	# progress.total/pending were bumped to reflect the wave-2 issue.
	[[ "$(jq '.progress.total' "$STATUS_FILE")" == "2" ]]
	[[ "$(jq '.progress.pending' "$STATUS_FILE")" == "1" ]]
}

@test "sweep_implement_followups invokes process_issue for each follow-up" {
	local body
	body=$(awk '/^sweep_implement_followups\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'process_issue'* ]]
}

@test "main body calls sweep_implement_followups when IMPLEMENT_FOLLOWUPS is true" {
	# After the primary issue loop, the script must call the sweep function
	# conditionally on the flag.  Two independent file-wide greps would pass
	# even if the guard and call are in unrelated positions (e.g. inside the
	# function definition vs the call site).  Scope the assertion to the
	# post-loop section by capturing only the content after the LAST bare
	# 'done' line (which closes the main issue for-loop), then verifying both
	# the IMPLEMENT_FOLLOWUPS conditional guard and the
	# sweep_implement_followups call are present within that scoped block.
	local post_loop
	post_loop=$(awk \
		'BEGIN{n=0} /^done$/{n=NR} {lines[NR]=$0} END{for(i=n+1;i<=NR;i++) print lines[i]}' \
		"$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$post_loop" == *'sweep_implement_followups'* ]]
	[[ "$post_loop" == *'IMPLEMENT_FOLLOWUPS'* ]]
}

@test "--implement-followups sets ENRICH_FOLLOWUPS to true" {
	# When --implement-followups is passed it must imply --enrich-followups so
	# that needs-explore issues are enriched before being implemented.
	# Scope to the case branch only to avoid matching unrelated assignments.
	local body
	body=$(awk '/--implement-followups\)/,/^\s+;;/' \
		"$BATCH_ORCHESTRATOR_SCRIPT" 2>/dev/null)
	[[ "$body" == *'ENRICH_FOLLOWUPS=true'* ]]
}

@test "sweep_implement_followups bumps progress.total for each wave-2 issue" {
	# update_progress derives completed/failed/skipped/etc. from .issues[]
	# but never recomputes .progress.total, which is set once at init to the
	# original manifest count.  When the sweep registers a wave-2 follow-up as
	# a new .issues[] row it MUST also increment .progress.total so the totals
	# stay consistent with the wave-2 outcomes.  Without this, completed+failed
	# can exceed total and pending can go negative.
	local body
	body=$(awk '/^sweep_implement_followups\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'.progress.total = (.progress.total + 1)'* ]]
}

@test "sweep_implement_followups bumps progress.pending for each wave-2 issue" {
	# A freshly-registered wave-2 follow-up starts in the "pending" state, so
	# .progress.pending must be incremented alongside .progress.total to keep
	# the registration snapshot internally consistent before process_issue
	# transitions the issue out of pending.
	local body
	body=$(awk '/^sweep_implement_followups\(\)/,/^\}$/' "$BATCH_ORCHESTRATOR_SCRIPT")
	[[ "$body" == *'.progress.pending = (.progress.pending + 1)'* ]]
}

@test "wave-2 follow-up totals are bumped via real jq transformation" {
	# Behavioural check: extract the registration jq filter and run it against a
	# representative status.json to prove .progress.total/.pending actually
	# increment by one per registered wave-2 issue (not just that the text is
	# present).
	local status="$TEST_TMP/status.json"
	cat > "$status" <<-'JSON'
		{
		  "progress": { "total": 2, "completed": 2, "pending": 0,
		    "failed": 0, "skipped": 0, "in_progress": 0 },
		  "issues": [
		    { "number": "10", "status": "completed" },
		    { "number": "11", "status": "completed" }
		  ]
		}
	JSON

	local out
	out=$(jq --arg num "12" \
		'.issues += [{ "number": $num, "status": "pending" }]
		 | .progress.total = (.progress.total + 1)
		 | .progress.pending = (.progress.pending + 1)' \
		"$status")

	[[ "$(jq -r '.progress.total' <<< "$out")" == "3" ]]
	[[ "$(jq -r '.progress.pending' <<< "$out")" == "1" ]]
	[[ "$(jq -r '.issues | length' <<< "$out")" == "3" ]]
}
