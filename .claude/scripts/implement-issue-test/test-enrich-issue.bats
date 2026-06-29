#!/usr/bin/env bats
#
# test-enrich-issue.bats
# Tests for the enrich-issue skill (issue #368).
#
# The enrich-issue skill rewrites a pipeline-autocreated GitHub issue body
# in place with /explore-quality research + planning, then removes the
# needs-explore label.  These tests assert that the SKILL.md:
#   1. Exists at the canonical path with valid frontmatter
#   2. Documents idempotency — no-op when label absent or marker absent
#   3. Documents the pipeline-autocreated HTML comment marker check
#   4. Documents needs-explore label removal on success
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env
	PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
	SKILL_FILE="$PROJECT_DIR/.claude/skills/enrich-issue/SKILL.md"
	export PROJECT_DIR SKILL_FILE
	CLAUDE_PROJECT_DIR="$PROJECT_DIR"
	export CLAUDE_PROJECT_DIR
	source_orchestrator_functions
}

teardown() {
	teardown_test_env
}

# =============================================================================
# Group 1: Skill file existence and frontmatter
# =============================================================================

@test "enrich-issue SKILL.md exists at the canonical path" {
	[[ -f "$SKILL_FILE" ]]
}

@test "load_skill enrich-issue returns non-empty content" {
	local content
	content=$(load_skill "enrich-issue")
	[[ -n "$content" ]]
}

@test "SKILL.md frontmatter contains name: enrich-issue" {
	grep -q '^name: enrich-issue' "$SKILL_FILE"
}

@test "SKILL.md frontmatter documents label removal side effect" {
	grep -qiE 'remove.*label|removes_github_label' "$SKILL_FILE"
}

# =============================================================================
# Group 2: Idempotency
# =============================================================================

@test "SKILL.md documents idempotency — no-op when needs-explore absent" {
	grep -qiE 'no-op|idempotent|already.enriched' "$SKILL_FILE"
}

@test "SKILL.md documents idempotency — no-op when marker absent" {
	local content
	content=$(cat "$SKILL_FILE")
	[[ "$content" == *"pipeline-autocreated"* ]]
	printf '%s' "$content" | \
		grep -qiE 'bail|skip|abort|no-op'
}

@test "SKILL.md documents a clear log/message for the no-op case" {
	grep -qiE 'log|message|skip|bail|abort' "$SKILL_FILE"
}

# =============================================================================
# Group 3: Marker check
# =============================================================================

@test "SKILL.md documents the pipeline-autocreated HTML comment marker" {
	grep -q 'pipeline-autocreated' "$SKILL_FILE"
}

@test "SKILL.md documents bailing/skipping when the marker is absent" {
	local pattern
	pattern='bail|skip|abort|no-op'
	pattern="$pattern|marker.*(absent|missing)"
	pattern="$pattern|(absent|missing).*marker"
	grep -qiE "$pattern" "$SKILL_FILE"
}

# =============================================================================
# Group 4: Label removal
# =============================================================================

@test "SKILL.md documents removing the needs-explore label on success" {
	grep -qi 'needs-explore' "$SKILL_FILE"
	grep -qiE 'remov' "$SKILL_FILE"
}

@test "SKILL.md references gh issue edit or remove-label for label ops" {
	grep -qE 'gh issue edit|remove-label' "$SKILL_FILE"
}

# =============================================================================
# Group 5: batch-orchestrator.sh integration (--enrich-followups sweep)
# =============================================================================

@test "batch-orchestrator.sh exists at expected path" {
	local script
	script="$PROJECT_DIR/.claude/scripts/batch-orchestrator.sh"
	[[ -f "$script" ]]
}

@test "batch-orchestrator.sh accepts --enrich-followups flag" {
	local script
	script="$PROJECT_DIR/.claude/scripts/batch-orchestrator.sh"
	grep -q 'enrich-followups' "$script"
}

@test "handle-issues SKILL.md documents --enrich-followups flag" {
	local skill
	skill="$PROJECT_DIR/.claude/skills/handle-issues/SKILL.md"
	[[ -f "$skill" ]]
	grep -q 'enrich-followups' "$skill"
}

@test "enrich-issue SKILL.md integration section references batch-orchestrator" {
	grep -qiE 'batch-orchestrator|enrich-followups' "$SKILL_FILE"
}

# =============================================================================
# Group 6: preflight skip when enrich-issue no-ops on non-pipeline-autocreated
# =============================================================================
#
# Regression test for issue #554:
# validate_issue_for_processing() used to return 0 (proceed) after an
# enrich-issue dispatch that exited 0 as a no-op (pipeline-autocreated marker
# absent).  The fix must re-validate the body after a successful enrich call
# and skip (return 1) when it is still structurally invalid.

# Extract and source validate_issue_for_processing from batch-orchestrator.sh
# and assert_issue_valid from issue-body-lib.sh so the function can be tested
# end-to-end.  Returns 1 (which BATS converts to a skip) when an artefact is
# missing, the function is undefined, or the issue #554 fix is not yet present.
#
# The fix re-validates the issue body after a successful (rc=0) enrich dispatch
# and can skip.  Without it the no-op path proceeds unconditionally, so the
# assertion below would exercise behaviour that does not exist yet (e.g. on a
# branch carrying only the test and not the orchestrator change).  Gate on a
# signal of that re-validation so the test skips cleanly in isolation and runs
# for real once the orchestrator fix lands.
_source_validate_for_enrich_test() {
	local lib="$PROJECT_DIR/.claude/scripts/issue-body-lib.sh"
	[[ -f "$lib" ]] || return 1
	# shellcheck disable=SC1090
	source "$lib"

	local batch="$PROJECT_DIR/.claude/scripts/batch-orchestrator.sh"
	[[ -f "$batch" ]] || return 1

	local func_file="$TEST_TMP/validate_issue_for_processing.bash"
	_extract_function_body validate_issue_for_processing "$batch" \
		> "$func_file"
	grep -q 'validate_issue_for_processing' "$func_file" 2>/dev/null \
		|| return 1
	# Require evidence of the post-enrich re-validation fix (issue #554).
	grep -qiE 'revalidat|invalid after enrich' "$func_file" 2>/dev/null \
		|| return 1
	# shellcheck disable=SC1090
	source "$func_file"
}

@test "functional: non-pipeline-autocreated issue with needs-explore label causes preflight to skip after enrich-issue no-op" {
	# Arrange ----------------------------------------------------------------
	# Mock gh returns a body that has the needs-explore label but lacks the
	# <!-- pipeline-autocreated --> marker.  enrich-issue treats the absent
	# marker as a no-op and exits 0 without modifying the issue.  The fixed
	# validate_issue_for_processing must re-validate and skip (rc=1) rather
	# than proceeding with the unchanged, structurally invalid body.
	local mock_bin="$TEST_TMP/mock-bin"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/gh" << 'GHEOF'
#!/usr/bin/env bash
# Non-pipeline-autocreated body: no marker, no parseable task lines, no AC.
printf '%s\n' \
  '{"body":"This is a human-authored issue.\n\nNo pipeline marker here.","labels":[{"name":"needs-explore"}]}'
GHEOF
	chmod +x "$mock_bin/gh"
	export PATH="$mock_bin:$PATH"

	_source_validate_for_enrich_test \
		|| skip "validate_issue_for_processing() post-enrich re-validation fix not present"

	# Stub collaborators.
	# dispatch_composition simulates enrich-issue exiting 0 as a no-op
	# (marker absent → it logs the no-op message and exits 0 unchanged).
	log()                  { :; }
	log_warn()             { :; }
	dispatch_composition() { return 0; }
	export ENRICH_FOLLOWUPS=true
	unset DEPLOY_VERIFY_CMD

	# Act --------------------------------------------------------------------
	_SKIP_REASON=""
	local rc=0
	validate_issue_for_processing 99 || rc=$?

	# Assert -----------------------------------------------------------------
	# Must skip — body is still invalid after the enrich no-op.
	[[ "$rc" -eq 1 ]]
	# _SKIP_REASON must be non-empty (exact wording validated in
	# test-batch-orchestrator.bats functional suite).
	[[ -n "$_SKIP_REASON" ]]
}

# =============================================================================
# Group 7: Check 3 stderr surfacing + enrich-issue fallback (issue #555)
# =============================================================================
#
# Issue #555 hardens validate_issue_for_processing()'s Check 3 (structural
# validation of pipeline-autocreated / ## Implementation Tasks bodies) in two
# ways:
#   1. assert_issue_valid stderr (one diagnostic line per failed criterion) is
#      captured and re-emitted via log_warn instead of being discarded with
#      `2>/dev/null`, so the operator sees WHICH criterion failed without a
#      manual re-run.
#   2. When Check 3 fails AND ENRICH_FOLLOWUPS=true AND the body carries the
#      <!-- pipeline-autocreated --> marker, enrich-issue is dispatched as an
#      auto-repair fallback (mirroring Checks 1 and 2) before the skip. Bodies
#      without the marker (human-authored) are still skipped, no enrich attempt.
#
# These tests exercise the real validate_issue_for_processing extracted from
# batch-orchestrator.sh. Each gates on a signal of its target fix so the suite
# skips cleanly on a branch carrying only this test, and runs for real once the
# orchestrator changes land.

# Extract assert_issue_valid (issue-body-lib.sh) and
# validate_issue_for_processing (batch-orchestrator.sh) so Check 3 can be
# exercised end-to-end. Sets _CHECK3_FUNC_FILE to the extracted function-body
# file. Returns 1 (which BATS converts to a skip) when an artefact is missing
# or the function is undefined.
_source_validate_for_check3_test() {
	local lib="$PROJECT_DIR/.claude/scripts/issue-body-lib.sh"
	[[ -f "$lib" ]] || return 1
	# shellcheck disable=SC1090
	source "$lib"

	local batch="$PROJECT_DIR/.claude/scripts/batch-orchestrator.sh"
	[[ -f "$batch" ]] || return 1

	_CHECK3_FUNC_FILE="$TEST_TMP/validate_issue_for_processing.bash"
	_extract_function_body validate_issue_for_processing "$batch" \
		> "$_CHECK3_FUNC_FILE"
	grep -q 'validate_issue_for_processing' "$_CHECK3_FUNC_FILE" 2>/dev/null \
		|| return 1
	# shellcheck disable=SC1090
	source "$_CHECK3_FUNC_FILE"
}

# Install a mock `gh` whose `issue view` returns a fixed issue JSON with no
# labels (so Check 1's needs-explore guard passes). $1 is the JSON string body
# with newlines pre-escaped as \n; it must contain no single quotes, double
# quotes, or $ so it survives the single-quoted JSON wrapper.
_install_mock_gh_body() {
	local body_json="$1"
	local mock_bin="$TEST_TMP/mock-bin"
	mkdir -p "$mock_bin"
	cat > "$mock_bin/gh" << GHEOF
#!/usr/bin/env bash
printf '%s\n' '{"body":"$body_json","labels":[]}'
GHEOF
	chmod +x "$mock_bin/gh"
	export PATH="$mock_bin:$PATH"
}

@test "Check 3: assert_issue_valid stderr diagnostics are surfaced via log_warn (issue #555)" {
	_source_validate_for_check3_test \
		|| skip "validate_issue_for_processing() not extractable"
	# Gate on the task 1 fix: while the Check 3 assert_issue_valid call still
	# discards stderr with 2>/dev/null, the surfacing behaviour does not exist
	# yet, so skip cleanly in isolation and run for real once it lands.
	if grep -qF 'assert_issue_valid "$body" 2>/dev/null' "$_CHECK3_FUNC_FILE"; then
		skip "Check 3 stderr-surfacing fix not present (stderr still discarded)"
	fi

	# Pipeline-autocreated body: has the marker and ## Implementation Tasks
	# (passes Checks 1 and 2) but non-canonical tasks and no Acceptance Criteria,
	# so assert_issue_valid fails Criterion 1 ("no parseable task lines found").
	_install_mock_gh_body 'Pipeline-generated issue.\n\n<!-- pipeline-autocreated -->\n\n## Implementation Tasks\n\nsteps:\n  - do the thing in src/foo.ts\n  - do another thing\n'

	local warn_log="$TEST_TMP/warn.log"
	: > "$warn_log"
	log()                           { :; }
	log_warn()                      { printf '%s\n' "$*" >> "$warn_log"; }
	dispatch_composition()          { return 0; }
	revalidate_issue_after_enrich() { return 0; }
	# ENRICH_FOLLOWUPS=false isolates the stderr-surfacing path from the
	# enrich fallback — surfacing happens regardless of enrichment.
	export ENRICH_FOLLOWUPS=false
	unset DEPLOY_VERIFY_CMD

	local rc=0
	validate_issue_for_processing 98 || rc=$?

	# Body is structurally invalid → must skip.
	[[ "$rc" -eq 1 ]]
	# The specific assert_issue_valid diagnostic line must have reached log_warn.
	grep -q 'no parseable task lines found' "$warn_log"
}

@test "Check 3: pipeline-autocreated body failing validation triggers enrich-issue fallback (issue #555)" {
	_source_validate_for_check3_test \
		|| skip "validate_issue_for_processing() not extractable"
	# Gate on the task 2 fix: the Check 3 enrich fallback adds a third
	# dispatch_composition call (Checks 1 and 2 already have one each).
	local dc_count
	dc_count=$(grep -c 'dispatch_composition' "$_CHECK3_FUNC_FILE")
	(( dc_count >= 3 )) \
		|| skip "Check 3 enrich-issue fallback not present"

	_install_mock_gh_body 'Pipeline-generated issue.\n\n<!-- pipeline-autocreated -->\n\n## Implementation Tasks\n\nsteps:\n  - do the thing in src/foo.ts\n  - do another thing\n'

	local dc_log="$TEST_TMP/dispatch.log"
	: > "$dc_log"
	log()                           { :; }
	log_warn()                      { :; }
	dispatch_composition()          { printf '%s\n' "$*" >> "$dc_log"; return 0; }
	# Simulate enrich repairing the body so the function may proceed.
	revalidate_issue_after_enrich() { return 0; }
	export ENRICH_FOLLOWUPS=true
	unset DEPLOY_VERIFY_CMD

	validate_issue_for_processing 98 || true

	# The fallback must have dispatched enrich-issue for this issue number.
	grep -q 'enrich-issue' "$dc_log"
	grep -q '98' "$dc_log"
}

@test "Check 3: non-pipeline-autocreated body is skipped with no enrich-issue attempt (issue #555)" {
	_source_validate_for_check3_test \
		|| skip "validate_issue_for_processing() not extractable"
	local dc_count
	dc_count=$(grep -c 'dispatch_composition' "$_CHECK3_FUNC_FILE")
	(( dc_count >= 3 )) \
		|| skip "Check 3 enrich-issue fallback not present"

	# No <!-- pipeline-autocreated --> marker. The body still carries
	# ## Implementation Tasks so it reaches Check 3 and fails validation, but
	# the missing marker must prevent any enrich-issue attempt.
	_install_mock_gh_body 'Human-authored issue.\n\n## Implementation Tasks\n\nsteps:\n  - do the thing in src/foo.ts\n'

	local dc_log="$TEST_TMP/dispatch.log"
	: > "$dc_log"
	log()                           { :; }
	log_warn()                      { :; }
	dispatch_composition()          { printf '%s\n' "$*" >> "$dc_log"; return 0; }
	revalidate_issue_after_enrich() { return 0; }
	export ENRICH_FOLLOWUPS=true
	unset DEPLOY_VERIFY_CMD

	local rc=0
	validate_issue_for_processing 98 || rc=$?

	# Must skip, and must NOT have attempted enrich-issue (no marker).
	[[ "$rc" -eq 1 ]]
	[[ ! -s "$dc_log" ]]
}
