#!/usr/bin/env bats
#
# test-comment-helpers.bats
# Tests for the comment_issue and comment_pr helper functions
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    # REPO is set via a conditional block in the orchestrator (if/elif/else)
    # which the awk filter in source_orchestrator_functions() cannot extract.
    # Mock it directly, matching the pattern used by test-argument-parsing.bats.
    export REPO="test-owner/test-repo"
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    # Source the orchestrator functions
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# FUNCTION DEFINITIONS
# =============================================================================

@test "comment_issue function is defined" {
    [ "$(type -t comment_issue)" = "function" ]
}

@test "comment_pr function is defined" {
    [ "$(type -t comment_pr)" = "function" ]
}

# =============================================================================
# REPO CONSTANT
# =============================================================================

@test "REPO constant is defined" {
    [ -n "$REPO" ]
}

@test "REPO has owner/repo format" {
    [ -n "$REPO" ]
    # REPO must be in owner/repo format (contains exactly one slash)
    [[ "$REPO" == *"/"* ]] || fail "REPO should be in owner/repo format, got: $REPO"
    local slash_count
    slash_count=$(echo "$REPO" | tr -cd '/' | wc -c | tr -d ' ')
    [ "$slash_count" -eq 1 ] || fail "REPO should have exactly one slash, got: $REPO"
}

# =============================================================================
# COMMENT_ISSUE STRUCTURE
# =============================================================================

@test "comment_issue uses platform comment-issue wrapper" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *"comment-issue.sh"* ]]
}

@test "comment_issue uses ISSUE_NUMBER variable" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *'$ISSUE_NUMBER'* ]] || [[ "$func_def" == *'"$ISSUE_NUMBER"'* ]]
}

@test "comment_issue uses PLATFORM_DIR variable" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *'$PLATFORM_DIR'* ]] || [[ "$func_def" == *'"$PLATFORM_DIR"'* ]]
}

@test "comment_issue includes orchestrator attribution" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *"implement-issue-orchestrator"* ]]
}

@test "comment_issue logs the action" {
    local func_def
    func_def=$(declare -f comment_issue)

    [[ "$func_def" == *"log"* ]]
}

# =============================================================================
# COMMENT_PR STRUCTURE
# =============================================================================

@test "comment_pr uses platform comment-mr wrapper" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *"comment-mr.sh"* ]]
}

@test "comment_pr takes pr_num as first argument" {
    local func_def
    func_def=$(declare -f comment_pr)

    # Check that function uses first parameter for PR number
    [[ "$func_def" == *'pr_num="$1"'* ]] || [[ "$func_def" == *'local pr_num'* ]]
}

@test "comment_pr uses PLATFORM_DIR variable" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *'$PLATFORM_DIR'* ]] || [[ "$func_def" == *'"$PLATFORM_DIR"'* ]]
}

@test "comment_pr includes orchestrator attribution" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *"implement-issue-orchestrator"* ]]
}

@test "comment_pr logs the action" {
    local func_def
    func_def=$(declare -f comment_pr)

    [[ "$func_def" == *"log"* ]]
}

# =============================================================================
# BEHAVIORAL TESTS
# =============================================================================

@test "comment_issue calls gh with correct arguments and body content" {
    # Track gh calls including the full body
    local gh_calls="$TEST_TMP/gh-calls.txt"
    local gh_body="$TEST_TMP/gh-body.txt"
    cat > "$TEST_TMP/bin/gh" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$gh_calls"
# Capture --body argument content
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --body) echo "\$2" >> "$gh_body"; shift 2 ;;
        *) shift ;;
    esac
done
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    comment_issue "Test Title" "Test body content"

    [ -f "$gh_calls" ] || fail "gh was not called"
    grep -q "issue" "$gh_calls" || fail "Expected 'issue' in gh call"
    grep -q "comment" "$gh_calls" || fail "Expected 'comment' in gh call"
    grep -q "$ISSUE_NUMBER" "$gh_calls" || fail "Expected issue number in gh call"
    # Verify the comment body includes the title and body content
    [ -f "$gh_body" ] || fail "Expected --body argument to gh"
    grep -q "Test Title" "$gh_body" || fail "Expected title in comment body"
    grep -q "Test body content" "$gh_body" || fail "Expected body content in comment body"
}

@test "comment_pr calls gh with correct arguments and body content" {
    # Track gh calls including the full body
    local gh_calls="$TEST_TMP/gh-calls.txt"
    local gh_body="$TEST_TMP/gh-body.txt"
    cat > "$TEST_TMP/bin/gh" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$gh_calls"
# Capture --body argument content
while [[ \$# -gt 0 ]]; do
    case "\$1" in
        --body) echo "\$2" >> "$gh_body"; shift 2 ;;
        *) shift ;;
    esac
done
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    comment_pr 456 "Test Title" "Test body content"

    [ -f "$gh_calls" ] || fail "gh was not called"
    grep -q "pr" "$gh_calls" || fail "Expected 'pr' in gh call"
    grep -q "comment" "$gh_calls" || fail "Expected 'comment' in gh call"
    grep -q "456" "$gh_calls" || fail "Expected PR number in gh call"
    # Verify the comment body includes the title and body content
    [ -f "$gh_body" ] || fail "Expected --body argument to gh"
    grep -q "Test Title" "$gh_body" || fail "Expected title in PR comment body"
    grep -q "Test body content" "$gh_body" || fail "Expected body content in PR comment body"
}

@test "comment_issue handles gh failure gracefully" {
    # Make gh fail
    cat > "$TEST_TMP/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TEST_TMP/bin/gh"

    # comment_issue now propagates the underlying exit code (PR #427, to
    # support timeout detection). It is still "graceful" in practice: the
    # orchestrator runs without `set -e` and no caller checks the return
    # value, so a non-zero return is non-fatal — execution continues and the
    # failure is logged. Assert that contract rather than the old status==0.
    run comment_issue "Test Title" "Test body"

    # Propagates the failure rather than masking it as success
    [ "$status" -ne 0 ]

    # The failure is logged so it is visible in the run log
    grep -q "Failed to comment on issue" "$LOG_FILE" \
        || fail "Expected failure to be logged"
}

@test "comment_pr handles gh failure gracefully" {
    # Make gh fail
    cat > "$TEST_TMP/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TEST_TMP/bin/gh"

    # Should not crash the script
    run comment_pr 456 "Test Title" "Test body"

    # Should not fail (function handles error)
    [ "$status" -eq 0 ]
}

@test "comment_issue writes to log file" {
    # Mock gh to succeed
    cat > "$TEST_TMP/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    comment_issue "Test Title" "Test body" 2>/dev/null

    # Check log file
    [ -f "$LOG_FILE" ] || fail "Log file should exist"
    grep -q "Commenting on issue" "$LOG_FILE" || fail "Expected log entry for comment"
}

@test "comment_pr writes to log file" {
    # Mock gh to succeed
    cat > "$TEST_TMP/bin/gh" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    comment_pr 456 "Test Title" "Test body" 2>/dev/null

    # Check log file
    [ -f "$LOG_FILE" ] || fail "Log file should exist"
    grep -q "Commenting on PR" "$LOG_FILE" || fail "Expected log entry for PR comment"
}

# =============================================================================
# COMMENT FORMAT TESTS
# =============================================================================

@test "comment_issue formats title as header" {
    local func_def
    func_def=$(declare -f comment_issue)

    # Should use ## for header
    [[ "$func_def" == *'## $title'* ]] || [[ "$func_def" == *"## \$title"* ]]
}

@test "comment_pr formats title as header" {
    local func_def
    func_def=$(declare -f comment_pr)

    # Should use ## for header
    [[ "$func_def" == *'## $title'* ]] || [[ "$func_def" == *"## \$title"* ]]
}

# =============================================================================
# USAGE IN MAIN FLOW
# =============================================================================

@test "main flow calls comment_issue at start" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_issue "Starting Automated Processing"'* ]]
}

@test "main flow calls comment_issue for implementation plan confirmed" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_issue "Implementation Plan Confirmed"'* ]]
}

@test "main flow calls comment_issue for task completion" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_issue "Task'* ]]
}

@test "main flow calls comment_issue for resuming" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_issue "Resuming Automated Processing"'* ]]
}

@test "main flow calls comment_pr for completion" {
    local main_def
    main_def=$(declare -f main)

    [[ "$main_def" == *'comment_pr "$pr_number" "Implementation Complete"'* ]]
}

@test "main flow re-validates partial-block reconciliation before the completion comment" {
    # revalidate_partial_block_against_branch() re-runs branch-evidence
    # reconciliation and rewrites .reconciled_count/DEGRADED_STAGES. It must
    # run before the "Implementation Complete" comment reads those fields, or
    # a task promoted only by this gate-time recheck never appears there —
    # only in metrics.json, exported later at orchestrator exit.
    local main_def
    main_def=$(declare -f main)

    local before_complete="${main_def%%'comment_pr "$pr_number" "Implementation Complete"'*}"
    [[ "$before_complete" == *'revalidate_partial_block_against_branch "$BASE_BRANCH"'* ]]
}

@test "quality loop does not call comment_issue for intermediate stages" {
    # Intermediate quality loop comments were removed in #561 to reduce noise.
    # Only the convergence failure (error termination condition) comment remains.
    # Milestone comments (task complete, PR complete) are still posted by main().
    local func_def
    func_def=$(declare -f run_quality_loop)

    # No intermediate progress comments (only convergence failure error comment is allowed)
    [[ "$func_def" != *'comment_issue "Quality Loop: Review'* ]]
    [[ "$func_def" != *'comment_issue "Quality Loop: Fix'* ]]
    [[ "$func_def" != *'comment_issue "Quality Loop: Complete'* ]]
}

# =============================================================================
# QUIET MODE
# =============================================================================

@test "comment_issue is a no-op when QUIET=true" {
    local gh_calls="$TEST_TMP/gh-calls.txt"
    cat > "$TEST_TMP/bin/gh" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$gh_calls"
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    QUIET=true comment_issue "Test Title" "Test body"

    [ ! -f "$gh_calls" ] || fail "gh should not have been called when QUIET=true"
}

@test "comment_pr is a no-op when QUIET=true" {
    local gh_calls="$TEST_TMP/gh-calls.txt"
    cat > "$TEST_TMP/bin/gh" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$gh_calls"
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    QUIET=true comment_pr 456 "Test Title" "Test body"

    [ ! -f "$gh_calls" ] || fail "gh should not have been called when QUIET=true"
}

@test "comment_issue still calls gh when QUIET=false" {
    local gh_calls="$TEST_TMP/gh-calls.txt"
    cat > "$TEST_TMP/bin/gh" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$gh_calls"
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    QUIET=false comment_issue "Test Title" "Test body"

    [ -f "$gh_calls" ] || fail "gh should have been called when QUIET=false"
}

@test "comment_pr still calls gh when QUIET=false" {
    local gh_calls="$TEST_TMP/gh-calls.txt"
    cat > "$TEST_TMP/bin/gh" << EOF
#!/usr/bin/env bash
echo "\$@" >> "$gh_calls"
exit 0
EOF
    chmod +x "$TEST_TMP/bin/gh"

    QUIET=false comment_pr 456 "Test Title" "Test body"

    [ -f "$gh_calls" ] || fail "gh should have been called when QUIET=false"
}

# =============================================================================
# extract_changes_bullets (issue #1115)
# =============================================================================

@test "extract_changes_bullets keeps only Changes bullets" {
	local s=$'Intro prose.\n\n## Changes\n- Added foo\n- Fixed bar\n\n## Quality Gates\n- Tests: passed'
	run extract_changes_bullets "$s"
	[ "$status" -eq 0 ]
	[ "$output" = $'- Added foo\n- Fixed bar' ]
}

@test "extract_changes_bullets drops bracket placeholders" {
	local s=$'**Changes**\n- Real change\n- [fill in test outcome]\n- See [doc](http://x)'
	run extract_changes_bullets "$s"
	[ "$output" = $'- Real change\n- See [doc](http://x)' ]
}

@test "extract_changes_bullets falls back for prose-only description" {
	local s='Generated the comment. Not posted. Quality Gates are placeholders.'
	run extract_changes_bullets "$s"
	[ "$output" = "Implementation completed successfully" ]
}

@test "extract_changes_bullets falls back when all bullets are placeholders" {
	run extract_changes_bullets $'## Changes\n- [TBD]'
	[ "$output" = "Implementation completed successfully" ]
}

@test "extract_changes_bullets drops bare TBD and angle placeholder bullets" {
	local s=$'## Changes\n- Real change\n- TBD\n- tbd.\n* <describe change>\n- Uses <b> tag in output'
	run extract_changes_bullets "$s"
	[ "$output" = $'- Real change\n- Uses <b> tag in output' ]
}

@test "extract_changes_bullets falls back when only TBD or angle bullets" {
	run extract_changes_bullets $'## Changes\n- TBD\n- <summary>'
	[ "$output" = "Implementation completed successfully" ]
}

@test "extract_changes_bullets falls back on empty input" {
	run extract_changes_bullets ""
	[ "$output" = "Implementation completed successfully" ]
}

# =============================================================================
# build_complete_prompt (issue #1115)
# =============================================================================

@test "build_complete_prompt lists each task description and status" {
	cat > "$STATUS_FILE" <<'JSON'
{"tasks":[{"id":"1","description":"Add foo","status":"completed"},
{"id":"2","description":"Fix bar","status":"failed"}]}
JSON
	run build_complete_prompt 45 feature/issue-9 "SKILLTEXT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PR #45 implementing issue #123 on branch feature/issue-9"* ]]
	[[ "$output" == *"- Task 1 [completed]: Add foo"* ]]
	[[ "$output" == *"- Task 2 [failed]: Fix bar"* ]]
	[[ "$output" == *"SKILLTEXT"* ]]
}

@test "build_complete_prompt omits skill block when skill empty" {
	echo '{"tasks":[]}' > "$STATUS_FILE"
	run build_complete_prompt 1 b ""
	[[ "$output" == *"(no tasks recorded)"* ]]
	[[ "$output" != *"Skill Instructions"* ]]
}

# =============================================================================
# complete-summary skill asks for the Changes section only (issue #1115)
# =============================================================================

@test "complete-summary skill requests Changes section only, no gates or placeholders" {
	local skill="$BATS_TEST_DIRNAME/../../../plugins/pipeline-core/skills/complete-summary/SKILL.md"
	[ -f "$skill" ]
	grep -qF '### Changes' "$skill"
	grep -qi 'Changes section only' "$skill"
	grep -qi 'task list' "$skill"
	# The output template must no longer carry header/footer/gate lines.
	local fence_block
	fence_block=$(awk '/^## Output Format/{f=1;next} /^## /{f=0} f' "$skill")
	[[ "$fence_block" != *"Quality Gates"* ]]
	[[ "$fence_block" != *"Implementation Complete"* ]]
	[[ "$fence_block" != *"ready for human review"* ]]
	[[ "$fence_block" != *"Posted by"* ]]
	[[ "$fence_block" != *"["*"]"* ]]
}

# =============================================================================
# completion_footer derives readiness from state
# =============================================================================

@test "completion_footer says ready when no degraded stage and no block" {
	echo '{"merge_blocked_reason":null}' > "$STATUS_FILE"
	DEGRADED_STAGES=()
	run completion_footer
	[ "$status" -eq 0 ]
	[[ "$output" == *"ready for human review and merge"* ]]
	[[ "$output" != *"NOT"* ]]
}

@test "completion_footer names in-memory degraded stage" {
	echo '{}' > "$STATUS_FILE"
	DEGRADED_STAGES=("quality:max_iterations:x:iter=3")
	run completion_footer
	[[ "$output" == *"NOT ready"* ]]
	[[ "$output" == *"quality:max_iterations:x:iter=3"* ]]
}

@test "completion_footer names merge_blocked_reason" {
	echo '{"merge_blocked_reason":"Partial implementation: 1/2"}' > "$STATUS_FILE"
	DEGRADED_STAGES=()
	run completion_footer
	[[ "$output" == *"NOT ready"* ]]
	[[ "$output" == *"Partial implementation: 1/2"* ]]
}

@test "completion_footer uses persisted degraded_stages after resume" {
	echo '{"degraded_stages":["e2e_verify:degraded"]}' > "$STATUS_FILE"
	DEGRADED_STAGES=()
	run completion_footer
	[[ "$output" == *"NOT ready"* ]]
	[[ "$output" == *"e2e_verify:degraded"* ]]
}

# =============================================================================
# Complete stage: drives the real stage body with stubbed collaborators
# =============================================================================

complete_stage_setup() {
	local body
	body=$(awk '
		/set_stage_started "complete"/ { on = 1 }
		on { print }
		on && /set_stage_completed "complete"/ { exit }
	' "$ORCHESTRATOR_SCRIPT")
	if [[ "$body" != *'extract_changes_bullets'*'completion_footer'* ]]; then
		echo "complete stage body not found in $ORCHESTRATOR_SCRIPT" >&2
		return 1
	fi
	eval "complete_stage_body() {
$body
}"
	STAGE_OUT="$TEST_TMP/stage-out"
	: > "$STAGE_OUT"
	pr_number=7
	branch=feat
	RESUME_MODE=""
	set_stage_started() { :; }
	set_stage_completed() { :; }
	revalidate_partial_block_against_branch() { :; }
	load_skill() { :; }
	build_complete_prompt() { :; }
	_halt_if_budget_exceeded() { :; }
	_halt_if_api_error() { :; }
	append_reconciled_tally() { printf '%s' "$1"; }
	run_stage() {
		jq -n --arg s "$STUB_SUMMARY" '{output: {summary: $s}}'
	}
	comment_pr() { printf '%s' "$3" > "$STAGE_OUT"; }
	STUB_SUMMARY=$'## Changes\n- Adds the retry wrapper\n- TBD\n- <what the first task implemented>\n- Removes the TBD marker from the header'
	DEGRADED_STAGES=()
}

@test "complete stage posts filtered bullets and the ready footer" {
	complete_stage_setup
	echo '{}' > "$STATUS_FILE"

	run complete_stage_body
	[ "$status" -eq 0 ]
	local body
	body=$(< "$STAGE_OUT")
	[[ "$body" == *"- Adds the retry wrapper"* ]]
	[[ "$body" == *"- Removes the TBD marker from the header"* ]]
	[[ "$body" != *$'\n- TBD'* ]]
	[[ "$body" != *"<what the first task implemented>"* ]]
	[[ "$body" == *"ready for human review and merge"* ]]
}

@test "complete stage footer names a degraded stage instead of ready" {
	complete_stage_setup
	echo '{}' > "$STATUS_FILE"
	DEGRADED_STAGES=("pr_review:max_iterations:iter=2")

	# run would drop the array into a subshell copy; call directly.
	complete_stage_body
	local body
	body=$(< "$STAGE_OUT")
	[[ "$body" == *"- Adds the retry wrapper"* ]]
	[[ "$body" != *"ready for human review and merge"* ]]
	[[ "$body" == *"NOT ready to merge"* ]]
	[[ "$body" == *"pr_review:max_iterations:iter=2"* ]]
}
