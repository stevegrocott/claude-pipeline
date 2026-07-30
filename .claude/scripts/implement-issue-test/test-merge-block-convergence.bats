#!/usr/bin/env bats
#
# test-merge-block-convergence.bats
# Tests for merge blocking on quality:convergence_failure degradation
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
# STATIC ANALYSIS: DEGRADED_STAGES recording at convergence failure
# =============================================================================

@test "convergence-failure handler appends quality:convergence_failure entry to DEGRADED_STAGES" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# The exact DEGRADED_STAGES entry written in the >33% repeats branch
	[[ "$script_content" == *'DEGRADED_STAGES+=("quality:convergence_failure:$stage_prefix:iter=$loop_iteration")'* ]]
}

@test "quality-loop convergence branch calls set_final_state convergence_failure_quality" {
	# AC2: set_final_state "convergence_failure_quality" must be called in the
	# >33%-repeats branch so status.json reflects the convergence failure.
	# The merge stage overwrites it with "merge_blocked" if auto-merge is blocked.
	local conv_block
	conv_block=$(awk \
		'/if \(\( repeat_ratio > 33 \)\); then/,/loop_approved=true/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)
	[[ "$conv_block" == *'set_final_state "convergence_failure_quality"'* ]]
}

# =============================================================================
# STATIC ANALYSIS: merge_blocked_reason persistence at convergence failure
# =============================================================================

@test "convergence failure handler persists merge_blocked_reason to status.json" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# After adding to DEGRADED_STAGES, the script must write merge_blocked_reason
	[[ "$script_content" == *'merge_blocked_reason'* ]]
}

@test "convergence failure writes merge_blocked_reason via jq --arg" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'.merge_blocked_reason = $reason'* ]]
}

@test "merge_blocked_reason includes repeat_ratio and stage context" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Block reason must embed the ratio and stage prefix
	[[ "$script_content" == *'${repeat_ratio}% of issues repeating at $stage_prefix'* ]]
}

@test "merge_blocked_reason includes repeating issues when present" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# The block reason should include the repeat_issues text
	[[ "$script_content" == *'Repeating issues:'* ]]
}

# =============================================================================
# STATIC ANALYSIS: BLOCK_MERGE_ON_CONVERGENCE_FAILURE gate in merge stage
# =============================================================================

@test "merge stage checks BLOCK_MERGE_ON_CONVERGENCE_FAILURE env var" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1'* ]]
}

@test "BLOCK_MERGE_ON_CONVERGENCE_FAILURE defaults to 1 (blocking enabled)" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Default must be 1, not 0
	[[ "$script_content" == *'BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1'* ]]
	[[ "$script_content" != *'BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-0'* ]]
}

@test "merge stage reads merge_blocked_reason from status.json" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'.merge_blocked_reason // empty'* ]]
}

@test "merge stage falls back to scanning DEGRADED_STAGES array" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Fallback loop checks entries starting with quality:convergence_failure:
	[[ "$script_content" == *'quality:convergence_failure:*'* ]]
}

@test "merge stage calls comment_pr when merge is blocked" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'Merge Blocked — Unresolved Quality Feedback'* ]]
}

@test "merge stage sets final state to merge_blocked when blocked" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'set_final_state "merge_blocked"'* ]]
}

@test "merge stage exits 0 (not error) when merge is blocked" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Blocked merge must exit 0 (leave PR open, not fail the pipeline).
	# Find the line number of set_final_state "merge_blocked", then check
	# that the next exit statement in the same block is exit 0.
	local block_pos next_exit
	block_pos=$(grep -n 'set_final_state "merge_blocked"' <<< "$script_content" \
		| tail -1 | cut -d: -f1)
	next_exit=$(awk "NR>$block_pos && /exit [0-9]/{ print; exit }" <<< "$script_content")
	[[ "$next_exit" == *'exit 0'* ]]
}

@test "merge stage block check precedes merge-mr.sh call" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# BLOCK_MERGE_ON_CONVERGENCE_FAILURE check must appear before merge-mr.sh
	local block_pos merge_pos
	block_pos=$(grep -n 'BLOCK_MERGE_ON_CONVERGENCE_FAILURE' <<< "$script_content" \
		| tail -1 | cut -d: -f1)
	merge_pos=$(grep -n 'merge-mr.sh' <<< "$script_content" \
		| tail -1 | cut -d: -f1)

	(( block_pos < merge_pos ))
}

@test "merge stage logs bypass message when BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 — skipping merge-block check'* ]]
}

# =============================================================================
# FUNCTIONAL: merge_blocked_reason written to status.json
# =============================================================================

@test "status.json gains merge_blocked_reason when jq command is run" {
	# Simulate what the convergence failure handler does
	local block_reason="Quality loop convergence failure: 75% of issues repeating at main (iter=3)"
	jq --arg reason "$block_reason" \
		'.merge_blocked_reason = $reason | .last_update = (now | todate)' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local stored
	stored=$(jq -r '.merge_blocked_reason' "$STATUS_FILE")
	[[ "$stored" == "$block_reason" ]]
}

@test "status.json merge_blocked_reason includes repeating issues" {
	local block_reason
	block_reason=$(printf 'Quality loop convergence failure: 60%% of issues repeating at pre-commit (iter=2)\nRepeating issues:\n- Missing null check\n- Unused import')
	jq --arg reason "$block_reason" \
		'.merge_blocked_reason = $reason' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local stored
	stored=$(jq -r '.merge_blocked_reason' "$STATUS_FILE")
	[[ "$stored" == *"Repeating issues"* ]]
}

# =============================================================================
# FUNCTIONAL: merge stage block check logic
# =============================================================================

@test "blocked_reason is read from merge_blocked_reason field in status.json" {
	# Write a merge_blocked_reason to status.json
	jq '.merge_blocked_reason = "test block reason"' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local blocked_reason
	blocked_reason=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null)
	[[ "$blocked_reason" == "test block reason" ]]
}

@test "DEGRADED_STAGES fallback detects quality:convergence_failure entry" {
	declare -a test_stages=("quality:max_iterations:main:iter=5" \
		"quality:convergence_failure:main:iter=3")

	local blocked_reason=""
	local _ds
	for _ds in "${test_stages[@]}"; do
		if [[ "$_ds" == quality:convergence_failure:* ]]; then
			blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
			break
		fi
	done

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"quality:convergence_failure:main:iter=3"* ]]
}

@test "DEGRADED_STAGES fallback returns empty when no convergence failure present" {
	declare -a test_stages=("quality:max_iterations:main:iter=5" \
		"test:max_iterations:iter=7")

	local blocked_reason=""
	local _ds
	for _ds in "${test_stages[@]}"; do
		if [[ "$_ds" == quality:convergence_failure:* ]]; then
			blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
			break
		fi
	done

	[[ -z "$blocked_reason" ]]
}

@test "BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 disables block check" {
	export BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0

	# Even with a blocked reason in status.json, setting the flag to 0
	# should bypass the check
	jq '.merge_blocked_reason = "should be ignored"' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	# The gate: if flag is 0, skip reading blocked_reason
	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" != "0" ]]; then
		blocked_reason=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null)
	fi

	[[ -z "$blocked_reason" ]]
}

@test "BLOCK_MERGE_ON_CONVERGENCE_FAILURE=1 enables block check by default" {
	# Unset so the default kicks in
	unset BLOCK_MERGE_ON_CONVERGENCE_FAILURE

	jq '.merge_blocked_reason = "block is active"' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" != "0" ]]; then
		blocked_reason=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null)
	fi

	[[ "$blocked_reason" == "block is active" ]]
}

# =============================================================================
# FUNCTIONAL: merge stage skipped when merge_blocked_reason is set
# =============================================================================

@test "merge stage gate returns blocked_reason when merge_blocked_reason in status.json" {
	# Simulate the merge gate: with BLOCK_MERGE_ON_CONVERGENCE_FAILURE=1 (default)
	# and merge_blocked_reason persisted in status.json, the gate must return a
	# non-empty blocked_reason — meaning merge-mr.sh would be skipped.
	jq --arg r "Quality loop convergence failure: 75% of issues repeating at pre-commit (iter=2)" \
		'.merge_blocked_reason = $r' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	unset BLOCK_MERGE_ON_CONVERGENCE_FAILURE  # ensure default (1) is used

	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" != "0" ]]; then
		blocked_reason=$(jq -r '.merge_blocked_reason // empty' \
			"$STATUS_FILE" 2>/dev/null)
	fi

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"pre-commit"* ]]
}

@test "merge stage gate skips merge-mr.sh when DEGRADED_STAGES has convergence entry and no status.json field" {
	# Fallback path: no merge_blocked_reason in status.json but DEGRADED_STAGES
	# has a quality:convergence_failure entry.  The gate must still produce a
	# non-empty blocked_reason so merge-mr.sh is skipped.
	declare -a deg=("quality:convergence_failure:main:iter=3")

	local blocked_reason=""
	local _ds
	for _ds in "${deg[@]}"; do
		if [[ "$_ds" == quality:convergence_failure:* ]]; then
			blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
			break
		fi
	done

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"quality:convergence_failure:main:iter=3"* ]]
}

# =============================================================================
# FUNCTIONAL: BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 restores old merge behavior
# =============================================================================

@test "BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 allows merge even when DEGRADED_STAGES has convergence failure" {
	# Old (pre-fix) behavior: merge proceeds regardless of convergence failure.
	# With =0 the gate is bypassed — merge_blocked_reason must stay empty.
	export BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0
	DEGRADED_STAGES=("quality:convergence_failure:main:iter=2")

	jq '.merge_blocked_reason = "should be bypassed"' \
		"$STATUS_FILE" > "${STATUS_FILE}.tmp" \
		&& mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

	local blocked_reason=""
	if [[ "${BLOCK_MERGE_ON_CONVERGENCE_FAILURE:-1}" != "0" ]]; then
		blocked_reason=$(jq -r '.merge_blocked_reason // empty' "$STATUS_FILE" 2>/dev/null)
		if [[ -z "$blocked_reason" ]]; then
			local _ds
			for _ds in "${DEGRADED_STAGES[@]}"; do
				if [[ "$_ds" == quality:convergence_failure:* ]]; then
					blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
					break
				fi
			done
		fi
	fi

	# Gate bypassed — blocked_reason must be empty so merge-mr.sh is reached
	[[ -z "$blocked_reason" ]]
}

# =============================================================================
# FUNCTIONAL: pr_review:max_iterations blocks merge (issue #594)
# =============================================================================
# A PR-review loop that exhausts its iterations without an approved verdict
# records "pr_review:max_iterations:*" in degraded_stages. The merge gate must
# treat this as a blocking condition (review never converged), same as a
# quality:convergence_failure, and leave the PR OPEN instead of auto-merging.

@test "orchestrator merge gate scans DEGRADED_STAGES for pr_review:max_iterations" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# The merge-gate fallback loop must match a pr_review:max_iterations entry
	[[ "$script_content" == *'pr_review:max_iterations:*'* ]]
}

@test "pr_review:max_iterations in degraded_stages produces a merge block" {
	# Mirror the merge-gate fallback scan (Gate B): a pr_review:max_iterations
	# entry must yield a non-empty blocked_reason so merge-mr.sh is skipped.
	declare -a deg=("pr_review:max_iterations:iter=3")

	local blocked_reason=""
	local _dsp
	for _dsp in "${deg[@]}"; do
		if [[ "$_dsp" == pr_review:max_iterations:* || "$_dsp" == pr_review:wall_timeout ]]; then
			blocked_reason="PR review loop ended without an approved verdict (degraded_stages: $_dsp)."
			break
		fi
	done

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"pr_review:max_iterations:iter=3"* ]]
}

@test "quality:convergence_failure still blocks when pr_review entry absent (regression)" {
	# AC2: existing convergence blocking behaviour is unaffected.
	declare -a deg=("quality:convergence_failure:main:iter=3")

	local blocked_reason=""
	local _ds
	for _ds in "${deg[@]}"; do
		if [[ "$_ds" == quality:convergence_failure:* ]]; then
			blocked_reason="Quality loop convergence failure recorded in degraded_stages: $_ds"
			break
		fi
	done

	[[ -n "$blocked_reason" ]]
	[[ "$blocked_reason" == *"quality:convergence_failure:main:iter=3"* ]]
}

@test "process-pr SKILL.md falls back to degraded_stages scan for pr_review:max_iterations" {
	local skill_file
	# Prefer the post-git-mv plugin layout; fall back to the legacy layout.
	skill_file="$(dirname "$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")")/plugins/pipeline-core/skills/process-pr/SKILL.md"
	[[ -f "$skill_file" ]] || skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]
	# Skill must document the pr_review:max_iterations fallback path (AC4: no
	# orchestrator<->process-pr drift).
	grep -q 'pr_review:max_iterations' "$skill_file"
}

# =============================================================================
# STATIC ANALYSIS: process-pr schema includes merge_blocked status
# =============================================================================

@test "process-pr schema allows merge_blocked as a valid status" {
	local schema_file
	schema_file="$SCRIPT_DIR/schemas/process-pr.json"

	[[ -f "$schema_file" ]]
	grep -q '"merge_blocked"' "$schema_file"
}

# =============================================================================
# BEHAVIORAL: process-pr SKILL.md contains AC4 merge-block gate logic
# =============================================================================
# SKILL_FILE is derived from ORCHESTRATOR_SCRIPT (set at load time, real path).
# SCRIPT_DIR is re-set by sourced orchestrator functions and points to TEST_TMP.

@test "process-pr SKILL.md reads merge_blocked_reason from status.json before merging" {
	local skill_file
	# Prefer the post-git-mv plugin layout; fall back to the legacy layout.
	skill_file="$(dirname "$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")")/plugins/pipeline-core/skills/process-pr/SKILL.md"
	[[ -f "$skill_file" ]] || skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]
	grep -q '\.merge_blocked_reason // empty' "$skill_file"
}

@test "process-pr SKILL.md block check precedes merge-mr.sh invocation" {
	local skill_file
	# Prefer the post-git-mv plugin layout; fall back to the legacy layout.
	skill_file="$(dirname "$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")")/plugins/pipeline-core/skills/process-pr/SKILL.md"
	[[ -f "$skill_file" ]] || skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]

	local block_line merge_line
	block_line=$(grep -n 'merge_blocked_reason // empty' "$skill_file" | head -1 | cut -d: -f1)
	# Match the actual invocation line (contains PLATFORM_DIR), not prose references
	merge_line=$(grep -n 'PLATFORM_DIR.*merge-mr\.sh\|merge-mr\.sh.*PR_NUMBER' "$skill_file" | head -1 | cut -d: -f1)

	[[ -n "$block_line" ]]
	[[ -n "$merge_line" ]]
	(( block_line < merge_line ))
}

@test "process-pr SKILL.md exits without merging when MERGE_BLOCKED_REASON is set" {
	local skill_file
	# Prefer the post-git-mv plugin layout; fall back to the legacy layout.
	skill_file="$(dirname "$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")")/plugins/pipeline-core/skills/process-pr/SKILL.md"
	[[ -f "$skill_file" ]] || skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]
	# Skill must document a non-merge exit path when the block reason is populated
	grep -q 'MERGE BLOCKED' "$skill_file"
	grep -q 'Leave the PR open' "$skill_file"
}

@test "process-pr SKILL.md supports BLOCK_MERGE_ON_CONVERGENCE_FAILURE=0 override" {
	local skill_file
	# Prefer the post-git-mv plugin layout; fall back to the legacy layout.
	skill_file="$(dirname "$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")")/plugins/pipeline-core/skills/process-pr/SKILL.md"
	[[ -f "$skill_file" ]] || skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]
	grep -q 'BLOCK_MERGE_ON_CONVERGENCE_FAILURE' "$skill_file"
}

@test "process-pr SKILL.md falls back to degraded_stages scan when merge_blocked_reason absent" {
	local skill_file
	# Prefer the post-git-mv plugin layout; fall back to the legacy layout.
	skill_file="$(dirname "$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")")/plugins/pipeline-core/skills/process-pr/SKILL.md"
	[[ -f "$skill_file" ]] || skill_file="$(dirname "$(dirname "$ORCHESTRATOR_SCRIPT")")/skills/process-pr/SKILL.md"

	[[ -f "$skill_file" ]]
	# Skill must document the degraded_stages fallback path
	grep -q 'degraded_stages' "$skill_file"
	grep -q 'quality:convergence_failure' "$skill_file"
}

# =============================================================================
# STATIC ANALYSIS: max-iterations check runs after that iteration's review
# (issue #651 — budget the verdict, not the round-trip)
# =============================================================================
# The check must sit in the changes_requested (else) branch, after the PR
# comment for the current iteration's review has already been posted — so a
# fix applied on iteration N is always followed by a review on iteration N+1
# before the loop can block on max_iterations. A check at the top of the
# loop (before that iteration's review runs) would let the loop exit without
# ever re-reviewing the final fix, which is the bug #651 fixed.

@test "max_iterations check is inside the changes_requested branch, not at loop top" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# The review-verdict branch and the max_iterations check must both be
	# present, and the check must reference the current iteration's fix
	# guard (pr_iteration >= pr_review_max_iter), not the pre-#651
	# strictly-greater-than top-of-loop form.
	[[ "$script_content" == *'if (( pr_iteration >= pr_review_max_iter )); then'* ]]
}

@test "max_iterations check follows the current-iteration PR review comment (re-review before block)" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	local review_comment_pos maxiter_check_pos
	review_comment_pos=$(grep -n 'comment_pr "\$pr_number" "PR Review (Iteration \$pr_iteration)"' \
		<<< "$script_content" | head -1 | cut -d: -f1)
	maxiter_check_pos=$(grep -n 'if (( pr_iteration >= pr_review_max_iter )); then' \
		<<< "$script_content" | head -1 | cut -d: -f1)

	[[ -n "$review_comment_pos" ]]
	[[ -n "$maxiter_check_pos" ]]
	# The check must come AFTER the review comment for the same iteration,
	# proving the review already ran before the loop can block.
	(( maxiter_check_pos > review_comment_pos ))
}

@test "max_iterations check is guarded by review_verdict != approved" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	# Extract the review-verdict branch and confirm the max_iterations
	# check lives in the else (changes_requested) arm, not the approved arm.
	local verdict_block
	verdict_block=$(awk \
		'/if \[\[ "\$review_verdict" == "approved" \]\]; then/,/log "PR review requested changes\. Fixing\.\.\."/' \
		"$ORCHESTRATOR_SCRIPT" 2>/dev/null || true)

	[[ "$verdict_block" == *'pr_approved=true'* ]]
	[[ "$verdict_block" == *'if (( pr_iteration >= pr_review_max_iter )); then'* ]]
	[[ "$verdict_block" == *'pr_review:max_iterations:iter=$pr_iteration'* ]]
}

@test "no stale top-of-loop max_iterations check precedes the current-iteration review (regression)" {
	# Pre-#651 bug: a strictly-greater-than check ran at the top of the loop,
	# before that iteration's review, so a fix could go unreviewed. Guard
	# against reintroducing a check that fires before the review comment.
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	local loop_start_pos review_comment_pos
	loop_start_pos=$(grep -n 'while \[\[ "\$pr_approved" != "true" \]\]; do' \
		<<< "$script_content" | head -1 | cut -d: -f1)
	review_comment_pos=$(grep -n 'comment_pr "\$pr_number" "PR Review (Iteration \$pr_iteration)"' \
		<<< "$script_content" | head -1 | cut -d: -f1)

	local between
	between=$(sed -n "${loop_start_pos},${review_comment_pos}p" "$ORCHESTRATOR_SCRIPT")

	[[ "$between" != *'pr_iteration > pr_review_max_iter'* ]]
}

# =============================================================================
# FUNCTIONAL: re-review runs after the final fix before a max_iterations block
# (issue #651)
# =============================================================================
# Simulates the loop's own control flow (mirrored from the real else-branch
# ordering above) to prove that every fix is followed by a review, and the
# loop only ever blocks after that review has run.

@test "simulated loop re-reviews every fix before blocking on max_iterations" {
	local pr_review_max_iter=3
	local pr_iteration=0
	local pr_approved=false
	local review_count=0
	local fix_count=0
	local blocked_reason=""

	while [[ "$pr_approved" != "true" ]]; do
		pr_iteration=$(( pr_iteration + 1 ))

		# Every review in this simulation requests changes, forcing the
		# loop to run all the way to the max_iterations block.
		review_count=$(( review_count + 1 ))
		local review_verdict="changes_requested"

		if [[ "$review_verdict" == "approved" ]]; then
			pr_approved=true
		else
			if (( pr_iteration >= pr_review_max_iter )); then
				blocked_reason="PR review loop ended without an approved verdict after max iterations (pr_review:max_iterations:iter=$pr_iteration)."
				pr_approved=true
				break
			fi
			fix_count=$(( fix_count + 1 ))
		fi

		(( pr_iteration > 10 )) && break  # test-only safety valve
	done

	# Every fix (2, since iteration 3 blocks instead of fixing) was
	# followed by a review before the loop could block: review_count is
	# exactly fix_count + 1 — the review of the final fix.
	[[ "$review_count" -eq 3 ]]
	[[ "$fix_count" -eq 2 ]]
	[[ "$review_count" -eq $(( fix_count + 1 )) ]]
	[[ "$blocked_reason" == *"max_iterations:iter=3"* ]]
}

@test "simulated loop applies no fix without a following review (max_iter=1, immediate block)" {
	local pr_review_max_iter=1
	local pr_iteration=0
	local pr_approved=false
	local review_count=0
	local fix_count=0
	local blocked_reason=""

	while [[ "$pr_approved" != "true" ]]; do
		pr_iteration=$(( pr_iteration + 1 ))
		review_count=$(( review_count + 1 ))
		local review_verdict="changes_requested"

		if [[ "$review_verdict" == "approved" ]]; then
			pr_approved=true
		else
			if (( pr_iteration >= pr_review_max_iter )); then
				blocked_reason="PR review loop ended without an approved verdict after max iterations (pr_review:max_iterations:iter=$pr_iteration)."
				pr_approved=true
				break
			fi
			fix_count=$(( fix_count + 1 ))
		fi

		(( pr_iteration > 10 )) && break
	done

	# With max_iter=1 the single review already ran before the block fires,
	# and no fix is ever applied without a subsequent review.
	[[ "$review_count" -eq 1 ]]
	[[ "$fix_count" -eq 0 ]]
	[[ "$blocked_reason" == *"max_iterations:iter=1"* ]]
}

@test "simulated loop applies final fix and re-reviews it, then approves (no block)" {
	local pr_review_max_iter=3
	local pr_iteration=0
	local pr_approved=false
	local review_count=0
	local fix_count=0
	local blocked_reason=""

	# changes_requested, changes_requested, approved
	local -a verdicts=("changes_requested" "changes_requested" "approved")

	while [[ "$pr_approved" != "true" ]]; do
		pr_iteration=$(( pr_iteration + 1 ))
		review_count=$(( review_count + 1 ))
		local review_verdict="${verdicts[$((pr_iteration - 1))]}"

		if [[ "$review_verdict" == "approved" ]]; then
			pr_approved=true
		else
			if (( pr_iteration >= pr_review_max_iter )); then
				blocked_reason="PR review loop ended without an approved verdict after max iterations (pr_review:max_iterations:iter=$pr_iteration)."
				pr_approved=true
				break
			fi
			fix_count=$(( fix_count + 1 ))
		fi

		(( pr_iteration > 10 )) && break
	done

	# The final fix (applied after iteration 2) is re-reviewed on
	# iteration 3, which approves — no block, and the last review count
	# still reflects one review per fix plus the approving review.
	[[ "$review_count" -eq 3 ]]
	[[ "$fix_count" -eq 2 ]]
	[[ -z "$blocked_reason" ]]
	[[ "$pr_approved" == "true" ]]
}

# =============================================================================
# FUNCTIONAL + STATIC: the two block reasons (max_iterations vs wall_timeout)
# are textually and structurally distinguishable (issue #651)
# =============================================================================

@test "max_iterations and wall_timeout block-reason messages are distinct strings" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'"PR review loop ended without an approved verdict after max iterations (pr_review:max_iterations:iter=$pr_iteration)."'* ]]
	[[ "$script_content" == *'"PR review loop hit wall-clock timeout without an approved verdict (pr_review:wall_timeout)."'* ]]
	[[ "$script_content" == *'"PR review loop hit its wall-clock budget without an approved verdict (pr_review:wall_timeout)."'* ]]
}

@test "max_iterations and wall_timeout DEGRADED_STAGES tags use distinct prefixes" {
	local script_content
	script_content=$(< "$ORCHESTRATOR_SCRIPT")

	[[ "$script_content" == *'DEGRADED_STAGES+=("pr_review:max_iterations:iter=$pr_iteration")'* ]]
	[[ "$script_content" == *'DEGRADED_STAGES+=("pr_review:wall_timeout")'* ]]
}

@test "persisted max_iterations and wall_timeout reasons are distinguishable by glob in the merge gate" {
	# Mirrors the Gate B fallback scan (merge_pr): both tags are recognised,
	# but the interpolated $_dsp preserves which situation actually fired.
	local -a max_iter_case=("pr_review:max_iterations:iter=3")
	local -a wall_timeout_case=("pr_review:wall_timeout")

	local reason=""
	local _dsp
	for _dsp in "${max_iter_case[@]}"; do
		if [[ "$_dsp" == pr_review:max_iterations:* || "$_dsp" == pr_review:wall_timeout ]]; then
			reason="PR review loop ended without an approved verdict (degraded_stages: $_dsp)."
			break
		fi
	done
	local max_iter_reason="$reason"

	reason=""
	for _dsp in "${wall_timeout_case[@]}"; do
		if [[ "$_dsp" == pr_review:max_iterations:* || "$_dsp" == pr_review:wall_timeout ]]; then
			reason="PR review loop ended without an approved verdict (degraded_stages: $_dsp)."
			break
		fi
	done
	local wall_timeout_reason="$reason"

	[[ -n "$max_iter_reason" ]]
	[[ -n "$wall_timeout_reason" ]]
	# Both reach the same generic prefix, but the embedded tag still
	# distinguishes which situation occurred.
	[[ "$max_iter_reason" != "$wall_timeout_reason" ]]
	[[ "$max_iter_reason" == *"pr_review:max_iterations:iter=3"* ]]
	[[ "$wall_timeout_reason" == *"pr_review:wall_timeout"* ]]
}

@test "persist_merge_blocked_reason stores distinct text for max_iterations vs wall_timeout" {
	persist_merge_blocked_reason \
		"PR review loop ended without an approved verdict after max iterations (pr_review:max_iterations:iter=2)."

	local stored
	stored=$(jq -r '.merge_blocked_reason' "$STATUS_FILE")

	[[ "$stored" == *"max iterations"* ]]
	[[ "$stored" == *"pr_review:max_iterations:iter=2"* ]]
	[[ "$stored" != *"wall-clock"* ]]
}

@test "persist_merge_blocked_reason stores distinct text for wall_timeout vs max_iterations" {
	persist_merge_blocked_reason \
		"PR review loop hit its wall-clock budget without an approved verdict (pr_review:wall_timeout)."

	local stored
	stored=$(jq -r '.merge_blocked_reason' "$STATUS_FILE")

	[[ "$stored" == *"wall-clock budget"* ]]
	[[ "$stored" == *"pr_review:wall_timeout"* ]]
	[[ "$stored" != *"max iterations"* ]]
}
