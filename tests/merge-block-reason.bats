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
# branch is still reported as "lacking evidence" — blaming the wrong
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

@test "AC1: red full-suite (jest) marker — reason names the red suite, not lacking evidence" {
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
		bash -c '[[ "$1" != *"lacking evidence"* ]]' _ "$reason"
	expect_ok "reason must name the red test suite as the cause" \
		bash -c '[[ "$1" == *[Tt]est*[Ss]uite*[Rr]ed* || "$1" == *[Rr]ed*[Tt]est*[Ss]uite* ]]' _ "$reason"
}

@test "AC1: red full-suite (bats) marker — reason names the red suite, not lacking evidence" {
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
		bash -c '[[ "$1" != *"lacking evidence"* ]]' _ "$reason"
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
		bash -c '[[ "$1" != *"lacking evidence"* ]]' _ "$reason"
}

# =============================================================================
# AC2: tests green + a genuine gap — the reason still names the specific task
# lacking evidence (regression guard: the AC1 fix must not blank out the
# real-gap wording it needs to keep).
# =============================================================================

@test "AC2: tests green, one task genuinely missing evidence — reason still names the task and its evidence kind" {
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
	expect_glob "$reason" '*lacking evidence: task 2 (README install section) \[file evidence: README.md\]*' \
		"a genuine gap with tests green must still name the task and the evidence kind applied (#840 AC3)"
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

# =============================================================================
# Issue #1006: the batch's wait-for-merge park must not start for a PR held
# open BY CONFIGURATION (merge_block_kind == "manual"), but must still start
# for the incidental kinds (convergence | partial | e2e) — the #861 protection.
#
# These drive the real wait_for_pr_merged() extracted out of
# batch-orchestrator.sh. merge_block_kind is seeded where the inner
# orchestrator persists it — the per-issue status file the batch already reads
# for .pr — rather than re-derived from log text.
# =============================================================================

_load_park_functions() {
	local script="$BATS_TEST_DIRNAME/../.claude/scripts/batch-orchestrator.sh" fn body
	for fn in set_state set_paused_on_pr comment_paused_on_pr \
		pr_merge_state wait_for_pr_merged; do
		body=$(_extract_function_body "$fn" "$script")
		[[ -n "$body" ]] || fail "$fn() not defined in batch-orchestrator.sh"
		eval "$body"
	done
	log() { printf '%s\n' "$*" >> "$TEST_TMP/batch.log"; }
	log_warn() { printf '%s\n' "$*" >> "$TEST_TMP/batch.log"; }
	log_error() { printf '%s\n' "$*" >> "$TEST_TMP/batch.log"; }
	timeout() { shift; "$@"; }
	# Count sleeps through a file: wait_for_pr_merged runs under `run` (a
	# subshell), so a counter variable would not survive.
	sleep() { printf 'x\n' >> "$TEST_TMP/sleeps.log"; }
	: > "$TEST_TMP/batch.log"
	: > "$TEST_TMP/sleeps.log"
}

# Seeds batch status.json (issue 1006 carrying PR 4321) and the per-issue
# status file with the given merge_block_kind; the PR stays OPEN forever.
_seed_blocked_issue() {
	local kind="$1"
	jq -n '{state: "running",
		issues: [{number: "1006", status: "merge_blocked", pr: "4321"}],
		progress: {total: 1, completed: 0, pending: 0, failed: 0}}' \
		> "$STATUS_FILE"
	jq -n --arg kind "$kind" '{state: "merge_blocked", merge_block_kind: $kind,
		stages: {pr: {pr_number: "4321"}}}' \
		> "$LOG_BASE/issue-1006-status.json"

	mkdir -p "$TEST_TMP/bin" "$TEST_TMP/platform"
	cat > "$TEST_TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo OPEN
STUB
	chmod +x "$TEST_TMP/bin/gh"
	PATH="$TEST_TMP/bin:$PATH"
	export PLATFORM_DIR="$TEST_TMP/platform"
	printf '#!/usr/bin/env bash\nexit 0\n' > "$PLATFORM_DIR/comment-issue.sh"
	chmod +x "$PLATFORM_DIR/comment-issue.sh"

	export BATCH_WAIT_FOR_MERGE_MAX=100 BATCH_WAIT_FOR_MERGE_INTERVAL=1
}

@test "#1006 AC1: a manual hold starts no wait-for-merge poll and never pauses the batch" {
	_load_park_functions
	_seed_blocked_issue manual

	run wait_for_pr_merged 1006

	local sleeps
	sleeps=$(grep -c . "$TEST_TMP/sleeps.log" || true)
	[[ "$sleeps" -eq 0 ]] \
		|| fail "manual hold polled $sleeps time(s) — the park must not start"
	if grep -q 'pausing the batch' "$TEST_TMP/batch.log"; then
		fail "manual hold logged the park start: $(cat "$TEST_TMP/batch.log")"
	fi
	[[ "$(jq -r .state "$STATUS_FILE")" != "paused_on_pr" ]] \
		|| fail "manual hold set state paused_on_pr"
}

@test "#1006 AC3: an incidental block (convergence) still parks and polls" {
	_load_park_functions
	_seed_blocked_issue convergence

	run wait_for_pr_merged 1006

	# PR never merges, so the park runs to its ceiling and reports timeout.
	[[ "$status" -eq 1 ]] \
		|| fail "convergence block did not run the park to timeout (rc=$status)"
	local sleeps
	sleeps=$(grep -c . "$TEST_TMP/sleeps.log" || true)
	[[ "$sleeps" -gt 0 ]] || fail "convergence block never polled"
	grep -q 'pausing the batch' "$TEST_TMP/batch.log" \
		|| fail "convergence block did not log the park start"
	[[ "$(jq -r .state "$STATUS_FILE")" == "paused_on_pr" ]] \
		|| fail "convergence block did not set state paused_on_pr"
}

@test "#1006 AC3: partial and e2e blocks also still park exactly as before" {
	local kind
	for kind in partial e2e; do
		_load_park_functions
		_seed_blocked_issue "$kind"

		run wait_for_pr_merged 1006
		[[ "$status" -eq 1 ]] \
			|| fail "$kind block did not run the park to timeout (rc=$status)"
		grep -q 'pausing the batch' "$TEST_TMP/batch.log" \
			|| fail "$kind block did not start the park"
	done
}

# =============================================================================
# #1007: a failed container rebuild/health check must reach Gate C.
#
# The e2e_verify subshell exits 1 on a rebuild failure. Gate C only fires on
# an e2e_verify:blocking:* marker, which is derived from the unmeasured
# marker file the subshell writes — so the rebuild-failure branch has to
# write that file, or the PR merges with the gate silent. These drive the
# real run_parallel_post_task_stages() and then the real gate function.
# =============================================================================

# Mock the collaborators run_parallel_post_task_stages() shells out to, and
# put a changed E2E spec on the feature branch so Gate C is armed.
_arm_e2e_stage() {
	mkdir -p tests/e2e
	echo "test('x', () => {});" > tests/e2e/new.spec.ts
	git add tests/e2e/new.spec.ts
	git commit -q -m "add e2e spec"

	is_stage_completed() { return 1; }
	set_stage_started() { true; }
	set_stage_completed() { true; }
	log() { true; }
	log_error() { true; }
	log_warn() { true; }
	comment_issue() { true; }
	verify_on_feature_branch() { return 0; }
	_build_targeted_e2e_cmd() { printf '%s' "echo run-e2e"; }
	run_stage() {
		printf '%s' '{"status":"success","result":"passed","summary":"ok","output":{"tests_run":3,"tests_passed":3,"tests_failed":0}}'
	}

	export TEST_E2E_CMD="echo run-e2e"
	export TEST_E2E_PATH_PATTERNS='tests/e2e/*'
	export RESUME_MODE=""
	unset E2E_CONTAINER_REBUILD E2E_VERIFY_BLOCKING
	DEGRADED_STAGES=()
}

@test "#1007: a rebuild failure records the unmeasured and blocking markers and Gate C fires" {
	_arm_e2e_stage
	rebuild_and_health_check() {
		printf '{"rebuild":"failed","health":"unreachable"}'
		return 1
	}

	run_parallel_post_task_stages "feature" "frontend" "standard" "M"

	local joined
	joined=$(printf '%s\n' "${DEGRADED_STAGES[@]+"${DEGRADED_STAGES[@]}"}")
	[[ "$joined" == *"e2e_verify:unmeasured"* ]] \
		|| fail "rebuild failure left no unmeasured marker: $joined"
	[[ "$joined" == *"e2e_verify:blocking:spec_changed"* ]] \
		|| fail "rebuild failure left no blocking marker: $joined"

	local reason rc=0
	reason=$(_e2e_verify_merge_block_reason) || rc=$?
	[[ "$rc" -eq 0 ]] || fail "Gate C did not block after a rebuild failure"
	[[ "$reason" == *"never executed"* ]] \
		|| fail "Gate C reason does not describe the unexecuted spec: $reason"
}

@test "#1007: a clean e2e run on a spec-changing diff leaves Gate C silent" {
	_arm_e2e_stage
	rebuild_and_health_check() {
		printf '{"rebuild":"success","health":"healthy"}'
	}

	run_parallel_post_task_stages "feature" "frontend" "standard" "M"

	local joined
	joined=$(printf '%s\n' "${DEGRADED_STAGES[@]+"${DEGRADED_STAGES[@]}"}")
	[[ "$joined" != *"e2e_verify:unmeasured"* ]] \
		|| fail "clean run recorded an unmeasured marker: $joined"
	[[ "$joined" != *"e2e_verify:blocking"* ]] \
		|| fail "clean run recorded a blocking marker: $joined"

	local rc=0
	_e2e_verify_merge_block_reason >/dev/null || rc=$?
	[[ "$rc" -eq 1 ]] || fail "Gate C blocked a clean run (rc=$rc)"
}

@test "#1007: E2E_VERIFY_BLOCKING=0 still opts a rebuild failure out of Gate C" {
	_arm_e2e_stage
	rebuild_and_health_check() {
		printf '{"rebuild":"failed","health":"unreachable"}'
		return 1
	}
	export E2E_VERIFY_BLOCKING=0

	run_parallel_post_task_stages "feature" "frontend" "standard" "M"

	local rc=0
	_e2e_verify_merge_block_reason >/dev/null || rc=$?
	[[ "$rc" -eq 1 ]] || fail "opt-out ignored for a rebuild failure (rc=$rc)"
}

# A subshell that exits non-zero without writing any marker must still be
# recorded as unmeasured by the parent, not just log_warn'd.
@test "#1007: a markerless non-zero e2e subshell exit is recorded as unmeasured" {
	_arm_e2e_stage
	export E2E_CONTAINER_REBUILD=false
	# Crash only inside the backgrounded subshell (BASHPID != $$).
	log() { if [[ "$BASHPID" != "$$" ]]; then exit 9; fi; true; }

	run_parallel_post_task_stages "feature" "frontend" "standard" "M"

	local joined
	joined=$(printf '%s\n' "${DEGRADED_STAGES[@]+"${DEGRADED_STAGES[@]}"}")
	[[ "$joined" == *"e2e_verify:unmeasured"* ]] \
		|| fail "markerless crash left no unmeasured marker: $joined"
	[[ "$joined" == *"e2e_verify:blocking:spec_changed"* ]] \
		|| fail "markerless crash left no blocking marker: $joined"
}
