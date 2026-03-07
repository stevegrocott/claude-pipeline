#!/usr/bin/env bats
#
# test-prompt-file-lists.bats
# Tests verifying that stage prompts contain pre-computed file lists
# and do not contain embedded git commands.
#
# Background: stages (simplify, review, implement-task) pre-compute file
# lists before building their prompts.  These tests assert that the
# resulting prompt strings contain the expected file-list sections and
# that no raw git commands (which would ask the agent to run git itself)
# appear in the prompts.
#

load 'helpers/test-helper.bash'

# ---------------------------------------------------------------------------
# Shared git-repo helpers
# ---------------------------------------------------------------------------

# Create a minimal git repo in $TEST_TMP/repo with:
#   main branch: README.md
#   feature-123 branch: src/component.ts, src/widget.tsx, src/helper.js
_setup_git_repo() {
    local repo="$TEST_TMP/repo"
    mkdir -p "$repo/src"
    cd "$repo"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git checkout -q -b main
    echo "initial" > README.md
    git add README.md
    git commit -q -m "initial"

    git checkout -q -b feature-123
    echo "export const x = 1;" > src/component.ts
    echo "export default () => null;" > src/widget.tsx
    echo "regular file" > src/helper.js
    git add src/
    git commit -q -m "add files"
}

setup() {
    setup_test_env
    install_mocks

    export ISSUE_NUMBER=123
    export BASE_BRANCH=main
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0
    export SCHEMA_DIR="$TEST_TMP/schemas"
    export _CONSECUTIVE_TIMEOUTS=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
    mkdir -p "$SCHEMA_DIR"

    # Create required schemas
    for schema in implement-issue-implement implement-issue-test \
                  implement-issue-review implement-issue-fix \
                  implement-issue-simplify; do
        echo '{"type":"object"}' > "$SCHEMA_DIR/${schema}.json"
    done

    _setup_git_repo

    source_orchestrator_functions
    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# build_files_block() UNIT TESTS
# =============================================================================

@test "build_files_block with no arguments produces no LIKELY AFFECTED FILES header" {
    build_files_block > "$TEST_TMP/block-no-args.txt"
    ! grep -q "LIKELY AFFECTED FILES:" "$TEST_TMP/block-no-args.txt" || \
        fail "Empty file list should not produce LIKELY AFFECTED FILES header"
}

@test "build_files_block contains LIKELY AFFECTED FILES header when files given" {
    local result
    result=$(build_files_block "src/foo.ts" "src/bar.tsx")
    [[ "$result" == *"LIKELY AFFECTED FILES:"* ]] || \
        fail "Expected LIKELY AFFECTED FILES header. Got: $result"
}

@test "build_files_block lists each file with a dash prefix" {
    local result
    result=$(build_files_block "src/component.ts" "src/widget.tsx")
    [[ "$result" == *"- src/component.ts"* ]] || \
        fail "Missing - src/component.ts. Got: $result"
    [[ "$result" == *"- src/widget.tsx"* ]] || \
        fail "Missing - src/widget.tsx. Got: $result"
}

@test "build_files_block deduplicates repeated file paths" {
    local result
    result=$(build_files_block "src/foo.ts" "src/foo.ts" "src/bar.ts")
    local count
    count=$(printf '%s' "$result" | grep -c "src/foo.ts")
    [ "$count" -eq 1 ] || \
        fail "Expected src/foo.ts to appear once, got $count times. Result: $result"
}

@test "build_files_block sorts files alphabetically" {
    local result
    result=$(build_files_block "src/z.ts" "src/a.ts" "src/m.ts")
    local a_line z_line
    a_line=$(printf '%s' "$result" | grep -n "src/a.ts" | cut -d: -f1)
    z_line=$(printf '%s' "$result" | grep -n "src/z.ts" | cut -d: -f1)
    [ "$a_line" -lt "$z_line" ] || \
        fail "Expected files sorted: src/a.ts before src/z.ts. Result: $result"
}

@test "build_files_block does not contain git commands" {
    local result
    result=$(build_files_block "src/component.ts")
    ! printf '%s' "$result" | grep -qE 'git (diff|log|show)' || \
        fail "build_files_block output contains embedded git commands. Got: $result"
}

# =============================================================================
# SIMPLIFY PROMPT — FILE LIST CONTENT
# =============================================================================

@test "simplify prompt contains MODIFIED TYPESCRIPT/REACT FILES section" {
    local captured="$TEST_TMP/simplify-prompt.txt"
    export captured

    run_stage() {
        case "$1" in
            simplify-*) printf '%s' "$2" > "$captured"
                        echo '{"status":"success","summary":"No changes"}' ;;
            review-*)   echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "$TEST_TMP/repo" "feature-123" "task-1"

    [ -f "$captured" ] || fail "Simplify stage was not called"
    grep -q "MODIFIED TYPESCRIPT/REACT FILES:" "$captured" || \
        fail "Simplify prompt missing MODIFIED TYPESCRIPT/REACT FILES section"
}

@test "simplify prompt includes pre-computed TypeScript file names" {
    local captured="$TEST_TMP/simplify-prompt.txt"
    export captured

    run_stage() {
        case "$1" in
            simplify-*) printf '%s' "$2" > "$captured"
                        echo '{"status":"success","summary":"No changes"}' ;;
            review-*)   echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "$TEST_TMP/repo" "feature-123" "task-1"

    [ -f "$captured" ] || fail "Simplify stage was not called"
    grep -q "src/component.ts" "$captured" || \
        fail "Simplify prompt missing TypeScript file name src/component.ts"
    grep -q "src/widget.tsx" "$captured" || \
        fail "Simplify prompt missing TSX file name src/widget.tsx"
}

@test "simplify prompt excludes non-TypeScript files" {
    local captured="$TEST_TMP/simplify-prompt.txt"
    export captured

    run_stage() {
        case "$1" in
            simplify-*) printf '%s' "$2" > "$captured"
                        echo '{"status":"success","summary":"No changes"}' ;;
            review-*)   echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "$TEST_TMP/repo" "feature-123" "task-1"

    [ -f "$captured" ] || fail "Simplify stage was not called"
    ! grep -q "src/helper.js" "$captured" || \
        fail "Simplify prompt incorrectly includes non-TypeScript file src/helper.js"
}

@test "simplify prompt does not contain embedded git commands" {
    local captured="$TEST_TMP/simplify-prompt.txt"
    export captured

    run_stage() {
        case "$1" in
            simplify-*) printf '%s' "$2" > "$captured"
                        echo '{"status":"success","summary":"No changes"}' ;;
            review-*)   echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "$TEST_TMP/repo" "feature-123" "task-1"

    [ -f "$captured" ] || fail "Simplify stage was not called"
    ! grep -qE 'git (diff|log|show)' "$captured" || \
        fail "Simplify prompt contains embedded git commands"
}

# =============================================================================
# REVIEW PROMPT — FILE LIST CONTENT
# =============================================================================

@test "review prompt contains FILES CHANGED section" {
    local captured="$TEST_TMP/review-prompt.txt"
    export captured

    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes"}' ;;
            review-*)   printf '%s' "$2" > "$captured"
                        echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "$TEST_TMP/repo" "feature-123" "task-1"

    [ -f "$captured" ] || fail "Review stage was not called"
    grep -q "FILES CHANGED:" "$captured" || \
        fail "Review prompt missing FILES CHANGED section"
}

@test "review prompt includes pre-computed changed file names" {
    local captured="$TEST_TMP/review-prompt.txt"
    export captured

    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes"}' ;;
            review-*)   printf '%s' "$2" > "$captured"
                        echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "$TEST_TMP/repo" "feature-123" "task-1"

    [ -f "$captured" ] || fail "Review stage was not called"
    grep -q "src/component.ts" "$captured" || \
        fail "Review prompt missing changed file src/component.ts"
    grep -q "src/widget.tsx" "$captured" || \
        fail "Review prompt missing changed file src/widget.tsx"
}

@test "review prompt includes all changed files not just TypeScript" {
    local captured="$TEST_TMP/review-prompt.txt"
    export captured

    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes"}' ;;
            review-*)   printf '%s' "$2" > "$captured"
                        echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "$TEST_TMP/repo" "feature-123" "task-1"

    [ -f "$captured" ] || fail "Review stage was not called"
    grep -q "src/helper.js" "$captured" || \
        fail "Review prompt missing non-TypeScript changed file src/helper.js"
}

@test "review prompt does not contain embedded git commands" {
    local captured="$TEST_TMP/review-prompt.txt"
    export captured

    run_stage() {
        case "$1" in
            simplify-*) echo '{"status":"success","summary":"No changes"}' ;;
            review-*)   printf '%s' "$2" > "$captured"
                        echo '{"status":"success","result":"approved","summary":"Approved"}' ;;
        esac
    }
    export -f run_stage
    comment_issue() { :; }
    export -f comment_issue

    run_quality_loop "$TEST_TMP/repo" "feature-123" "task-1"

    [ -f "$captured" ] || fail "Review stage was not called"
    ! grep -qE 'git (diff|log|show)' "$captured" || \
        fail "Review prompt contains embedded git commands"
}
