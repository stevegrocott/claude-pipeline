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
# detect_change_scope() .claude/scripts/ ROUTING
# These tests verify fix for: .claude/scripts/*.sh and *.bats files must route
# to has_bash=true, not be silently skipped as "pipeline files".
# =============================================================================

@test "detect_change_scope returns 'bash' for .claude/scripts/*.sh" {
	cd "$TEST_TMP/repo"
	git checkout -q -b feature-claude-scripts-sh
	mkdir -p .claude/scripts
	printf '#!/usr/bin/env bash\n' > .claude/scripts/my-script.sh
	git add .claude/scripts/my-script.sh
	git commit -q -m "add .claude/scripts script"

	local scope
	scope=$(detect_change_scope "." "main")
	[ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .claude/scripts/ subdirectory .sh" {
	cd "$TEST_TMP/repo"
	git checkout -q -b feature-claude-scripts-subdir-sh
	mkdir -p .claude/scripts/implement-issue-test
	printf '#!/usr/bin/env bash\n' \
		> .claude/scripts/implement-issue-test/helper.sh
	git add .claude/scripts/implement-issue-test/helper.sh
	git commit -q -m "add nested .claude/scripts script"

	local scope
	scope=$(detect_change_scope "." "main")
	[ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .claude/scripts/*.bats" {
	cd "$TEST_TMP/repo"
	git checkout -q -b feature-claude-scripts-bats
	mkdir -p .claude/scripts/implement-issue-test
	printf "@test 'hello' { true; }\n" \
		> .claude/scripts/implement-issue-test/test-foo.bats
	git add .claude/scripts/implement-issue-test/test-foo.bats
	git commit -q -m "add .claude/scripts bats"

	local scope
	scope=$(detect_change_scope "." "main")
	[ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .claude/hooks/*.sh files" {
	cd "$TEST_TMP/repo"
	git checkout -q -b feature-claude-hooks-sh
	mkdir -p .claude/hooks
	printf '#!/usr/bin/env bash\n' > .claude/hooks/pre-commit.sh
	git add .claude/hooks/pre-commit.sh
	git commit -q -m "add .claude/hooks script"

	local scope
	scope=$(detect_change_scope "." "main")
	[ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .claude/config/*.sh files" {
	cd "$TEST_TMP/repo"
	git checkout -q -b feature-claude-config-sh
	mkdir -p .claude/config
	printf '#!/usr/bin/env bash\n' > .claude/config/setup.sh
	git add .claude/config/setup.sh
	git commit -q -m "add .claude/config script"

	local scope
	scope=$(detect_change_scope "." "main")
	[ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .claude/hooks/hook.sh" {
	cd "$TEST_TMP/repo"
	git checkout -q -b feature-claude-hooks-hook-sh
	mkdir -p .claude/hooks
	printf '#!/usr/bin/env bash\n' > .claude/hooks/hook.sh
	git add .claude/hooks/hook.sh
	git commit -q -m "add .claude/hooks/hook.sh"

	local scope
	scope=$(detect_change_scope "." "main")
	[ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .claude/config/platform.sh" {
	cd "$TEST_TMP/repo"
	git checkout -q -b feature-claude-config-platform-sh
	mkdir -p .claude/config
	printf '#!/usr/bin/env bash\n' > .claude/config/platform.sh
	git add .claude/config/platform.sh
	git commit -q -m "add .claude/config/platform.sh"

	local scope
	scope=$(detect_change_scope "." "main")
	[ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .claude/scripts/platform/*.sh" {
	cd "$TEST_TMP/repo"
	git checkout -q -b feature-claude-platform-sh
	mkdir -p .claude/scripts/platform
	printf '#!/usr/bin/env bash\n' > .claude/scripts/platform/foo.sh
	git add .claude/scripts/platform/foo.sh
	git commit -q -m "add .claude/scripts/platform script"

	local scope
	scope=$(detect_change_scope "." "main")
	[ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .claude/scripts/implement-issue-test/*.bats" {
	cd "$TEST_TMP/repo"
	git checkout -q -b feature-claude-iit-foo-bats
	mkdir -p .claude/scripts/implement-issue-test
	printf "@test 'hello' { true; }\n" \
		> .claude/scripts/implement-issue-test/foo.bats
	git add .claude/scripts/implement-issue-test/foo.bats
	git commit -q -m "add .claude/scripts/implement-issue-test bats"

	local scope
	scope=$(detect_change_scope "." "main")
	[ "$scope" = "bash" ]
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

    # Add an implementation file and a test file that exercises it
    echo "export const add = (a, b) => a + b;" > math.ts
    echo "import { add } from './math';
test('adds', () => expect(add(2, 3)).toBe(5));" > math.test.ts
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

    # Add a TS implementation file, a test file that exercises it, and a
    # bash script
    echo "export const add = (a, b) => a + b;" > math.ts
    echo "import { add } from './math';
test('adds', () => expect(add(2, 3)).toBe(5));" > math.test.ts
    echo "#!/bin/bash" > deploy.sh
    git add math.ts math.test.ts deploy.sh
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
                    echo '{"status":"success","output":{"result":"failed","failures":[{"test":"failing.test","message":"PR introduced failure"}],"summary":"1 PR failure","validation_result":"skipped"}}'
                else
                    echo '{"status":"success","output":{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated"}}'
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

@test "_matches_frontend_pattern is not corrupted by matching files on disk" {
    # Regression test: the pattern loop iterates over an unquoted,
    # word-split expansion of FRONTEND_PATH_PATTERNS. Without `set -f`,
    # a glob pattern that happens to match real files in the cwd gets
    # replaced by those literal filenames before the case match runs —
    # so the loop variable is no longer the intended glob at all.
    export FRONTEND_PATH_PATTERNS="web/src/components/*"
    mkdir -p web/src/components
    touch web/src/components/Alpha.tsx

    # Beta.tsx does not exist on disk, but it still falls under the
    # web/src/components/* glob and must be reported as a match.
    run _matches_frontend_pattern "web/src/components/Beta.tsx"
    [ "$status" -eq 0 ] || fail \
        "pattern should match Beta.tsx even though only Alpha.tsx exists on disk"
}

@test "_matches_frontend_pattern restores globbing on every exit path" {
    export FRONTEND_PATH_PATTERNS="web/src/components/*"
    mkdir -p web/src/components
    touch web/src/components/Alpha.tsx

    # Call directly (not via `run`) so any leaked `set -f` would affect
    # this shell.
    _matches_frontend_pattern "web/src/components/Alpha.tsx"

    case "$-" in
        *f*) fail "set -f (noglob) leaked out of _matches_frontend_pattern" ;;
    esac

    # A non-matching call (early-return path) must restore it too.
    unset FRONTEND_PATH_PATTERNS
    _matches_frontend_pattern "web/src/components/Alpha.tsx" || true

    case "$-" in
        *f*) fail "set -f (noglob) leaked out of the empty-pattern exit path" ;;
    esac
}

# =============================================================================
# _matches_frontend_pattern() DISK-PREFIX REGRESSION TESTS (issue #650)
#
# The existing cases above all use a "web/..." prefix that never exists on
# disk in the test sandbox, so an unquoted pattern list has nothing to
# pathname-expand and the bug stays invisible. These cases create the
# pattern's prefix directory for real (cwd is $TEST_TMP/repo, a git repo)
# so a regression to unquoted expansion is caught: bash would replace the
# pattern with literal directory entries before `case` ever sees it, and
# any nested path would silently stop matching.
# =============================================================================

@test "_matches_frontend_pattern matches a nested path when the pattern's prefix exists on disk" {
    export FRONTEND_PATH_PATTERNS="apps/frontend/*"

    mkdir -p apps/frontend/src/components apps/backend
    touch apps/frontend/components.json apps/frontend/Containerfile

    run _matches_frontend_pattern "apps/frontend/src/components/Foo.tsx"
    [ "$status" -eq 0 ] || fail \
        "nested path under an on-disk prefix should match; got status $status"
}

@test "_matches_frontend_pattern still matches a top-level path when the prefix exists on disk" {
    export FRONTEND_PATH_PATTERNS="apps/frontend/*"

    mkdir -p apps/frontend/src/components apps/backend
    touch apps/frontend/components.json apps/frontend/Containerfile

    run _matches_frontend_pattern "apps/frontend/components.json"
    [ "$status" -eq 0 ] || fail \
        "top-level path under an on-disk prefix should match; got status $status"
}

@test "_matches_frontend_pattern still rejects a non-matching path when the prefix exists on disk" {
    export FRONTEND_PATH_PATTERNS="apps/frontend/*"

    mkdir -p apps/frontend/src/components apps/backend/src/routes
    touch apps/frontend/components.json apps/frontend/Containerfile

    run _matches_frontend_pattern "apps/backend/src/routes/crops.ts"
    [ "$status" -eq 1 ] || fail \
        "non-matching path should still be rejected; got status $status"
}

@test "_matches_frontend_pattern restores pathname expansion after a match" {
    export FRONTEND_PATH_PATTERNS="apps/frontend/*"

    mkdir -p apps/frontend/src/components
    touch apps/frontend/components.json apps/frontend/Containerfile

    # Not wrapped in `run`: a direct non-zero return would fail the test
    # body itself, and only the post-call shell option state (`$-`) is
    # under test here — the match outcome is covered separately above.
    _matches_frontend_pattern "apps/frontend/src/components/Foo.tsx" || true

    [[ "$-" != *f* ]] || fail \
        "globbing (set -f) should be restored after a matching call"
}

@test "_matches_frontend_pattern restores pathname expansion after a non-match" {
    export FRONTEND_PATH_PATTERNS="apps/frontend/*"

    mkdir -p apps/frontend/src/components apps/backend
    touch apps/frontend/components.json apps/frontend/Containerfile

    # Not wrapped in `run`: a direct non-zero return would fail the test
    # body itself, and only the post-call shell option state (`$-`) is
    # under test here — the reject outcome is covered separately above.
    _matches_frontend_pattern "apps/backend/index.ts" || true

    [[ "$-" != *f* ]] || fail \
        "globbing (set -f) should be restored after a non-matching call"
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
# ISSUE #659: detect_change_scope() + e2e_verify STAGE SELECTION INTEGRATION
# (AC3/AC4 of issue #650's fix, PR #656)
#
# The _matches_frontend_pattern() glob-corruption bug (fixed in #656) let an
# unquoted `for pattern in $FRONTEND_PATH_PATTERNS` expansion get
# pathname-expanded against files that already existed on disk under the
# pattern's own prefix, silently replacing the intended glob with literal
# filenames before a nested path was ever compared. That misclassified a
# nested frontend file as non-frontend, and because bash/.sh extensions are
# checked independently of the frontend match, the file fell through to
# scope=bash — which in turn made run_parallel_post_task_stages() SKIP
# e2e_verify instead of running it.
#
# This test drives both detect_change_scope() and the real
# run_parallel_post_task_stages() skip-condition logic end-to-end, using an
# on-disk prefix (mirroring the #650 regression setup) so any regression to
# unquoted glob expansion would be caught here too.
# =============================================================================

# Install spies around run_parallel_post_task_stages() so the stage-selection
# decision is observable without running any real agent, container rebuild, or
# issue comment. Every call is appended to $1 as a "kind:value" line so tests
# can assert on ORDER, not just presence.
#
# Only the stage's collaborators are stubbed — the skip/run decision logic
# under test is the real orchestrator code.
_install_e2e_stage_spies() {
    local calls_file="$1"
    : > "$calls_file"
    export E2E_SPY_CALLS="$calls_file"

    is_stage_completed()   { return 1; }
    set_stage_started()    { printf 'started:%s\n'   "$1" >> "$E2E_SPY_CALLS"; }
    set_stage_completed()  { printf 'completed:%s\n' "$1" >> "$E2E_SPY_CALLS"; }
    log()                  { printf 'log:%s\n' "$*"  >> "$E2E_SPY_CALLS"; }
    log_warn()             { printf 'log:%s\n' "$*"  >> "$E2E_SPY_CALLS"; }
    log_error()            { printf 'log:%s\n' "$*"  >> "$E2E_SPY_CALLS"; }
    comment_issue()            { :; }
    verify_on_feature_branch() { return 0; }
    rebuild_and_health_check() {
        printf '{"rebuild":"skipped","health":"skipped","elapsed_secs":0}'
    }
    _build_targeted_e2e_cmd()  { printf '%s' "$TEST_E2E_CMD"; }

    # Shape must match what the orchestrator parses (.output.result /
    # .output.summary); a flat object would read back as null and mask a
    # regression in the result handling.
    #
    # $2/$3/$4 (prompt/schema/agent) are captured to sidecar files rather
    # than appended to $E2E_SPY_CALLS: the prompt is multi-line, and folding
    # it into the calls file would corrupt the "one call = one line"
    # ordering assertions that key off run_stage:e2e-verify. Sidecar files
    # keep those assertions intact while still letting callers verify the
    # real args the orchestrator hands to run_stage for e2e_verify.
    run_stage() {
        printf 'run_stage:%s\n' "$1" >> "$E2E_SPY_CALLS"
        printf '%s' "$2" > "$E2E_SPY_CALLS.prompt"
        printf '%s' "$3" > "$E2E_SPY_CALLS.schema"
        printf '%s' "$4" > "$E2E_SPY_CALLS.agent"
        printf '{"output":{"result":"passed","summary":"e2e ok"}}'
    }
}

# Read a prompt/schema/agent sidecar file written by the run_stage() spy
# above. A missing sidecar means the spy's run_stage() was never invoked at
# all (e2e_verify was skipped, or the orchestrator called run_stage with a
# different stage first) -- reading it with plain `$(< file)` would instead
# fail silently, returning an empty string that only surfaces later as a
# confusing "got ''" mismatch against the expected value. Fail here with the
# missing path and the reason, so the real cause is obvious immediately.
_read_e2e_sidecar() {
    local calls_file="$1"
    local kind="$2"
    local sidecar="$calls_file.$kind"
    local msg

    if [ ! -f "$sidecar" ]; then
        msg="missing $kind sidecar file '$sidecar' -- run_stage() was"
        msg+=" never invoked for e2e-verify (the stage likely didn't run)"
        fail "$msg"
        return 1
    fi

    cat "$sidecar"
}

# Shared assertion logic for the 'frontend' and 'ts-frontend' e2e_verify
# skip-guard test cases below. The skip guard in
# run_parallel_post_task_stages() checks
# `branch_scope != "frontend" && branch_scope != "ts-frontend"`, so both
# scopes must exercise the exact same run/ordering/schema/agent
# assertions -- only the branch name, scope, and calls file differ per
# test. Callers that need additional scope-specific assertions (e.g. the
# 'frontend' test's prompt-content checks) can read $calls_file again
# afterward via _read_e2e_sidecar().
_assert_e2e_verify_runs_for_scope() {
    local branch_name="$1"
    local scope="$2"
    local calls_file="$3"

    export TEST_E2E_CMD="npx playwright test"
    export BASE_BRANCH=main
    unset RESUME_MODE

    _install_e2e_stage_spies "$calls_file"

    local exit_code=0
    run_parallel_post_task_stages \
        "$branch_name" "$scope" "minimal" "S" || exit_code=$?
    [ "$exit_code" -eq 0 ] || fail \
        "run_parallel_post_task_stages exited $exit_code, expected 0"

    # ORDERING, not mere presence: the skip path also emits
    # started:e2e_verify followed immediately by completed:e2e_verify, so
    # grepping for those alone would pass even when the stage is skipped.
    # Requiring run_stage:e2e-verify BETWEEN them is only satisfiable by
    # the real run path.
    local sequence expected run_msg
    sequence=$(tr '\n' ' ' < "$calls_file")
    expected='*started:e2e_verify*run_stage:e2e-verify*completed:e2e_verify*'
    run_msg="e2e_verify was skipped for scope '$scope', expected it to"
    run_msg+=" run. Call sequence: $sequence"
    # shellcheck disable=SC2254
    [[ "$sequence" == $expected ]] || fail "$run_msg"

    # The orchestrator must hand run_stage the real e2e-validate schema and
    # the playwright-test-developer agent for this scope -- not just call
    # it with any args. A regression that swapped in the wrong
    # schema/agent (or lost them) would still satisfy the "run_stage was
    # called" assertion above, so assert the actual $3/$4 values captured
    # by the spy.
    local captured_schema captured_agent
    captured_schema=$(_read_e2e_sidecar "$calls_file" schema) || return 1
    captured_agent=$(_read_e2e_sidecar "$calls_file" agent) || return 1

    [ "$captured_schema" = "implement-issue-e2e-validate.json" ] || fail \
        "expected schema implement-issue-e2e-validate.json, got '$captured_schema'"
    [ "$captured_agent" = "playwright-test-developer" ] || fail \
        "expected agent playwright-test-developer, got '$captured_agent'"

    # Structural skip marker: every skip branch records started:e2e_verify
    # immediately followed by completed:e2e_verify with no run_stage call
    # between them (see the skip-handling block in
    # run_parallel_post_task_stages()). Assert that adjacent pair is
    # absent instead of matching any particular log wording -- its
    # presence would mean a skip branch fired even though the ordering
    # check above passed.
    local skip_msg
    skip_msg="e2e_verify hit a skip branch for scope '$scope' (started"
    skip_msg+=" immediately followed by completed, no run_stage in"
    skip_msg+=" between): $sequence"
    [[ "$sequence" != *'started:e2e_verify completed:e2e_verify'* ]] \
        || fail "$skip_msg"
}

@test "detect_change_scope classifies a nested frontend file as frontend (not bash), and e2e_verify runs instead of being skipped" {
    export FRONTEND_PATH_PATTERNS="web/e2e/*"

    cd "$TEST_TMP/repo"

    # Pre-populate sibling files under the pattern's own prefix on disk —
    # reproduces the exact conditions of the #650 glob-corruption bug.
    mkdir -p web/e2e/flows
    touch web/e2e/existing-spec.js

    git checkout -q -b feature-issue-659-e2e

    # A nested frontend file with a .sh extension: if _matches_frontend_pattern
    # regresses, this file's extension alone (*.sh) would classify it "bash"
    # instead of "frontend".
    printf '#!/usr/bin/env bash\nnpx playwright test login\n' \
        > web/e2e/flows/login-flow.sh
    git add web/e2e/flows/login-flow.sh
    git commit -q -m "add nested e2e flow script"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "frontend" ] || fail \
        "expected nested frontend file to classify as 'frontend', got '$scope'"

    # --- e2e_verify stage selection ------------------------------------
    # Feed the real computed scope into run_parallel_post_task_stages() and
    # assert the e2e-verify stage actually runs (calls run_stage) rather
    # than being marked skipped. See _assert_e2e_verify_runs_for_scope()
    # above for the shared run/ordering/schema/agent assertions -- also
    # exercised by the ts-frontend companion test below.
    local calls_file="$TEST_TMP/e2e-stage-calls.txt"
    _assert_e2e_verify_runs_for_scope \
        "feature-issue-659-e2e" "$scope" "$calls_file" || return 1

    # Prompt must actually be built from this run's context (issue number
    # and the targeted E2E command), not a stale/hardcoded string. This
    # check is specific to the 'frontend' scope (driven by the real
    # detect_change_scope output above), so it stays out of the shared
    # helper.
    local captured_prompt
    captured_prompt=$(_read_e2e_sidecar "$calls_file" prompt) || return 1

    [[ "$captured_prompt" == *"issue #$ISSUE_NUMBER"* ]] || fail \
        "expected prompt to reference issue #$ISSUE_NUMBER: $captured_prompt"
    [[ "$captured_prompt" == *"$TEST_E2E_CMD"* ]] || fail \
        "expected prompt to include the targeted E2E command '$TEST_E2E_CMD': $captured_prompt"
}

# Negative control for the test above. Without this, an e2e_verify stage
# that ran unconditionally (ignoring scope entirely) would still satisfy
# the positive assertions. A non-frontend nested path must still skip.
@test "detect_change_scope classifies a non-frontend nested file as bash, and e2e_verify is skipped" {
    export FRONTEND_PATH_PATTERNS="web/e2e/*"

    cd "$TEST_TMP/repo"
    mkdir -p tools/deploy
    git checkout -q -b feature-issue-659-nonfe

    printf '#!/usr/bin/env bash\necho deploy\n' > tools/deploy/release.sh
    git add tools/deploy/release.sh
    git commit -q -m "add deploy script"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "bash" ] || fail \
        "expected non-frontend .sh file to classify as 'bash', got '$scope'"

    export TEST_E2E_CMD="npx playwright test"
    export BASE_BRANCH=main
    unset RESUME_MODE

    local calls_file="$TEST_TMP/e2e-stage-calls-skip.txt"
    _install_e2e_stage_spies "$calls_file"

    local exit_code=0
    run_parallel_post_task_stages \
        "feature-issue-659-nonfe" "$scope" "minimal" "S" || exit_code=$?
    [ "$exit_code" -eq 0 ] || fail \
        "run_parallel_post_task_stages exited $exit_code, expected 0"

    if grep -q "^run_stage:e2e-verify$" "$calls_file"; then
        fail "e2e_verify ran for non-frontend scope '$scope' — it must skip"
    fi

    # Structural skip marker: a skipped stage records started:e2e_verify
    # immediately followed by completed:e2e_verify with no run_stage call
    # between them (see the skip-handling block in
    # run_parallel_post_task_stages()). Assert on that call-order marker
    # instead of matching the log message's exact wording.
    local sequence skip_msg
    sequence=$(tr '\n' ' ' < "$calls_file")
    skip_msg="expected e2e_verify to be skipped (started immediately"
    skip_msg+=" followed by completed, no run_stage call) for"
    skip_msg+=" non-frontend scope, got: $sequence"
    [[ "$sequence" == *'started:e2e_verify completed:e2e_verify'* ]] \
        || fail "$skip_msg"
}

# Companion coverage for the 'frontend' branch tested above: the skip guard
# in run_parallel_post_task_stages() checks
# `branch_scope != "frontend" && branch_scope != "ts-frontend"`, so a
# regression that dropped the "ts-frontend" arm would still pass every test
# above (they only ever exercise "frontend" and "bash") while silently
# skipping e2e_verify for TS+frontend projects. detect_change_scope's own
# mapping to "ts-frontend" is already covered elsewhere (see the TSX test
# above), so this test supplies the scope directly and asserts on the
# skip-guard's behavior in isolation.
@test "run_parallel_post_task_stages runs e2e_verify for ts-frontend scope (not just frontend)" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-issue-712-ts-frontend

    # See _assert_e2e_verify_runs_for_scope() above for the shared
    # run/ordering/schema/agent assertions -- same as the 'frontend' test.
    local calls_file="$TEST_TMP/e2e-stage-calls-ts-frontend.txt"
    _assert_e2e_verify_runs_for_scope \
        "feature-issue-712-ts-frontend" "ts-frontend" "$calls_file" \
        || return 1
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
                echo '{"status":"success","output":{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated","e2e_result":"passed","e2e_summary":"E2E passed"}}'
                ;;
        esac
    }
    export -f run_stage

    # E2E injection now gates on a successful container rebuild — stub it.
    rebuild_and_health_check() {
        echo '{"rebuild":"success","health":"healthy","elapsed_secs":1}'
    }
    export -f rebuild_and_health_check

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
                echo '{"status":"success","output":{"result":"passed","summary":"Tests passed","validation_result":"passed","validation_summary":"Validated","e2e_result":"passed","e2e_summary":"E2E passed"}}'
                ;;
        esac
    }
    export -f run_stage

    # E2E injection now gates on a successful container rebuild — stub it.
    rebuild_and_health_check() {
        echo '{"rebuild":"success","health":"healthy","elapsed_secs":1}'
    }
    export -f rebuild_and_health_check

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

@test "detect_change_scope returns 'bash' for .claude/scripts/*.sh files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-claude-sh
    mkdir -p .claude/scripts
    echo "#!/bin/bash" > .claude/scripts/helper.sh
    git add .claude/scripts/helper.sh
    git commit -q -m "add pipeline script"

    local scope
    scope=$(detect_change_scope "." "main")
    # .claude/scripts/ shell scripts MUST trigger bash scope (they have bats tests)
    [ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .claude/ bats files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-claude-bats
    mkdir -p .claude/scripts/implement-issue-test
    echo "@test 'hello' { true; }" > .claude/scripts/implement-issue-test/test-new.bats
    git add .claude/scripts/implement-issue-test/test-new.bats
    git commit -q -m "add pipeline test"

    local scope
    scope=$(detect_change_scope "." "main")
    # ALL bats files MUST trigger bash scope regardless of location
    [ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'mixed' when .claude/scripts/ and app TS files both change" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-claude-plus-ts
    mkdir -p .claude/scripts
    echo "#!/bin/bash" > .claude/scripts/helper.sh
    echo "export const x = 1;" > app.ts
    git add .claude/scripts/helper.sh app.ts
    git commit -q -m "add both"

    local scope
    scope=$(detect_change_scope "." "main")
    # Should be mixed: .claude/scripts/*.sh triggers bash + app.ts triggers typescript
    [ "$scope" = "mixed" ]
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
                echo '{"status":"success","output":{"result":"failed","summary":"1 test failed","failures":[{"test":"app.test.ts > x","error":"Expected 2"}],"validation_result":"skipped","validation_summary":""}}'
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
    # Max iterations uses soft-fail (DEGRADED_STAGES + break), but we still
    # run in a subshell for isolation.
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
                echo '{"status":"success","output":{"result":"passed","summary":"Tests passed","validation_result":"failed","validation_summary":"Missing assertions","validation_issues":"Add assertion coverage"}}'
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
    # Run in a subshell for isolation (max iterations uses soft-fail via DEGRADED_STAGES).
    ( run_test_loop "$TEST_TMP/repo" "feature-fix-test-quality-complexity" "" "typescript" "M" ) || true

    [[ -f "$complexity_file" ]] || fail "fix-test-quality stage was not called"
    local captured_complexity
    captured_complexity=$(< "$complexity_file")
    [ "$captured_complexity" = "M" ] || fail "Expected complexity 'M' passed to fix-test-quality run_stage, got '$captured_complexity'"
}

# =============================================================================
# RTK-REWRITE HOOK BEHAVIORAL TESTS (issue-381)
# Tests for .claude/hooks/rtk-rewrite.sh — the opt-in RTK command-rewrite hook.
# Hook contract:
#   - Reads PreToolUse JSON from stdin: {"tool_name":"Bash","tool_input":{"command":"..."}}
#   - No-ops (exit 0, empty stdout) when RTK_ENABLED != 1 or rtk binary is absent
#   - When enabled, rewrites allowlisted commands by prepending "rtk" and outputs
#     modified tool_input JSON; passes parse-sensitive and non-allowlisted commands
#     through unchanged (exit 0, empty stdout)
# =============================================================================

_rtk_hook() {
    echo "${BATS_TEST_DIRNAME}/../../hooks/rtk-rewrite.sh"
}

_rtk_bash_input() {
    local cmd="$1"
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$cmd"
}

_rtk_mock_bin() {
    mkdir -p "$TEST_TMP/bin"
    cat > "$TEST_TMP/bin/rtk" << 'EOF'
#!/usr/bin/env bash
echo "rtk-mock: $*"
EOF
    chmod +x "$TEST_TMP/bin/rtk"
}

@test "rtk-rewrite.sh hook file exists" {
    [[ -f "$(_rtk_hook)" ]]
}

@test "rtk-rewrite.sh hook is executable" {
    [[ -x "$(_rtk_hook)" ]]
}

@test "rtk-rewrite hook no-ops when RTK_ENABLED is unset" {
    local out exit_code
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
        | env -u RTK_ENABLED bash "$(_rtk_hook)" 2>/dev/null)
    exit_code=$?
    [ "$exit_code" -eq 0 ]
    [[ -z "$out" ]]
}

@test "rtk-rewrite hook no-ops when RTK_ENABLED=0" {
    local out exit_code
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
        | RTK_ENABLED=0 bash "$(_rtk_hook)" 2>/dev/null)
    exit_code=$?
    [ "$exit_code" -eq 0 ]
    [[ -z "$out" ]]
}

@test "rtk-rewrite hook no-ops when rtk binary absent even if RTK_ENABLED=1" {
    local out exit_code
    # Use a PATH that contains no rtk binary
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
        | RTK_ENABLED=1 PATH="/usr/bin:/bin" bash "$(_rtk_hook)" 2>/dev/null)
    exit_code=$?
    [ "$exit_code" -eq 0 ]
    [[ -z "$out" ]]
}

@test "rtk-rewrite hook no-ops for non-Bash tool calls" {
    _rtk_mock_bin
    local out exit_code
    out=$(printf '{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    exit_code=$?
    [ "$exit_code" -eq 0 ]
    [[ -z "$out" ]]
}

@test "rtk-rewrite hook rewrites 'git status' when enabled and rtk present" {
    _rtk_mock_bin
    local out
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    [ $? -eq 0 ]
    [[ "$out" == *"rtk git status"* ]]
}

@test "rtk-rewrite hook rewrites 'git diff' when enabled and rtk present" {
    _rtk_mock_bin
    local out
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git diff HEAD"}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    [ $? -eq 0 ]
    [[ "$out" == *"rtk git diff"* ]]
}

@test "rtk-rewrite hook rewrites 'ls' when enabled and rtk present" {
    _rtk_mock_bin
    local out
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    [ $? -eq 0 ]
    [[ "$out" == *"rtk ls"* ]]
}

@test "rtk-rewrite hook rewrites 'grep' when enabled and rtk present" {
    _rtk_mock_bin
    local out
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"grep -r pattern src/"}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    [ $? -eq 0 ]
    [[ "$out" == *"rtk grep"* ]]
}

@test "rtk-rewrite hook rewrites 'find' when enabled and rtk present" {
    _rtk_mock_bin
    local out
    # Use printf '%s' so the embedded \" escapes survive as literal backslash-quote
    # (a format-string printf drops them, yielding invalid JSON the hook rejects).
    out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"find . -name \"*.ts\""}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    [ $? -eq 0 ]
    [[ "$out" == *"rtk find"* ]]
}

@test "rtk-rewrite hook passes through non-allowlisted commands unchanged" {
    _rtk_mock_bin
    local out exit_code
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"npm run build"}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    exit_code=$?
    [ "$exit_code" -eq 0 ]
    [[ -z "$out" ]]
}

@test "rtk-rewrite hook passes through commands piped to jq (parse-sensitive)" {
    _rtk_mock_bin
    local out exit_code
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git status | jq ."}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    exit_code=$?
    [ "$exit_code" -eq 0 ]
    [[ -z "$out" ]]
}

@test "rtk-rewrite hook passes through commands piped to gh (parse-sensitive)" {
    _rtk_mock_bin
    local out exit_code
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git log | gh api /repos"}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    exit_code=$?
    [ "$exit_code" -eq 0 ]
    [[ -z "$out" ]]
}

@test "rtk-rewrite hook outputs valid JSON when rewriting a command" {
    _rtk_mock_bin
    local out
    out=$(printf '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
        | RTK_ENABLED=1 PATH="$TEST_TMP/bin:$PATH" bash "$(_rtk_hook)" 2>/dev/null)
    [ $? -eq 0 ]
    [[ -n "$out" ]]
    # Output must be valid JSON parseable by python3 or jq
    if command -v python3 &>/dev/null; then
        python3 -c "import json,sys; json.loads(sys.stdin.read())" <<< "$out"
    elif command -v jq &>/dev/null; then
        jq . <<< "$out" > /dev/null
    fi
}
