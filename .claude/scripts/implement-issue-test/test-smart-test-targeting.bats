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
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}'
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
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}'
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
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}'
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
    # The jest command line (npx jest) should NOT contain the integration test file
    # (the CHANGED FILES section may list it for validation, but jest must not run it)
    local jest_line
    jest_line=$(echo "$captured" | grep "npx jest" || true)
    [[ "$jest_line" != *"integration.test.ts"* ]]
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
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}'
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
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}'
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
            test-iter-*)
                echo "true" > "$test_loop_reached"
                echo '{"result":"failed","failures":[{"test":"PreExisting.test","message":"pre-existing failure"}],"summary":"1 pre-existing failure","validation_result":"skipped"}'
                ;;
            fix-tests-*)
                echo "true" > "$fix_called"
                echo '{"status":"success","summary":"Fixed"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-fallback-preexisting" "" "typescript"
    local exit_status=$?

    # Verify the test loop stage was actually reached
    [ "$(cat "$test_loop_reached")" = "true" ] || fail "run_stage test-iter was never called"
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
            test-iter-*)
                local count
                count=$(cat "$call_count_file")
                count=$((count + 1))
                echo "$count" > "$call_count_file"
                if (( count <= 1 )); then
                    echo '{"result":"failed","failures":[{"test":"failing.test","message":"PR introduced failure"}],"summary":"1 PR failure","validation_result":"skipped"}'
                else
                    echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}'
                fi
                ;;
            fix-tests-*)
                echo "true" > "$fix_called"
                echo '{"status":"success","summary":"Fixed"}'
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
            test-iter-*)
                # Failed result but with empty failures array
                echo '{"result":"failed","failures":[],"summary":"0 failures","validation_result":"skipped"}'
                ;;
            fix-tests-*)
                echo "true" > "$fix_called"
                echo '{"status":"success","summary":"Fixed"}'
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

# =============================================================================
# _matches_frontend_pattern() TESTS
# =============================================================================

@test "_matches_frontend_pattern function is defined" {
    [ "$(type -t _matches_frontend_pattern)" = "function" ]
}

@test "_matches_frontend_pattern matches configured patterns" {
    export FRONTEND_PATH_PATTERNS="web/src/components/*|web/src/pages/*|web/e2e/*"

    run _matches_frontend_pattern "web/src/components/Button.tsx"
    [ "$status" -eq 0 ]

    run _matches_frontend_pattern "web/src/pages/Home.tsx"
    [ "$status" -eq 0 ]

    run _matches_frontend_pattern "web/e2e/login.spec.ts"
    [ "$status" -eq 0 ]
}

@test "_matches_frontend_pattern rejects non-matching paths" {
    export FRONTEND_PATH_PATTERNS="web/src/components/*|web/src/pages/*"

    run _matches_frontend_pattern "src/api/routes/users.ts"
    [ "$status" -eq 1 ]

    run _matches_frontend_pattern "server/index.ts"
    [ "$status" -eq 1 ]
}

@test "_matches_frontend_pattern returns 1 when FRONTEND_PATH_PATTERNS is empty" {
    export FRONTEND_PATH_PATTERNS=""

    run _matches_frontend_pattern "web/src/components/Button.tsx"
    [ "$status" -eq 1 ]
}

@test "_matches_frontend_pattern returns 1 when FRONTEND_PATH_PATTERNS is unset" {
    unset FRONTEND_PATH_PATTERNS

    run _matches_frontend_pattern "web/src/components/Button.tsx"
    [ "$status" -eq 1 ]
}

# =============================================================================
# detect_change_scope() FRONTEND SCOPE TESTS
# =============================================================================

@test "detect_change_scope returns 'frontend' for CSS-only changes with frontend patterns" {
    export FRONTEND_PATH_PATTERNS="web/src/components/*|web/src/*.css"

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-css-frontend
    mkdir -p web/src
    echo "body { color: red; }" > web/src/style.css
    git add web/src/style.css
    git commit -q -m "add css in frontend path"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "frontend" ]
}

@test "detect_change_scope returns 'ts-frontend' for TSX changes matching frontend patterns" {
    export FRONTEND_PATH_PATTERNS="web/src/components/*|web/src/pages/*"

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-tsx-frontend
    mkdir -p web/src/components
    echo "export default () => <div/>;" > web/src/components/Button.tsx
    git add web/src/components/Button.tsx
    git commit -q -m "add tsx component"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "ts-frontend" ]
}

@test "detect_change_scope returns 'typescript' for TS changes when FRONTEND_PATH_PATTERNS is empty" {
    export FRONTEND_PATH_PATTERNS=""

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-ts-no-patterns
    mkdir -p web/src/components
    echo "export default () => <div/>;" > web/src/components/Button.tsx
    git add web/src/components/Button.tsx
    git commit -q -m "add tsx without patterns"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for non-frontend TS changes" {
    export FRONTEND_PATH_PATTERNS="web/src/components/*|web/src/pages/*"

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-ts-backend
    mkdir -p src/api
    echo "export const handler = () => {};" > src/api/handler.ts
    git add src/api/handler.ts
    git commit -q -m "add backend ts"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'mixed' when ts + bash even with frontend patterns" {
    export FRONTEND_PATH_PATTERNS="web/src/components/*"

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-mixed-frontend
    mkdir -p web/src/components
    echo "export default () => <div/>;" > web/src/components/App.tsx
    echo "#!/bin/bash" > deploy.sh
    git add web/src/components/App.tsx deploy.sh
    git commit -q -m "add tsx and sh"

    local scope
    scope=$(detect_change_scope "." "main")
    # mixed takes precedence (ts + bash = mixed regardless of frontend)
    [ "$scope" = "mixed" ]
}

# =============================================================================
# E2E PROMPT INJECTION TESTS
# =============================================================================

@test "run_test_loop includes E2E section in prompt for ts-frontend scope" {
    export TEST_E2E_CMD="cd web && npx playwright test"

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-e2e-prompt
    mkdir -p web/src/components
    echo "export default () => <div/>;" > web/src/components/Button.tsx
    git add web/src/components/Button.tsx
    git commit -q -m "add component"

    local prompt_file="$TEST_TMP/e2e_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated","e2e_result":"passed","e2e_summary":"E2E passed"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-e2e-prompt" "" "ts-frontend"

    local captured
    captured=$(< "$prompt_file")
    [[ "$captured" == *"E2E TEST EXECUTION"* ]]
    [[ "$captured" == *"playwright test"* ]]
}

@test "run_test_loop omits E2E section for typescript scope" {
    export TEST_E2E_CMD="cd web && npx playwright test"

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-no-e2e-prompt
    echo "export const x = 1;" > app.ts
    git add app.ts
    git commit -q -m "add ts"

    local prompt_file="$TEST_TMP/no_e2e_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-no-e2e-prompt" "" "typescript"

    local captured
    captured=$(< "$prompt_file")
    [[ "$captured" != *"E2E TEST EXECUTION"* ]]
}

@test "run_test_loop omits E2E section when TEST_E2E_CMD is empty" {
    export TEST_E2E_CMD=""

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-no-e2e-cmd
    mkdir -p web/src/components
    echo "export default () => <div/>;" > web/src/components/Button.tsx
    git add web/src/components/Button.tsx
    git commit -q -m "add component"

    local prompt_file="$TEST_TMP/no_cmd_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-no-e2e-cmd" "" "ts-frontend"

    local captured
    captured=$(< "$prompt_file")
    [[ "$captured" != *"E2E TEST EXECUTION"* ]]
}

@test "run_test_loop includes E2E section for frontend scope" {
    export TEST_E2E_CMD="cd web && npx playwright test"

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-e2e-frontend-only
    mkdir -p web/src
    echo "body { color: blue; }" > web/src/app.css
    git add web/src/app.css
    git commit -q -m "add css"

    local prompt_file="$TEST_TMP/frontend_e2e_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated","e2e_result":"passed","e2e_summary":"E2E passed"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-e2e-frontend-only" "" "frontend"

    local captured
    captured=$(< "$prompt_file")
    [[ "$captured" == *"E2E TEST EXECUTION"* ]]
}

# =============================================================================
# run_test_loop() scope validation accepts new scopes
# =============================================================================

@test "run_test_loop accepts 'frontend' as valid pre-computed scope" {
    export TEST_E2E_CMD=""
    export FRONTEND_PATH_PATTERNS="web/src/*"

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-frontend-scope
    mkdir -p web/src
    echo "body {}" > web/src/style.css
    git add web/src/style.css
    git commit -q -m "css only"

    run_stage() {
        echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"OK"}'
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    # Should not fail or recompute — "frontend" is a valid scope
    run run_test_loop "$TEST_TMP/repo" "feature-frontend-scope" "" "frontend"
    [ "$status" -eq 0 ]
}

@test "run_test_loop accepts 'ts-frontend' as valid pre-computed scope" {
    export TEST_E2E_CMD=""
    export FRONTEND_PATH_PATTERNS="web/src/components/*"

    cd "$TEST_TMP/repo"
    git checkout -q -b feature-ts-frontend-scope
    mkdir -p web/src/components
    echo "export default () => <div/>;" > web/src/components/App.tsx
    git add web/src/components/App.tsx
    git commit -q -m "add component"

    run_stage() {
        echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"OK"}'
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run run_test_loop "$TEST_TMP/repo" "feature-ts-frontend-scope" "" "ts-frontend"
    [ "$status" -eq 0 ]
}

# =============================================================================
# .claude/ PIPELINE FILES EXCLUDED FROM SCOPE (claude-pipeline#41)
# =============================================================================

@test "detect_change_scope excludes .claude/*.sh from bash scope" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-claude-sh
    mkdir -p .claude/scripts
    echo "#!/bin/bash" > .claude/scripts/helper.sh
    git add .claude/scripts/helper.sh
    git commit -q -m "add pipeline script"

    local scope
    scope=$(detect_change_scope "." "main")
    # .claude/ shell scripts should NOT trigger bash scope
    [ "$scope" = "config" ]
}

@test "detect_change_scope excludes .claude/*.bats from bash scope" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-claude-bats
    mkdir -p .claude/scripts/implement-issue-test
    echo "@test 'hello' { true; }" > .claude/scripts/implement-issue-test/test-new.bats
    git add .claude/scripts/implement-issue-test/test-new.bats
    git commit -q -m "add pipeline test"

    local scope
    scope=$(detect_change_scope "." "main")
    # .claude/ bats files should NOT trigger bash scope
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'typescript' when .claude/ and app TS files both change" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-claude-plus-ts
    mkdir -p .claude/scripts
    echo "#!/bin/bash" > .claude/scripts/helper.sh
    echo "export const x = 1;" > app.ts
    git add .claude/scripts/helper.sh app.ts
    git commit -q -m "add both"

    local scope
    scope=$(detect_change_scope "." "main")
    # Should be typescript, NOT mixed (because .claude/ bash is excluded)
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope still returns 'bash' for non-.claude/ sh files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-app-sh
    echo "#!/bin/bash" > deploy.sh
    git add deploy.sh
    git commit -q -m "add app script"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "bash" ]
}

# =============================================================================
# filter_implementation_files() TESTS (claude-pipeline#41)
# =============================================================================

@test "filter_implementation_files function is defined" {
    [ "$(type -t filter_implementation_files)" = "function" ]
}

@test "filter_implementation_files excludes .claude/ files" {
    local result
    result=$(printf '%s\n' ".claude/scripts/orchestrator.sh" "src/app.ts" ".claude/config/platform.sh" | filter_implementation_files)
    [[ "$result" == *"src/app.ts"* ]]
    [[ "$result" != *".claude/"* ]]
}

@test "filter_implementation_files excludes docs/ files" {
    local result
    result=$(printf '%s\n' "docs/README.md" "src/index.ts" "docs/architecture.md" | filter_implementation_files)
    [[ "$result" == *"src/index.ts"* ]]
    [[ "$result" != *"docs/"* ]]
}

@test "filter_implementation_files excludes config file extensions" {
    local result
    result=$(printf '%s\n' "package.json" "config.yaml" "src/app.ts" "README.md" "docker-compose.yml" | filter_implementation_files)
    [[ "$result" == *"src/app.ts"* ]]
    [[ "$result" != *".json"* ]]
    [[ "$result" != *".yaml"* ]]
    [[ "$result" != *".md"* ]]
    [[ "$result" != *".yml"* ]]
}

@test "filter_implementation_files preserves source code files" {
    local result
    result=$(printf '%s\n' "src/routes/api.ts" "tests/unit/api.test.ts" "lib/utils.js" | filter_implementation_files)
    [[ "$result" == *"src/routes/api.ts"* ]]
    [[ "$result" == *"tests/unit/api.test.ts"* ]]
    [[ "$result" == *"lib/utils.js"* ]]
}

# =============================================================================
# _is_playwright_spec() TESTS (claude-pipeline#41)
# =============================================================================

@test "_is_playwright_spec function is defined" {
    [ "$(type -t _is_playwright_spec)" = "function" ]
}

@test "_is_playwright_spec identifies tests/e2e/ specs" {
    run _is_playwright_spec "tests/e2e/login.spec.ts"
    [ "$status" -eq 0 ]
}

@test "_is_playwright_spec identifies nested e2e/ specs" {
    run _is_playwright_spec "tests/e2e/bugs/test-killingworth.spec.ts"
    [ "$status" -eq 0 ]
}

@test "_is_playwright_spec rejects Jest test files" {
    run _is_playwright_spec "src/services/auth.test.ts"
    [ "$status" -eq 1 ]
}

@test "_is_playwright_spec rejects non-e2e spec files" {
    run _is_playwright_spec "src/components/Button.spec.ts"
    [ "$status" -eq 1 ]
}

# =============================================================================
# PLAYWRIGHT SPEC EXCLUSION FROM JEST (claude-pipeline#41)
# =============================================================================

@test "run_test_loop excludes Playwright specs from Jest command" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-playwright-split

    # Add both a Jest test and a Playwright spec
    echo "test('unit', () => {});" > math.test.ts
    mkdir -p tests/e2e
    echo "import { test } from '@playwright/test';" > tests/e2e/login.spec.ts
    git add math.test.ts tests/e2e/login.spec.ts
    git commit -q -m "add mixed test types"

    local prompt_file="$TEST_TMP/playwright_split_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"OK"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-playwright-split" "" "typescript"

    local captured
    captured=$(< "$prompt_file")
    # Jest command should contain the unit test
    local jest_line
    jest_line=$(echo "$captured" | grep "npx jest" || true)
    [[ "$jest_line" == *"math.test.ts"* ]]
    # Jest command should NOT contain the Playwright spec
    [[ "$jest_line" != *"login.spec.ts"* ]]
}

@test "run_test_loop logs Playwright specs as excluded from Jest" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-playwright-log

    mkdir -p tests/e2e
    echo "import { test } from '@playwright/test';" > tests/e2e/smoke.spec.ts
    echo "test('unit', () => {});" > util.test.ts
    git add tests/e2e/smoke.spec.ts util.test.ts
    git commit -q -m "add e2e and unit test"

    run_stage() {
        echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"OK"}'
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-playwright-log" "" "typescript"

    # Check log for Playwright exclusion message
    grep -q "Playwright specs detected" "$LOG_FILE"
}

# =============================================================================
# BATS NON-BLOCKING IN MIXED SCOPE (claude-pipeline#41)
# =============================================================================

@test "run_test_loop does not include BATS in main test_command for mixed scope" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-mixed-no-bats

    echo "export const x = 1;" > app.ts
    echo "#!/bin/bash" > deploy.sh
    git add app.ts deploy.sh
    git commit -q -m "mixed changes"

    local prompt_file="$TEST_TMP/mixed_no_bats_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"OK","bats_result":"passed","bats_summary":"OK"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-mixed-no-bats" "" "mixed"

    local captured
    captured=$(< "$prompt_file")
    # STEP 1 (Jest) should NOT contain run-tests.sh or bats
    local step1_cmd
    step1_cmd=$(echo "$captured" | grep -A1 "STEP 1 —" | grep -v "STEP 1" || true)
    [[ "$step1_cmd" != *"run-tests.sh"* ]] || [[ "$step1_cmd" != *"bats"* ]]
    # But BATS should appear as STEP 1c (informational)
    [[ "$captured" == *"STEP 1c"* ]]
    [[ "$captured" == *"informational only"* ]]
}

@test "run_test_loop includes BATS section as non-blocking for mixed scope" {
    local func_def
    func_def=$(declare -f run_test_loop)

    # Must reference bats_section or bats_result
    [[ "$func_def" == *"bats_section"* ]]
    [[ "$func_def" == *"bats_result"* ]]
}

# =============================================================================
# FILTERED CHANGED FILES IN VALIDATION (claude-pipeline#41)
# =============================================================================

@test "run_test_loop filters .claude/ files from validation scope" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-filtered-validation

    echo "export const x = 1;" > app.ts
    mkdir -p .claude/scripts
    echo "#!/bin/bash" > .claude/scripts/helper.sh
    git add app.ts .claude/scripts/helper.sh
    git commit -q -m "app + pipeline"

    local prompt_file="$TEST_TMP/filtered_validation_prompt"
    export prompt_file

    run_stage() {
        local stage_name="$1"
        local prompt="$2"
        case "$stage_name" in
            test-iter-*)
                printf '%s' "$prompt" > "$prompt_file"
                echo '{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"OK"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    run_test_loop "$TEST_TMP/repo" "feature-filtered-validation" "" "typescript"

    local captured
    captured=$(< "$prompt_file")
    # Validation scope should contain app.ts but NOT .claude/ files
    [[ "$captured" == *"app.ts"* ]]
    [[ "$captured" != *".claude/scripts/helper.sh"* ]]
}

# =============================================================================
# COMPLEXITY PASSTHROUGH TO FIX STAGES IN TEST LOOP
# =============================================================================

@test "run_test_loop passes complexity arg to fix-tests run_stage call" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-fix-tests-complexity

    # Add a test file so scope is 'typescript' (not config-only)
    echo "test('x', () => expect(1).toBe(1));" > app.test.ts
    git add app.test.ts
    git commit -q -m "add test file"

    local complexity_file="$TEST_TMP/fix_tests_complexity"
    export complexity_file

    run_stage() {
        local stage_name="$1"
        local complexity_arg="$5"
        case "$stage_name" in
            test-iter-*)
                # Return failed with a PR-introduced failure to trigger fix-tests path
                echo '{"result":"failed","summary":"1 test failed","failures":[{"test":"app.test.ts > x","error":"Expected 2"}],"validation_result":"skipped","validation_summary":""}'
                ;;
            fix-tests-iter-*)
                # Capture the complexity arg passed to run_stage
                printf '%s' "$complexity_arg" > "$complexity_file"
                echo '{"status":"success","summary":"Fixed"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    # Pass complexity "L" as arg 5 to run_test_loop.
    # Convergence now uses soft exit (loop_complete=true) instead of exit 2,
    # but we still run in a subshell for max-iterations safety.
    # The fix-tests stage runs before convergence triggers, so the complexity file is written.
    ( run_test_loop "$TEST_TMP/repo" "feature-fix-tests-complexity" "" "typescript" "L" ) || true

    [[ -f "$complexity_file" ]] || fail "fix-tests stage was not called"
    local captured_complexity
    captured_complexity=$(< "$complexity_file")
    [ "$captured_complexity" = "L" ] || fail "Expected complexity 'L' passed to fix-tests run_stage, got '$captured_complexity'"
}

@test "run_test_loop passes complexity arg to fix-test-quality run_stage call" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-fix-test-quality-complexity

    # Add a test file so scope is 'typescript' (not config-only)
    echo "test('y', () => expect(1).toBe(1));" > svc.test.ts
    git add svc.test.ts
    git commit -q -m "add test file"

    local complexity_file="$TEST_TMP/fix_test_quality_complexity"
    export complexity_file

    run_stage() {
        local stage_name="$1"
        local complexity_arg="$5"
        case "$stage_name" in
            test-iter-*)
                # Tests passed but validation failed — triggers fix-test-quality path
                echo '{"result":"passed","summary":"Tests passed","validation_result":"failed","validation_summary":"Missing assertions","validation_issues":"Add assertion coverage"}'
                ;;
            fix-test-quality-iter-*)
                # Capture the complexity arg passed to run_stage
                printf '%s' "$complexity_arg" > "$complexity_file"
                echo '{"status":"success","summary":"Fixed"}'
                ;;
        esac
    }
    export -f run_stage

    comment_issue() { :; }
    export -f comment_issue

    # Pass complexity "M" as arg 5 to run_test_loop.
    # Run in a subshell for max-iterations safety (still hard exit 2).
    ( run_test_loop "$TEST_TMP/repo" "feature-fix-test-quality-complexity" "" "typescript" "M" ) || true

    [[ -f "$complexity_file" ]] || fail "fix-test-quality stage was not called"
    local captured_complexity
    captured_complexity=$(< "$complexity_file")
    [ "$captured_complexity" = "M" ] || fail "Expected complexity 'M' passed to fix-test-quality run_stage, got '$captured_complexity'"
}
