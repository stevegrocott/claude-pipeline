#!/usr/bin/env bats
#
# test-pr-recovery-gate.bats
# Tests for batch-orchestrator.sh's PR-exists recovery heuristic gate.
#
# Issue #848: an orchestrator that exits `error` while stuck at merge_pr was
# converted to `success` by the recovery heuristic purely because a PR number
# existed.  That handed off to /process-pr, which merged a PR whose required
# check had already concluded in failure — laundering merge-mr.sh's explicit
# refusal into a merge.  The heuristic exists for a crash *after* PR creation
# but before set_final_state, where PR existence really is evidence the work
# got far enough; at merge_pr that premise is inverted.
#
# These tests source the BUNDLED copy under plugins/pipeline-core/scripts/
# (the tree consumers install and that bats sources) rather than replicating
# the logic, so a fix that lands only in .claude/scripts/ is not credited here.
#

bats_require_minimum_version 1.5.0

load 'helpers/test-helper.bash'

# Resolve the bundled copy at file-load time. SCRIPT_DIR (set by
# test-helper.bash) is .claude/scripts; the repo root is two levels up.
BUNDLE_ORCHESTRATOR="$(cd "$SCRIPT_DIR/../.." && pwd)/plugins/pipeline-core/scripts/batch-orchestrator.sh"

setup() {
	setup_test_env
}

teardown() {
	teardown_test_env
}

# Source the real pr_recovery_allowed() out of the bundled orchestrator.
# Fails loudly when the function is absent so a missing fix reads as a
# named diagnostic instead of "command not found" noise.
_load_recovery_gate() {
	[[ -f "$BUNDLE_ORCHESTRATOR" ]] \
		|| fail "bundled orchestrator not found: $BUNDLE_ORCHESTRATOR"

	local body
	body=$(_extract_function_body pr_recovery_allowed "$BUNDLE_ORCHESTRATOR")
	[[ -n "$body" ]] \
		|| fail "pr_recovery_allowed() not defined in $BUNDLE_ORCHESTRATOR"

	eval "$body"
}

# Write an issue status file shaped like the one the orchestrator leaves
# behind: a terminal state, the stage it stopped on, and (optionally) a PR
# number already recorded under .stages.pr.
_write_issue_status() {
	local out="$1" state="$2" stage="$3" pr="${4:-}"

	if [[ -n "$pr" ]]; then
		jq -n --arg s "$state" --arg cs "$stage" --argjson pr "$pr" \
			'{state: $s, current_stage: $cs,
			  stages: {pr: {pr_number: $pr}}}' > "$out"
	else
		jq -n --arg s "$state" --arg cs "$stage" \
			'{state: $s, current_stage: $cs}' > "$out"
	fi
}

# Run the REAL recovery block lifted out of the bundled process_issue().
#
# The block is extracted verbatim (from its `# Recovery:` comment through the
# `fi` that closes the impl_status guard) and eval'd inside this function, so
# its `local` declarations are legal and the assertions below exercise shipped
# code rather than a restatement of it.
#
# Populates: rec_impl_status, rec_pr_number, rec_impl_error, rec_log
_run_recovery_block() {
	local issue_status_file="$1"

	_load_recovery_gate

	rec_log="$TEST_TMP/recovery.log"
	: > "$rec_log"
	log_warn() { printf '%s\n' "$*" >> "$rec_log"; }
	log_error() { printf '%s\n' "$*" >> "$rec_log"; }

	local block
	block=$(awk '/# Recovery: if the orchestrator exited/,/^        fi$/' \
		"$BUNDLE_ORCHESTRATOR")
	[[ "$block" == *'impl_status'* ]] \
		|| fail "recovery block not extracted from $BUNDLE_ORCHESTRATOR"

	# Preconditions the surrounding process_issue() has already established
	# by the time control reaches the block.
	local impl_status="error" pr_number="" impl_error=""
	local state
	state=$(jq -r '.state' "$issue_status_file")

	eval "$block"

	rec_impl_status="$impl_status"
	rec_pr_number="$pr_number"
	rec_impl_error="$impl_error"
}

# =============================================================================
# AC1 / AC5(a): merge stages are excluded from the gate
# =============================================================================

@test "bundled batch-orchestrator.sh defines pr_recovery_allowed" {
	_load_recovery_gate
	declare -F pr_recovery_allowed > /dev/null \
		|| fail "pr_recovery_allowed was not defined after sourcing"
}

@test "pr_recovery_allowed declines recovery when stuck at merge_pr" {
	_load_recovery_gate
	if pr_recovery_allowed "merge_pr"; then
		fail "merge_pr must not be eligible for PR-exists recovery"
	fi
}

@test "pr_recovery_allowed declines recovery when stuck at merge_pr_timeout" {
	# _handle_merge_pr_timeout sets current_stage to merge_pr_timeout before
	# set_final_state "error" — the merge was never confirmed either way, so
	# crediting it is the same laundering as merge_pr.
	_load_recovery_gate
	if pr_recovery_allowed "merge_pr_timeout"; then
		fail "merge_pr_timeout must not be eligible for PR-exists recovery"
	fi
}

# =============================================================================
# AC2 / AC5(b): the genuine post-PR crash case keeps working
# =============================================================================

@test "pr_recovery_allowed permits recovery when stuck at pr_review" {
	_load_recovery_gate
	pr_recovery_allowed "pr_review" \
		|| fail "pr_review is after pr and before merge_pr — must recover"
}

@test "pr_recovery_allowed permits recovery when stuck at docs" {
	_load_recovery_gate
	pr_recovery_allowed "docs" || fail "docs must remain recoverable"
}

@test "pr_recovery_allowed permits recovery when the stage is unknown" {
	# A crash before current_stage could be read still reaches the heuristic
	# with the "unknown" fallback; that is the original crash case.
	_load_recovery_gate
	pr_recovery_allowed "unknown" || fail "unknown stage must remain recoverable"
}

@test "pr_recovery_allowed permits recovery for a post-merge stage" {
	# complete runs after a successful merge — an exit there is the crash the
	# heuristic was written for.
	_load_recovery_gate
	pr_recovery_allowed "complete" || fail "complete must remain recoverable"
}

# =============================================================================
# FUNCTIONAL: the real recovery block, driven by a real status file
# =============================================================================

@test "recovery block: merge_pr error with an existing PR is NOT recovered" {
	local status_file="$TEST_TMP/issue-status.json"
	_write_issue_status "$status_file" "error" "merge_pr" 5857

	_run_recovery_block "$status_file"

	[[ "$rec_impl_status" == "error" ]] \
		|| fail "impl_status became '$rec_impl_status'; expected 'error'"
}

@test "recovery block: merge_pr error does not log 'recovering as success'" {
	local status_file="$TEST_TMP/issue-status.json"
	_write_issue_status "$status_file" "error" "merge_pr" 5857

	_run_recovery_block "$status_file"

	if grep -q "recovering as success" "$rec_log"; then
		fail "declined recovery still logged 'recovering as success'"
	fi
}

@test "recovery block: merge_pr error records a diagnostic impl_error" {
	# AC3 — the declined recovery must leave a non-terminal/blocked record
	# rather than an empty error, so the batch reports it instead of a green.
	local status_file="$TEST_TMP/issue-status.json"
	_write_issue_status "$status_file" "error" "merge_pr" 5857

	_run_recovery_block "$status_file"

	[[ -n "$rec_impl_error" ]] || fail "impl_error was cleared on decline"
	[[ "$rec_impl_error" == *"merge_pr"* ]] \
		|| fail "impl_error does not name the stage: $rec_impl_error"
}

@test "recovery block: merge_pr error still records the PR number" {
	# The PR is left open and must stay visible in the batch status file even
	# though the issue is not credited as success.
	local status_file="$TEST_TMP/issue-status.json"
	_write_issue_status "$status_file" "error" "merge_pr" 5857

	_run_recovery_block "$status_file"

	[[ "$rec_pr_number" == "5857" ]] \
		|| fail "PR number was dropped: '$rec_pr_number'"
}

@test "recovery block: merge_pr_timeout error with an existing PR is NOT recovered" {
	local status_file="$TEST_TMP/issue-status.json"
	_write_issue_status "$status_file" "error" "merge_pr_timeout" 4242

	_run_recovery_block "$status_file"

	[[ "$rec_impl_status" == "error" ]] \
		|| fail "impl_status became '$rec_impl_status'; expected 'error'"
}

@test "recovery block: post-PR crash with an existing PR is still recovered" {
	local status_file="$TEST_TMP/issue-status.json"
	_write_issue_status "$status_file" "error" "pr_review" 4242

	_run_recovery_block "$status_file"

	[[ "$rec_impl_status" == "success" ]] \
		|| fail "post-PR crash was not recovered: '$rec_impl_status'"
	[[ "$rec_pr_number" == "4242" ]] \
		|| fail "recovered PR number is '$rec_pr_number'; expected 4242"
	[[ -z "$rec_impl_error" ]] \
		|| fail "impl_error survived a successful recovery: $rec_impl_error"
}

@test "recovery block: post-PR crash logs 'recovering as success'" {
	local status_file="$TEST_TMP/issue-status.json"
	_write_issue_status "$status_file" "error" "pr_review" 4242

	_run_recovery_block "$status_file"

	grep -q "recovering as success" "$rec_log" \
		|| fail "post-PR recovery did not log the recovery warning"
}

@test "recovery block: merge_pr error without a PR number is untouched" {
	local status_file="$TEST_TMP/issue-status.json"
	_write_issue_status "$status_file" "error" "merge_pr"

	_run_recovery_block "$status_file"

	[[ "$rec_impl_status" == "error" ]]
	[[ -z "$rec_pr_number" ]]
}

# =============================================================================
# AC3: a declined recovery cannot reach the /process-pr dispatch
# =============================================================================

@test "process-pr dispatch sits after the impl_status != success early return" {
	# Leaving impl_status at "error" is only a safe decline if the dispatch is
	# downstream of the guard that returns on a non-success status.
	local guard_line dispatch_line
	guard_line=$(grep -n '"$impl_status" != "success"' \
		"$BUNDLE_ORCHESTRATOR" | head -1 | cut -d: -f1)
	dispatch_line=$(grep -n 'Running: claude -p .*process-pr' \
		"$BUNDLE_ORCHESTRATOR" | head -1 | cut -d: -f1)

	[[ -n "$guard_line" ]] || fail "impl_status != success guard not found"
	[[ -n "$dispatch_line" ]] || fail "process-pr dispatch not found"
	(( dispatch_line > guard_line )) \
		|| fail "process-pr dispatch ($dispatch_line) precedes the guard ($guard_line)"
}
