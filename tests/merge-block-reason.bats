#!/usr/bin/env bats
#
# tests/merge-block-reason.bats
# Coverage for issue #824: a red test suite is misreported as missing file
# evidence.
#
# reconcile_failed_tasks_with_branch_evidence() (implement-issue-orchestrator.sh)
# refuses to promote ANY failed task while the test suite is red this run —
# a deliberate guard. _lacking_evidence_summary()'s header comment claims
# every task still "failed" after reconciliation is a genuine gap, but that
# invariant is false whenever tests_green=0: reconciliation short-circuits
# before ever checking branch evidence, so a task whose files ARE on the
# branch is still reported as "lacking file evidence" — blaming the wrong
# cause and sending the operator to investigate a missing-work problem that
# does not exist.
#
# revalidate_partial_block_against_branch() is the gate-time re-evaluation
# that builds the persisted merge_blocked_reason from these two functions'
# output immediately before the merge gate reads its verdict — the exact
# path named by the issue (implement-issue-orchestrator.sh:L5869-5882).
#
# These tests source the real orchestrator functions (the same
# helpers/test-helper.bash idiom used by
# .claude/scripts/implement-issue-test/test-convergence-gate.bats) so they
# exercise the shipped fix, not a mirror of it. They fail RED until the
# sibling tasks on this issue land the fix in
# implement-issue-orchestrator.sh; that is expected — this file's job is
# CI-gated coverage of the corrected behavior, not a description of the
# code as it stands before the fix merges.
#

load '../.claude/scripts/implement-issue-test/helpers/test-helper.bash'

setup() {
	setup_test_env

	export ISSUE_NUMBER=824
	export BASE_BRANCH=base
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0

	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

	ORCHESTRATOR_START_EPOCH=$(date +%s)
	DEGRADED_STAGES=()

	source_orchestrator_functions
	init_status

	# Real git repo standing in for the feature/base branch pair
	# revalidate_partial_block_against_branch() diffs against.
	git init -q .
	git config user.email test@example.com
	git config user.name "Test"
	git commit -q --allow-empty -m "base"
	git branch -q "$BASE_BRANCH"
	git checkout -q -b feature
}

teardown() {
	teardown_test_env
}

# =============================================================================
# AC1: a red test suite names the red suite, not missing file evidence — even
# when the failed task's declared files ARE present on the branch, which is
# exactly the scenario reconcile_failed_tasks_with_branch_evidence() short-
# circuits on and _lacking_evidence_summary() cannot distinguish from a
# genuine gap.
# =============================================================================

@test "AC1: red full-suite (jest) marker — reason names the red suite, not lacking file evidence" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "failed", affected_files: ["src/one.sh"]}
	]')
	set_tasks "$tasks_json"

	# The task's deliverable IS on the branch — if evidence were evaluated it
	# would reconcile. It must not be evaluated at all while tests are red.
	mkdir -p src
	echo "one" > src/one.sh
	git add src
	git commit -q -m "task one landed"

	DEGRADED_STAGES=("test:full_suite_red")

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local status1
	status1=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	expect_glob "$status1" 'failed' \
		"a red suite must not promote the task even though its files are on the branch"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_glob "$reason" 'Partial implementation: 0/1 tasks completed*' \
		"reason must keep the Partial implementation: prefix with the branch-verified count"
	expect_ok "reason must not blame missing file evidence when the cause is a red suite" \
		bash -c '[[ "$1" != *"lacking file evidence"* ]]' _ "$reason"
	expect_ok "reason must name the red test suite as the cause" \
		bash -c '[[ "$1" == *[Tt]est*[Ss]uite*[Rr]ed* || "$1" == *[Rr]ed*[Tt]est*[Ss]uite* ]]' _ "$reason"
}

@test "AC1: red full-suite (bats) marker — reason names the red suite, not lacking file evidence" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "failed", affected_files: ["src/one.sh"]},
		{id: 2, description: "task two", status: "completed", affected_files: ["src/two.sh"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p src
	echo "one" > src/one.sh
	echo "two" > src/two.sh
	git add src
	git commit -q -m "both tasks landed"

	DEGRADED_STAGES=("test:bats_full_suite_red")

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_ok "reason must not blame missing file evidence when the cause is a red BATS suite" \
		bash -c '[[ "$1" != *"lacking file evidence"* ]]' _ "$reason"
	expect_ok "reason must name the red test suite as the cause" \
		bash -c '[[ "$1" == *[Tt]est*[Ss]uite*[Rr]ed* || "$1" == *[Rr]ed*[Tt]est*[Ss]uite* ]]' _ "$reason"
}

@test "AC1: red suite plus a task with no branch evidence at all — still no lacking-file-evidence claim" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "never landed", status: "failed", affected_files: ["docs/missing.md"]}
	]')
	set_tasks "$tasks_json"

	DEGRADED_STAGES=("test:full_suite_red")

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_ok "a red suite is the reported cause even when the task also lacks evidence" \
		bash -c '[[ "$1" != *"lacking file evidence"* ]]' _ "$reason"
}

# =============================================================================
# AC2: tests green + a genuine gap — the reason still names the specific task
# lacking file evidence (regression guard: the AC1 fix must not blank out the
# real-gap wording it needs to keep).
# =============================================================================

@test "AC2: tests green, one task genuinely missing evidence — reason still reads lacking file evidence: task N" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "version field", status: "failed", affected_files: ["marketplace.json"]},
		{id: 2, description: "README install section", status: "failed", affected_files: ["README.md"]}
	]')
	set_tasks "$tasks_json"

	DEGRADED_STAGES=()

	# Only task 1's file lands; README.md is a genuine, unevidenced gap.
	echo '{"version": "0.3.0"}' > marketplace.json
	git add marketplace.json
	git commit -q -m "implement task 1 only"

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local status1 status2
	status1=$(jq -r '(.tasks[] | select(.id == 1)).status' "$STATUS_FILE")
	status2=$(jq -r '(.tasks[] | select(.id == 2)).status' "$STATUS_FILE")
	expect_glob "$status1" 'completed' "task 1's evidenced deliverable reconciles"
	expect_glob "$status2" 'failed' "task 2's genuine gap survives reconciliation"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_glob "$reason" 'Partial implementation: 1/2 tasks completed*' \
		"reason must lead with the branch-verified count"
	expect_glob "$reason" '*lacking file evidence: task 2 (README install section)*' \
		"a genuine gap with tests green must still be reported as lacking file evidence"
}

# =============================================================================
# AC3: the reason keeps its "Partial implementation:" prefix in both the
# red-suite and the genuine-gap case, since the status-file jq guards that
# clear/preserve a persisted reason match on that literal prefix.
# =============================================================================

@test "AC3: red-suite reason keeps the Partial implementation: prefix" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "task one", status: "failed", affected_files: ["src/one.sh"]}
	]')
	set_tasks "$tasks_json"

	mkdir -p src
	echo "one" > src/one.sh
	git add src
	git commit -q -m "task one landed"

	DEGRADED_STAGES=("test:full_suite_red")

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_glob "$reason" 'Partial implementation:*' \
		"the red-suite reason must still start with Partial implementation:"

	# A subsequent gate-time re-run must still recognize + rewrite this
	# reason (the jq guard in revalidate_partial_block_against_branch keys on
	# this exact prefix) rather than treating it as an unrelated persisted
	# reason it must never clobber.
	DEGRADED_STAGES=("test:full_suite_red")
	revalidate_partial_block_against_branch "$BASE_BRANCH"
	local reason2
	reason2=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_glob "$reason2" 'Partial implementation:*' \
		"the prefix must survive a second gate-time re-evaluation pass"
}

@test "AC3: genuine-gap reason keeps the Partial implementation: prefix" {
	local tasks_json
	tasks_json=$(jq -n '[
		{id: 1, description: "README install section", status: "failed", affected_files: ["README.md"]}
	]')
	set_tasks "$tasks_json"

	DEGRADED_STAGES=()

	revalidate_partial_block_against_branch "$BASE_BRANCH"

	local reason
	reason=$(jq -r '.merge_blocked_reason // ""' "$STATUS_FILE")
	expect_glob "$reason" 'Partial implementation:*' \
		"the genuine-gap reason must still start with Partial implementation:"
}

# =============================================================================
# AC4: _lacking_evidence_summary()'s header comment must no longer assert,
# unconditionally, that every task still "failed" after reconciliation is a
# genuine gap — that invariant is false on the red-suite short-circuit path
# this issue fixes.
# =============================================================================

@test "AC4: _lacking_evidence_summary() header no longer states the unconditional promoted-everything invariant" {
	local doc doc_flat
	doc=$(sed -n '/^# _lacking_evidence_summary() —/,/^_lacking_evidence_summary() {/p' \
		"$ORCHESTRATOR_SCRIPT")

	[[ -n "$doc" ]] || fail "could not locate _lacking_evidence_summary() header comment"

	# Comment lines wrap at 80 columns, so the stale sentence spans a line
	# break ("...is\n# a genuine gap."). Strip the leading "# " from each
	# line and collapse to single spaces before matching, so the check is
	# robust to re-wrapping and only cares about the words themselves.
	doc_flat=$(sed -E 's/^#[[:space:]]?//' <<< "$doc" | tr '\n' ' ' | tr -s ' ')

	[[ "$doc_flat" != *'has already promoted every task it could find evidence for — any task still "failed" at that point is a genuine gap.'* ]] || {
		printf 'FAIL: header comment still states the invariant the red-suite path violates:\n%s\n' \
			"$doc" >&2
		return 1
	}
}
