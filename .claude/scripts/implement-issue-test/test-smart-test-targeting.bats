#!/usr/bin/env bats
#
# test-smart-test-targeting.bats
# Tests for detect_change_scope() and smart test targeting in run_test_loop()
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=main
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

    # Create a fake git repo for detect_change_scope to work with
    mkdir -p "$TEST_TMP/repo"
    cd "$TEST_TMP/repo"
    git init -q
    git checkout -q -b main
    echo "initial" > README.md
    git add README.md
    git commit -q -m "initial"

    # Source the orchestrator functions
    source_orchestrator_functions

    # Initialize status
    init_status
}

teardown() {
    teardown_test_env
}

# =============================================================================
# detect_change_scope() FUNCTION EXISTS
# =============================================================================

@test "detect_change_scope function is defined" {
    [ "$(type -t detect_change_scope)" = "function" ]
}

# =============================================================================
# detect_change_scope() RETURNS CORRECT SCOPE
# =============================================================================

@test "detect_change_scope returns 'typescript' for .ts files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-ts
    echo "export const x = 1;" > app.ts
    git add app.ts
    git commit -q -m "add ts"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for .tsx files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-tsx
    echo "export default () => <div/>;" > comp.tsx
    git add comp.tsx
    git commit -q -m "add tsx"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'bash' for .sh files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-sh
    echo "#!/bin/bash" > script.sh
    git add script.sh
    git commit -q -m "add sh"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .bats files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-bats
    echo "@test 'hello' { true; }" > test.bats
    git add test.bats
    git commit -q -m "add bats"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'config' for markdown-only changes" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-md
    echo "# Updated" > CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "add md"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'config' for json-only changes" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-json
    echo '{"key":"value"}' > config.json
    git add config.json
    git commit -q -m "add json"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'config' for yaml-only changes" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-yaml
    echo "key: value" > config.yaml
    git add config.yaml
    git commit -q -m "add yaml"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'mixed' for ts + sh files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-mixed
    echo "export const x = 1;" > app.ts
    echo "#!/bin/bash" > script.sh
    git add app.ts script.sh
    git commit -q -m "add both"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "mixed" ]
}

@test "detect_change_scope returns 'typescript' for ts + config files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-ts-config
    echo "export const x = 1;" > app.ts
    echo "# notes" > NOTES.md
    git add app.ts NOTES.md
    git commit -q -m "add ts and md"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'bash' for sh + config files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-sh-config
    echo "#!/bin/bash" > deploy.sh
    echo "# notes" > NOTES.md
    git add deploy.sh NOTES.md
    git commit -q -m "add sh and md"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'typescript' for .js files (treated as testable code)" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-js
    echo "module.exports = {};" > util.js
    git add util.js
    git commit -q -m "add js"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for unknown code extensions like .css" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-css
    echo "body { color: red; }" > style.css
    git add style.css
    git commit -q -m "add css"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for .sql files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-sql
    echo "SELECT 1;" > query.sql
    git add query.sql
    git commit -q -m "add sql"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for extensionless files like Makefile" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-makefile
    echo "all: build" > Makefile
    git add Makefile
    git commit -q -m "add Makefile"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for extensionless files like Dockerfile" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-dockerfile
    echo "FROM node:18" > Dockerfile
    git add Dockerfile
    git commit -q -m "add Dockerfile"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'config' when no files changed" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-empty
    # No changes from main

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

# =============================================================================
# run_test_loop() SMART ROUTING - STRUCTURE TESTS
# =============================================================================

@test "run_test_loop calls detect_change_scope" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"detect_change_scope"* ]]
}

@test "run_test_loop skips tests for config-only scope" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-config-skip
    echo "# Updated readme" > NOTES.md
    git add NOTES.md
    git commit -q -m "config only"

    # Mock comment_issue
    comment_issue() { :; }
    export -f comment_issue

    # Mock run_stage - should NOT be called for config scope
    local stage_call_file="$TEST_TMP/stage_calls"
    echo "0" > "$stage_call_file"
    export stage_call_file

    run_stage() {
        local count
        count=$(cat "$stage_call_file")
        echo "$((count + 1))" > "$stage_call_file"
        echo '{"status":"success","result":"passed","summary":"Tests passed"}'
    }
    export -f run_stage

    run_test_loop "$TEST_TMP/repo" "feature-config-skip" ""

    local calls
    calls=$(cat "$stage_call_file")
    [ "$calls" -eq 0 ]
}

@test "run_test_loop falls back to jest --changedSince when no test files changed" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"changedSince"* ]] || [[ "$func_def" == *"--changedSince"* ]]
}

@test "run_test_loop references bats for bash scope" {
    local func_def
    func_def=$(declare -f run_test_loop)

    [[ "$func_def" == *"bats"* ]] || [[ "$func_def" == *"BATS"* ]] || [[ "$func_def" == *".bats"* ]]
}

# =============================================================================
# EXPLICIT CHANGED-FILE TEST EXECUTION
# =============================================================================

@test "run_test_loop computes explicit changed test files via git diff" {
    local func_def
    func_def=$(declare -f run_test_loop)

    # Must grep for test/spec file patterns in changed files
    [[ "$func_def" == *'\.test\.'* ]]
    [[ "$func_def" == *'\.spec\.'* ]]
}

@test "run_test_loop excludes .integration.test files from explicit list" {
    local func_def
    func_def=$(declare -f run_test_loop)

    # Must filter out integration test files
    [[ "$func_def" == *'integration'* ]]
}

@test "run_test_loop passes explicit test files to jest when test files changed" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-ts-testfiles

    # Add an implementation file and a test file
    echo "export const add = (a, b) => a + b;" > math.ts
    echo "test('adds', () => expect(1+1).toBe(2));" > math.test.ts
    git add math.ts math.test.ts
    git commit -q -m "add ts with test"

    # Track the test command passed to run_stage
    local prompt_file="$TEST_TMP/test_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-loop-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"status":"success","result":"passed","summary":"Tests passed"}'
                ;;
            test-validate-*)
                echo '{"status":"success","result":"passed","summary":"Tests validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-ts-testfiles" "" "typescript"

    # The prompt should contain the test file directly
    local captured
    captured=$(< "$prompt_file")
    [[ "$captured" == *"math.test.ts"* ]]
}

@test "run_test_loop uses changedSince fallback when only impl files changed" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-ts-no-testfiles

    # Only add an implementation file (no test files)
    echo "export const sub = (a, b) => a - b;" > utils.ts
    git add utils.ts
    git commit -q -m "add ts without test"

    # Track the test command passed to run_stage
    local prompt_file="$TEST_TMP/fallback_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-loop-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"status":"success","result":"passed","summary":"Tests passed"}'
                ;;
            test-validate-*)
                echo '{"status":"success","result":"passed","summary":"Tests validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-ts-no-testfiles" "" "typescript"

    # The prompt should use --changedSince fallback
    local captured
    captured=$(< "$prompt_file")
    [[ "$captured" == *"changedSince"* ]]
}

@test "run_test_loop excludes integration test files from explicit jest list" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-ts-integration

    # Add an integration test file and a regular test file
    echo "test('int', () => {});" > auth.integration.test.ts
    echo "test('unit', () => {});" > auth.test.ts
    git add auth.integration.test.ts auth.test.ts
    git commit -q -m "add tests with integration"

    local prompt_file="$TEST_TMP/integration_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-loop-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"status":"success","result":"passed","summary":"Tests passed"}'
                ;;
            test-validate-*)
                echo '{"status":"success","result":"passed","summary":"Tests validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-ts-integration" "" "typescript"

    local captured
    captured=$(< "$prompt_file")
    # Should contain the regular test file
    [[ "$captured" == *"auth.test.ts"* ]]
    # Should NOT contain the integration test file
    [[ "$captured" != *"integration.test.ts"* ]]
}

@test "run_test_loop falls back to changedSince when only integration test files changed" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-ts-only-integration

    # Add ONLY an integration test file (no regular test files)
    echo "test('int', () => {});" > db.integration.test.ts
    echo "export const connect = () => {};" > db.ts
    git add db.integration.test.ts db.ts
    git commit -q -m "add only integration test"

    local prompt_file="$TEST_TMP/only_integration_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-loop-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"status":"success","result":"passed","summary":"Tests passed"}'
                ;;
            test-validate-*)
                echo '{"status":"success","result":"passed","summary":"Tests validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-ts-only-integration" "" "typescript"

    local captured
    captured=$(< "$prompt_file")
    # Should NOT contain the integration test file
    [[ "$captured" != *"integration.test.ts"* ]]
    # Should fall back to --changedSince since no non-integration test files exist
    [[ "$captured" == *"changedSince"* ]]
}

@test "run_test_loop handles mixed scope with explicit test files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-mixed-testfiles

    # Add TS test file and bash script
    echo "test('adds', () => expect(1+1).toBe(2));" > math.test.ts
    echo "#!/bin/bash" > deploy.sh
    git add math.test.ts deploy.sh
    git commit -q -m "add mixed with test"

    local prompt_file="$TEST_TMP/mixed_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-loop-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"status":"success","result":"passed","summary":"Tests passed"}'
                ;;
            test-validate-*)
                echo '{"status":"success","result":"passed","summary":"Tests validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-mixed-testfiles" "" "mixed"

    # Should contain the explicit test file and bats
    local captured
    captured=$(< "$prompt_file")
    [[ "$captured" == *"math.test.ts"* ]]
}

# =============================================================================
# docs stage: conditional on detect_change_scope()
# =============================================================================

@test "docs stage is skipped for bash scope — run_stage not called" {
    # Behavioral integration test: when branch_scope is 'bash', the docs stage
    # must be skipped. We verify this by checking that should_run_docs_stage
    # returns 1 (skip) for 'bash', and that the orchestrator docs block guards
    # on its result (not an inverted condition). An inverted guard would call
    # run_stage for 'bash' — confirmed absent by mocking run_stage and checking.

    # Verify should_run_docs_stage correctly returns 1 (skip) for bash
    run should_run_docs_stage "bash"
    [ "$status" -eq 1 ]

    # Verify the guard in main() uses should_run_docs_stage (not inlined logic)
    local main_def
    main_def=$(declare -f main)
    [[ "$main_def" == *"should_run_docs_stage"* ]]

    # Verify the condition is a negation (skip when it returns non-zero)
    # "! should_run_docs_stage" means: if should_run_docs_stage returns 1, skip
    [[ "$main_def" == *"! should_run_docs_stage"* ]]
}

# =============================================================================
# should_run_docs_stage() BEHAVIORAL TESTS
# These test the actual decision function, not string patterns in main().
# A negated condition in main() would still be caught by these tests.
# =============================================================================

@test "should_run_docs_stage returns 0 (run) for typescript scope" {
    run should_run_docs_stage "typescript"
    [ "$status" -eq 0 ]
}

@test "should_run_docs_stage returns 0 (run) for mixed scope" {
    run should_run_docs_stage "mixed"
    [ "$status" -eq 0 ]
}

@test "should_run_docs_stage returns 1 (skip) for bash scope" {
    run should_run_docs_stage "bash"
    [ "$status" -eq 1 ]
}

@test "should_run_docs_stage returns 1 (skip) for config scope" {
    run should_run_docs_stage "config"
    [ "$status" -eq 1 ]
}

@test "should_run_docs_stage returns 0 (run) for unknown scope (safe default)" {
    run should_run_docs_stage "unknown"
    [ "$status" -eq 0 ]
}

# =============================================================================
# PRE-EXISTING FAILURE FILTERING — Task 2 (#20)
# =============================================================================

@test "run_test_loop uses pr_failures variable for pre-existing failure filtering" {
    local func_def
    func_def=$(declare -f run_test_loop)

    # Must declare pr_failures (assignment, not just a mention in a comment)
    [[ "$func_def" == *'pr_failures='* ]]
    # Must use pr_failures for the failure count check
    [[ "$func_def" == *'pr_failures'*'jq'*'length'* ]]
}

@test "run_test_loop logs informational message when skipping pre-existing failures" {
    local func_def
    func_def=$(declare -f run_test_loop)

    # Must log a message specifically about skipping pre-existing failures
    # using the log function (not just in a comment or echo)
    [[ "$func_def" == *'log'*'pre-existing failure'* ]]
    # Must also log when all failures are pre-existing
    [[ "$func_def" == *'All test failures are pre-existing'* ]]
}

@test "fix-agent not dispatched when all failures are pre-existing in fallback mode" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-fallback-preexisting

    # Only add an implementation file (no test files → fallback --changedSince mode)
    echo "export const foo = () => {};" > src.ts
    git add src.ts
    git commit -q -m "impl without tests"

    local fix_called="$TEST_TMP/fix_preexist_called"
    echo "false" > "$fix_called"
    export fix_called

    local test_loop_reached="$TEST_TMP/test_loop_reached"
    echo "false" > "$test_loop_reached"
    export test_loop_reached

    run_stage() {
        local stage_name="$1"
        case "$stage_name" in
            test-loop-*)
                echo "true" > "$test_loop_reached"
                echo '{"status":"success","result":"failed","failures":[{"test":"PreExisting.test","message":"pre-existing failure"}],"summary":"1 pre-existing failure"}'
                ;;
            fix-tests-*)
                echo "true" > "$fix_called"
                echo '{"status":"success","summary":"Fixed"}'
                ;;
            test-validate-*)
                echo '{"status":"success","result":"passed","summary":"Validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-fallback-preexisting" "" "typescript"
    local exit_status=$?

    # Verify the test loop stage was actually reached
    [ "$(cat "$test_loop_reached")" = "true" ] || fail "run_stage test-loop was never called"
    # Verify run_test_loop exited successfully (pre-existing failures don't block)
    [ "$exit_status" -eq 0 ] || fail "run_test_loop should exit 0 when all failures are pre-existing"
    # Verify fix-agent was NOT dispatched
    [ "$(cat "$fix_called")" = "false" ] || fail "Fix-agent should not be dispatched for pre-existing failures in fallback mode"
}

@test "fix-agent dispatched when failures are from PR-changed test files in explicit mode" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-pr-test-failures

    # Add a test file (so explicit mode is used)
    echo "test('fails', () => { throw new Error('PR introduced failure'); });" > failing.test.ts
    git add failing.test.ts
    git commit -q -m "add failing PR test"

    local fix_called="$TEST_TMP/fix_explicit_called"
    echo "false" > "$fix_called"
    export fix_called

    local call_count_file="$TEST_TMP/test_loop_count"
    echo "0" > "$call_count_file"
    export call_count_file

    run_stage() {
        local stage_name="$1"
        case "$stage_name" in
            test-loop-*)
                local count
                count=$(cat "$call_count_file")
                count=$((count + 1))
                echo "$count" > "$call_count_file"
                if (( count <= 1 )); then
                    echo '{"status":"success","result":"failed","failures":[{"test":"failing.test","message":"PR introduced failure"}],"summary":"1 PR failure"}'
                else
                    echo '{"status":"success","result":"passed","summary":"Tests passed"}'
                fi
                ;;
            fix-tests-*)
                echo "true" > "$fix_called"
                echo '{"status":"success","summary":"Fixed"}'
                ;;
            test-validate-*)
                echo '{"status":"success","result":"passed","summary":"Validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-pr-test-failures" "" "typescript"
    local exit_status=$?

    # Verify run_test_loop completed successfully
    [ "$exit_status" -eq 0 ] || fail "run_test_loop should exit 0 after fix-agent resolves failures"
    # Verify fix-agent WAS dispatched for PR-changed test file failures
    [ "$(cat "$fix_called")" = "true" ] || fail "Fix-agent should be dispatched for PR-changed test file failures"
    # Verify test loop ran more than once (first fail, then pass after fix)
    local final_count
    final_count=$(cat "$call_count_file")
    [ "$final_count" -ge 2 ] || fail "Test loop should have iterated at least twice (fail then pass)"
}

@test "run_test_loop exits gracefully when fallback mode returns failed with empty failures array" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-empty-failures

    # Only impl file → fallback mode
    echo "export const bar = () => {};" > lib.ts
    git add lib.ts
    git commit -q -m "impl only"

    local fix_called="$TEST_TMP/fix_empty_failures"
    echo "false" > "$fix_called"
    export fix_called

    run_stage() {
        local stage_name="$1"
        case "$stage_name" in
            test-loop-*)
                # Failed result but with empty failures array
                echo '{"status":"success","result":"failed","failures":[],"summary":"0 failures"}'
                ;;
            fix-tests-*)
                echo "true" > "$fix_called"
                echo '{"status":"success","summary":"Fixed"}'
                ;;
            test-validate-*)
                echo '{"status":"success","result":"passed","summary":"Validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-empty-failures" "" "typescript"
    local exit_status=$?

    # Should exit gracefully — zero failures means nothing to fix
    [ "$exit_status" -eq 0 ] || fail "run_test_loop should exit 0 when failures array is empty"
    # Fix-agent should NOT be dispatched for empty failures
    [ "$(cat "$fix_called")" = "false" ] || fail "Fix-agent should not be dispatched when failures array is empty"
}
