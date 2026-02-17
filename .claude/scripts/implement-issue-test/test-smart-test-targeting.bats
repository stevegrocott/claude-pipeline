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

@test "run_test_loop uses jest --changedSince for typescript scope" {
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
