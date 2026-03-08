#!/usr/bin/env bats
#
# test-verdict-parsing.bats
# Tests for verdict extraction and fallback parsing logic
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0
    export SCHEMA_DIR="$TEST_TMP/schemas"

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
    mkdir -p "$SCHEMA_DIR"

    # Create required schemas
    for schema in implement-issue-implement implement-issue-test implement-issue-review implement-issue-fix implement-issue-simplify; do
        echo '{"type":"object"}' > "$SCHEMA_DIR/${schema}.json"
    done

    # Source the orchestrator functions
    source_orchestrator_functions

    # Initialize status
    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# STRUCTURED OUTPUT VERDICT EXTRACTION
# =============================================================================

@test "verdict parsing: structured output with .result field uses it directly" {
    # Mock run_stage to return structured output with .result
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*) echo '{"status":"success","result":"approved","summary":"Code review complete","issues":[]}' ;;
        esac
    }
    export -f run_stage

    # Mock comment_issue to avoid gh calls
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    # Verify the quality loop completed successfully (approved verdict)
    local quality_iterations
    quality_iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$quality_iterations" = "1" ]
}

@test "verdict parsing: structured output with changes_requested in .result field" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                # Return changes_requested in structured .result field
                echo '{"status":"success","result":"changes_requested","summary":"Found issues","issues":[{"description":"Fix formatting"}]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    # Should continue looping due to changes_requested verdict
    # This will eventually exit due to convergence detection
    run_quality_loop "/tmp/worktree" "test-branch" "test" || true

    # Verify verdict was extracted correctly from .result field in the logs
    grep -q "Verdict extracted from structured output: changes_requested" "$LOG_FILE" || \
        fail "Should extract changes_requested from .result field"
}

# =============================================================================
# FALLBACK VERDICT PARSING FROM SUMMARY TEXT
# =============================================================================

@test "verdict parsing: fallback with 'approved' keyword in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                # No .result field, must use fallback parsing
                # Summary contains "approved"
                echo '{"status":"success","summary":"Code review approved - no issues found","issues":[]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    # Should complete after one iteration (approved)
    local quality_iterations
    quality_iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$quality_iterations" = "1" ]
}

@test "verdict parsing: fallback with 'LGTM' keyword in summary (case-insensitive)" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                # No .result field, LGTM in summary
                echo '{"status":"success","summary":"LGTM - looks good to merge","issues":[]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    # Should complete after one iteration (LGTM parsed as approved)
    local quality_iterations
    quality_iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$quality_iterations" = "1" ]
}

@test "verdict parsing: fallback with 'looks good' keyword in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                echo '{"status":"success","summary":"This looks good to me","issues":[]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    local quality_iterations
    quality_iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$quality_iterations" = "1" ]
}

@test "verdict parsing: fallback with 'no issues' keyword in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                echo '{"status":"success","summary":"No issues found in this code","issues":[]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    local quality_iterations
    quality_iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$quality_iterations" = "1" ]
}

@test "verdict parsing: fallback with 'changes requested' keyword in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                # No .result field, "changes requested" in summary
                echo '{"status":"success","summary":"Changes requested - fix the formatting","issues":[{"description":"Fix formatting"}]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test" || true

    # Verify verdict was parsed correctly from fallback text
    grep -q "Verdict parsed from fallback text: changes_requested (matched rejection keywords)" "$LOG_FILE" || \
        fail "Should parse 'changes requested' as changes_requested from fallback text"
}

@test "verdict parsing: fallback with 'request changes' keyword in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                echo '{"status":"success","summary":"Please request changes before merging","issues":[{"description":"Needs work"}]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test" || true

    grep -q "Verdict parsed from fallback text: changes_requested (matched rejection keywords)" "$LOG_FILE" || \
        fail "Should parse 'request changes' as changes_requested from fallback text"
}

@test "verdict parsing: fallback with 'must fix' keyword in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                echo '{"status":"success","summary":"Must fix critical security issue","issues":[{"severity":"critical"}]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test" || true

    grep -q "Verdict parsed from fallback text: changes_requested (matched rejection keywords)" "$LOG_FILE" || \
        fail "Should parse 'must fix' as changes_requested from fallback text"
}

@test "verdict parsing: fallback with 'blocking' keyword in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                echo '{"status":"success","summary":"This is a blocking issue","issues":[{"priority":"blocking"}]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test" || true

    grep -q "Verdict parsed from fallback text: changes_requested (matched rejection keywords)" "$LOG_FILE" || \
        fail "Should parse 'blocking' as changes_requested from fallback text"
}

@test "verdict parsing: fallback with 'critical' keyword in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                echo '{"status":"success","summary":"Critical issues found in the code","issues":[{"severity":"critical"}]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test" || true

    grep -q "Verdict parsed from fallback text: changes_requested (matched rejection keywords)" "$LOG_FILE" || \
        fail "Should parse 'critical' as changes_requested from fallback text"
}

# =============================================================================
# FALLBACK DEFAULTS TO CHANGES_REQUESTED FOR AMBIGUOUS TEXT
# =============================================================================

@test "verdict parsing: fallback with ambiguous text defaults to changes_requested" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                # No .result field, ambiguous summary (no approval or rejection keywords)
                echo '{"status":"success","summary":"Review completed","issues":[]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    # Run quality loop - ambiguous verdict should be treated as changes_requested
    # Use BATS 'run' to capture exit code without failing on max-iterations exit
    run run_quality_loop "/tmp/worktree" "test-branch" "test"

    # Verify ambiguous text defaults to changes_requested (regardless of loop exit code)
    grep -q "Verdict parsed from fallback text: changes_requested (ambiguous/default)" "$LOG_FILE" || \
        fail "Ambiguous summary should default to changes_requested"
}

@test "verdict parsing: fallback with neutral text defaults to changes_requested" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                # Neutral text with no verdict keywords
                echo '{"status":"success","summary":"Code review in progress","issues":[]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run run_quality_loop "/tmp/worktree" "test-branch" "test"

    grep -q "Verdict parsed from fallback text: changes_requested (ambiguous/default)" "$LOG_FILE" || \
        fail "Neutral text should default to changes_requested"
}

@test "verdict parsing: fallback with empty summary defaults to changes_requested" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                # Empty summary field (will use default "Review completed")
                echo '{"status":"success","summary":"","issues":[]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run run_quality_loop "/tmp/worktree" "test-branch" "test"

    grep -q "Verdict parsed from fallback text: changes_requested (ambiguous/default)" "$LOG_FILE" || \
        fail "Empty summary should default to changes_requested"
}

@test "verdict parsing: fallback with missing summary field defaults to changes_requested" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success"}' ;;
            test-*) echo '{"status":"success","result":"passed"}' ;;
            review-*)
                # No summary field at all
                echo '{"status":"success","issues":[]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run run_quality_loop "/tmp/worktree" "test-branch" "test"

    grep -q "Verdict parsed from fallback text: changes_requested (ambiguous/default)" "$LOG_FILE" || \
        fail "Missing summary field should default to changes_requested"
}

# =============================================================================
# CASE INSENSITIVITY TESTS
# =============================================================================

@test "verdict parsing: fallback with uppercase APPROVED in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                echo '{"status":"success","summary":"APPROVED: No issues","issues":[]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test"

    # Should complete after one iteration (case-insensitive approved)
    local quality_iterations
    quality_iterations=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$quality_iterations" = "1" ]
}

@test "verdict parsing: fallback with mixed case 'Changes Requested' in summary" {
    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes needed"}' ;;
            test-*) echo '{"status":"success","result":"passed","summary":"All tests passed"}' ;;
            review-*)
                echo '{"status":"success","summary":"Changes Requested - please fix","issues":[{"description":"Fix it"}]}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "/tmp/worktree" "test-branch" "test" || true

    grep -q "Verdict parsed from fallback text: changes_requested (matched rejection keywords)" "$LOG_FILE" || \
        fail "Mixed case 'Changes Requested' should match rejection keywords (case-insensitive)"
}
