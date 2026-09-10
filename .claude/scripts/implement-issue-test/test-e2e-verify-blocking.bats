#!/usr/bin/env bats
#
# test-e2e-verify-blocking.bats
# Tests for issue #872 Gate C: refuse to auto-merge a PR that adds or
# changes an E2E spec while e2e_verify is degraded — i.e. while no run on
# the branch has reported a single test executing.
#
# Before this gate, "degraded" was purely informational: the run continued
# to pr / merge_pr regardless, so five consecutive PRs on a consumer repo
# shipped a brand-new Playwright spec whose first execution anywhere was
# that repo's own CI, ~25 minutes after the PR opened. Every one failed
# there on environment facts one local run would have exposed.
#
# Mirrors test-merge-block-convergence.bats / test-merge-block-partial.bats
# idioms, with one deliberate difference: the gate decision lives in a real
# orchestrator function (_e2e_verify_merge_block_reason) rather than inline
# in main(), so the functional tests below call the SHIPPING code instead of
# re-implementing the scan in the test.
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env

	export ISSUE_NUMBER=123
	export BASE_BRANCH=test
	export STATUS_FILE="$TEST_TMP/status.json"
	export LOG_BASE="$TEST_TMP/logs/test"
	export LOG_FILE="$LOG_BASE/orchestrator.log"
	export STAGE_COUNTER=0

	mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

	ORCHESTRATOR_START_EPOCH=$(date +%s)
	DEGRADED_STAGES=()

	source_orchestrator_functions
	init_status
}

teardown() {
	teardown_test_env
}

# =============================================================================
# FUNCTIONAL: the shipping gate decision
# =============================================================================

@test "gate blocks when this run recorded the e2e blocking marker" {
	unset E2E_VERIFY_BLOCKING
	DEGRADED_STAGES=(
		"e2e_verify:unmeasured:initial"
		"e2e_verify:blocking:spec_changed"
	)

	local reason=""
	expect_ok "the gate must fire on the blocking marker" \
		_e2e_verify_merge_block_reason
	reason=$(_e2e_verify_merge_block_reason)

	expect_glob "$reason" '*e2e_verify*' \
		"the block reason must name the stage that failed the gate"
	expect_glob "$reason" '*e2e_verify:blocking:spec_changed*' \
		"the block reason must cite the degraded_stages entry"
}

@test "gate stays open on a clean run" {
	unset E2E_VERIFY_BLOCKING
	DEGRADED_STAGES=()

	expect_not_ok "no marker means no block" \
		_e2e_verify_merge_block_reason
}

# The narrowing that keeps this gate honest: an e2e_verify that came back
# unmeasured on a branch that changed NO spec still records
# e2e_verify:unmeasured (issue #745/#763) and must still merge. Only the
# spec-changed marker blocks.
@test "gate ignores a bare unmeasured marker with no spec change" {
	unset E2E_VERIFY_BLOCKING
	DEGRADED_STAGES=("e2e_verify:unmeasured:initial")

	expect_not_ok "an unmeasured run on a non-spec diff must not block" \
		_e2e_verify_merge_block_reason
}

@test "gate ignores unrelated degraded markers" {
	unset E2E_VERIFY_BLOCKING
	DEGRADED_STAGES=(
		"test:bats_incomplete:iter=1"
		"quality:max_iterations:review:iter=5"
	)

	expect_not_ok "unrelated markers must not fire the e2e gate" \
		_e2e_verify_merge_block_reason
}

# AC3, opt-out half: with E2E_VERIFY_BLOCKING=0 the behaviour is exactly
# what it was before this issue — degraded, and merged anyway.
@test "E2E_VERIFY_BLOCKING=0 restores the pre-#872 merge-anyway behaviour" {
	export E2E_VERIFY_BLOCKING=0
	DEGRADED_STAGES=(
		"e2e_verify:unmeasured:initial"
		"e2e_verify:blocking:spec_changed"
	)

	expect_not_ok "the opt-out must disable the gate entirely" \
		_e2e_verify_merge_block_reason
}

@test "E2E_VERIFY_BLOCKING defaults to on when unset or empty" {
	DEGRADED_STAGES=("e2e_verify:blocking:spec_changed")

	unset E2E_VERIFY_BLOCKING
	expect_ok "an unset opt-out must leave the gate armed" \
		_e2e_verify_merge_block_reason

	export E2E_VERIFY_BLOCKING=""
	expect_ok "an empty opt-out must leave the gate armed" \
		_e2e_verify_merge_block_reason

	export E2E_VERIFY_BLOCKING=1
	expect_ok "an explicit 1 must leave the gate armed" \
		_e2e_verify_merge_block_reason
}

# =============================================================================
# WIRING: the merge stage actually consults the gate, and acts on it
# =============================================================================

@test "the merge stage consults the gate before invoking merge-mr.sh" {
	local gate_pos merge_pos
	gate_pos=$(grep -n '_e2e_verify_merge_block_reason)' \
		"$ORCHESTRATOR_SCRIPT" | tail -1 | cut -d: -f1)
	merge_pos=$(grep -n 'merge-mr.sh' \
		"$ORCHESTRATOR_SCRIPT" | tail -1 | cut -d: -f1)

	expect_glob "${gate_pos:-<none>}" '[0-9]*' \
		"the merge stage must call _e2e_verify_merge_block_reason"
	expect_ok "the gate must be consulted before the merge command" \
		test "$gate_pos" -lt "$merge_pos"
}

@test "the e2e block branch leaves the PR open as merge_blocked and exits 0" {
	# Capture the Gate C handler: from its own `if` down to the exit that
	# ends it. Asserting on the extracted branch rather than the whole
	# file means a match cannot be satisfied by some other gate's text.
	local branch
	branch=$(awk '
		/if \[\[ "\$merge_block_kind" == "e2e" \]\]; then/ { capture = 1 }
		capture { print }
		capture && /^ *exit 0$/ { exit }
	' "$ORCHESTRATOR_SCRIPT")

	expect_glob "$branch" '*set_final_state "merge_blocked"*' \
		"the e2e gate must record the merge_blocked final state"
	expect_glob "$branch" '*exit 0*' \
		"the e2e gate must exit 0 (PR left open, not an error)"
	expect_glob "$branch" '*comment_pr "$pr_number"*' \
		"the e2e gate must comment on the PR it left open"
	expect_glob "$branch" '*e2e_verify*' \
		"the PR comment must name the stage that blocked the merge"
	expect_glob "$branch" '*E2E_VERIFY_BLOCKING=0*' \
		"the PR comment must tell the operator how to override this gate"
}

@test "the e2e gate never merges: no merge command inside its branch" {
	local branch
	branch=$(awk '
		/if \[\[ "\$merge_block_kind" == "e2e" \]\]; then/ { capture = 1 }
		capture { print }
		capture && /^ *exit 0$/ { exit }
	' "$ORCHESTRATOR_SCRIPT")

	if [[ "$branch" == *'merge-mr.sh'* ]]; then
		printf 'FAIL: the e2e block branch must not invoke a merge\n' >&2
		exit 1
	fi
}

# The gate is evaluated last so it cannot displace a convergence or partial
# reason — both describe a broader failure and carry their own final states
# (merge_blocked / completed_partial with exit 2).
@test "the e2e gate is evaluated only when no earlier gate blocked" {
	local guard
	guard=$(awk '
		/# Gate C — e2e_verify never executed/ { capture = 1 }
		capture { print }
		capture && /if _e2e_block_reason=/ { exit }
	' "$ORCHESTRATOR_SCRIPT")

	expect_glob "$guard" '*if \[\[ -z "$merge_blocked_reason" \]\]*' \
		"Gate C must only run when no earlier gate set a reason"
}

# =============================================================================
# WIRING: the marker the gate reads is actually produced by the stage
# =============================================================================

@test "run_parallel_post_task_stages records the marker the gate scans for" {
	# Capture the record block itself, not the whole file: a bare grep for
	# the marker string still matches after the block is guarded off with
	# `if false`, which is exactly the regression this test is here for.
	local record_block
	record_block=$(awk '
		/# Issue #872 — E2E BLOCKING MARKER/ { capture = 1 }
		capture { print }
		capture && /e2e_verify:blocking:spec_changed/ { exit }
	' "$ORCHESTRATOR_SCRIPT")

	expect_glob "$record_block" '*"e2e_verify:blocking:spec_changed"*' \
		"the stage must append the exact marker the gate matches"
	expect_glob "$record_block" '*if $run_e2e && $_e2e_spec_changed; then*' \
		"the marker must be recorded when the stage ran on a spec-changing diff"
	expect_glob "$record_block" '*e2e_verify:unmeasured*' \
		"the marker must be conditional on this run's degraded verdict"
}
