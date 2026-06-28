#!/usr/bin/env bats
#
# test-helper-functions.bats
# Dedicated tests for detect_change_scope(), should_run_quality_loop(),
# and get_max_review_attempts() helper functions.
#
# These tests focus on additional edge cases and integration behaviours
# not covered by existing test files.
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
# detect_change_scope() — additional extension coverage
# =============================================================================

@test "detect_change_scope returns 'typescript' for .mjs files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-mjs
    echo "export const x = 1;" > util.mjs
    git add util.mjs
    git commit -q -m "add mjs"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for .cjs files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-cjs
    echo "module.exports = {};" > util.cjs
    git add util.cjs
    git commit -q -m "add cjs"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'typescript' for .jsx files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-jsx
    echo "export default () => null;" > comp.jsx
    git add comp.jsx
    git commit -q -m "add jsx"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'config' for .toml files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-toml
    echo '[package]' > Cargo.toml
    git add Cargo.toml
    git commit -q -m "add toml"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'config' for .env files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-env
    echo "SECRET=abc" > .env
    git add .env
    git commit -q -m "add env"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'config' for .lock files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-lock
    echo "lockfileVersion: 1" > yarn.lock
    git add yarn.lock
    git commit -q -m "add lock"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'config' for .gitignore files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-gitignore
    echo "node_modules/" > .gitignore
    git add .gitignore
    git commit -q -m "add gitignore"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'bash' for .sh files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-bash
    echo "#!/usr/bin/env bash" > deploy.sh
    echo "echo hello" >> deploy.sh
    git add deploy.sh
    git commit -q -m "add sh"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'bash' for .bats files only" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-bats
    echo "#!/usr/bin/env bats" > test-foo.bats
    git add test-foo.bats
    git commit -q -m "add bats"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "bash" ]
}

@test "detect_change_scope returns 'config' for empty diff (no changed files)" {
    cd "$TEST_TMP/repo"
    # HEAD == base → no changed files
    local scope
    scope=$(detect_change_scope "." "main" 2>/dev/null)
    [ "$scope" = "config" ]
}

@test "detect_change_scope returns 'typescript' for unknown code files (.py)" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-python
    echo "x = 1" > script.py
    git add script.py
    git commit -q -m "add py"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "typescript" ]
}

@test "detect_change_scope returns 'mixed' for ts + sh + config files" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-mixed-with-config
    echo "export const x = 1;" > app.ts
    echo "#!/bin/bash" > deploy.sh
    echo "# changelog" > CHANGELOG.md
    git add app.ts deploy.sh CHANGELOG.md
    git commit -q -m "add ts sh and md"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$scope" = "mixed" ]
}

@test "detect_change_scope returns 0 exit status and valid scope on success" {
    cd "$TEST_TMP/repo"
    git checkout -q -b feature-exit-status
    echo "export const x = 1;" > app.ts
    git add app.ts
    git commit -q -m "add ts"

    local scope
    scope=$(detect_change_scope "." "main")
    [ "$?" -eq 0 ]
    [ "$scope" = "typescript" ]
}

# =============================================================================
# get_max_review_attempts() — edge cases
# =============================================================================

@test "get_max_review_attempts returns 1 for S-size" {
    local result
    result=$(get_max_review_attempts "S")
    [ "$result" -eq 1 ]
}

@test "get_max_review_attempts returns 2 for M-size" {
    local result
    result=$(get_max_review_attempts "M")
    [ "$result" -eq 2 ]
}

@test "get_max_review_attempts returns 3 for L-size" {
    local result
    result=$(get_max_review_attempts "L")
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for lowercase 's' (safe default)" {
    local result
    result=$(get_max_review_attempts "s" 2>/dev/null)
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for lowercase 'm' (safe default)" {
    local result
    result=$(get_max_review_attempts "m" 2>/dev/null)
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for lowercase 'l' (safe default)" {
    local result
    result=$(get_max_review_attempts "l" 2>/dev/null)
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts returns 3 for numeric string input (safe default)" {
    local result
    result=$(get_max_review_attempts "2" 2>/dev/null)
    [ "$result" -eq 3 ]
}

@test "get_max_review_attempts output is numeric (integer-comparable)" {
    local result
    result=$(get_max_review_attempts "M")
    # Arithmetic comparison fails if result is not a number
    [ "$result" -gt 0 ]
}

# =============================================================================
# should_run_quality_loop() — additional behaviours
# =============================================================================

@test "should_run_quality_loop returns 1 for S (same as get_max_review_attempts == 1)" {
    run should_run_quality_loop "S"
    [ "$status" -eq 1 ]
}

@test "should_run_quality_loop returns 0 for M (max_attempts > 1)" {
    run should_run_quality_loop "M"
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop returns 0 for L (max_attempts > 1)" {
    run should_run_quality_loop "L"
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop agrees with get_max_review_attempts for S: both indicate skip" {
    # get_max_review_attempts S == 1 means should_run_quality_loop S returns 1 (skip)
    local max
    max=$(get_max_review_attempts "S")
    run should_run_quality_loop "S"
    [ "$max" -eq 1 ]
    [ "$status" -eq 1 ]
}

@test "should_run_quality_loop agrees with get_max_review_attempts for M: both indicate run" {
    # get_max_review_attempts M == 2 means should_run_quality_loop M returns 0 (run)
    local max
    max=$(get_max_review_attempts "M")
    run should_run_quality_loop "M"
    [ "$max" -gt 1 ]
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop agrees with get_max_review_attempts for L: both indicate run" {
    local max
    max=$(get_max_review_attempts "L")
    run should_run_quality_loop "L"
    [ "$max" -gt 1 ]
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop returns 0 (run) for unrecognised size — safe default" {
    run should_run_quality_loop "XL"
    [ "$status" -eq 0 ]
}

@test "should_run_quality_loop returns 0 (run) for empty size — safe default" {
    run should_run_quality_loop ""
    [ "$status" -eq 0 ]
}

# =============================================================================
# is_stage_timeout() — timeout detection helper
# =============================================================================

# is_stage_timeout consumes the stage_result envelope (issue #178 PR-A).
# Envelope shape: {status, output, raw, denials, model, error_kind, elapsed_ms}.
# Timeout is signalled by status=="error" AND error_kind=="timeout".
@test "is_stage_timeout returns 0 (true) for timeout error JSON" {
    run is_stage_timeout '{"status":"error","output":null,"error_kind":"timeout"}'
    [ "$status" -eq 0 ]
}

@test "is_stage_timeout returns 1 (false) for successful result" {
    run is_stage_timeout '{"status":"success","output":{"result":"passed","summary":"All tests passed"},"error_kind":null}'
    [ "$status" -eq 1 ]
}

@test "is_stage_timeout returns 1 (false) for non-timeout error" {
    run is_stage_timeout '{"status":"error","output":null,"error_kind":"no_structured_output"}'
    [ "$status" -eq 1 ]
}

@test "is_stage_timeout returns 1 (false) for empty string" {
    run is_stage_timeout ''
    [ "$status" -eq 1 ]
}

@test "is_stage_timeout returns 1 (false) for schema-not-found error" {
    run is_stage_timeout '{"status":"error","output":null,"error_kind":"schema_not_found"}'
    [ "$status" -eq 1 ]
}

# =============================================================================
# _build_bash_test_command() — bash_test_command construction
# =============================================================================

@test "_build_bash_test_command uses run-tests.sh when it exists" {
    mkdir -p "$TEST_TMP/.claude/scripts/implement-issue-test"
    touch "$TEST_TMP/.claude/scripts/implement-issue-test/run-tests.sh"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    [ "$result" = "bash .claude/scripts/implement-issue-test/run-tests.sh" ]
}

@test "_build_bash_test_command falls back to bats glob when run-tests.sh absent" {
    # Mock bats without --jobs support to test serial fallback
    cat > "$TEST_TMP/bin/bats" << 'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--help" ]] && { printf 'Usage: bats [OPTIONS] <tests>\n'; exit 0; }
exit 0
EOF
    chmod +x "$TEST_TMP/bin/bats"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    [ "$result" = "bats .claude/scripts/implement-issue-test/*.bats" ]
}

@test "_build_bash_test_command includes tests/*.bats suffix when tests dir has bats files" {
    # Mock bats without --jobs support to test serial fallback
    cat > "$TEST_TMP/bin/bats" << 'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--help" ]] && { printf 'Usage: bats [OPTIONS] <tests>\n'; exit 0; }
exit 0
EOF
    chmod +x "$TEST_TMP/bin/bats"

    mkdir -p "$TEST_TMP/.claude/scripts/implement-issue-test"
    touch "$TEST_TMP/.claude/scripts/implement-issue-test/run-tests.sh"
    mkdir -p "$TEST_TMP/tests"
    touch "$TEST_TMP/tests/foo.bats"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    [[ "$result" == *"&& bats tests/*.bats" ]]
}

@test "_build_bash_test_command does not include tests/*.bats when tests dir is absent" {
    mkdir -p "$TEST_TMP/.claude/scripts/implement-issue-test"
    touch "$TEST_TMP/.claude/scripts/implement-issue-test/run-tests.sh"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    [[ "$result" != *"&& bats tests/*.bats"* ]]
}

@test "_build_bash_test_command does not include tests/*.bats when tests dir exists but holds no bats files" {
    mkdir -p "$TEST_TMP/.claude/scripts/implement-issue-test"
    touch "$TEST_TMP/.claude/scripts/implement-issue-test/run-tests.sh"
    mkdir -p "$TEST_TMP/tests"
    touch "$TEST_TMP/tests/helper.sh"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    [[ "$result" != *"&& bats tests/*.bats"* ]]
}

@test "_build_bash_test_command produces full expected string with run-tests.sh and tests dir" {
    # Mock bats without --jobs support to test serial fallback
    cat > "$TEST_TMP/bin/bats" << 'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--help" ]] && { printf 'Usage: bats [OPTIONS] <tests>\n'; exit 0; }
exit 0
EOF
    chmod +x "$TEST_TMP/bin/bats"

    mkdir -p "$TEST_TMP/.claude/scripts/implement-issue-test"
    touch "$TEST_TMP/.claude/scripts/implement-issue-test/run-tests.sh"
    mkdir -p "$TEST_TMP/tests"
    touch "$TEST_TMP/tests/lint.bats"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    [ "$result" = "bash .claude/scripts/implement-issue-test/run-tests.sh && bats tests/*.bats" ]
}

@test "_build_bash_test_command produces full expected string with bats glob fallback and tests dir" {
    # Mock bats without --jobs support to test serial fallback
    cat > "$TEST_TMP/bin/bats" << 'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--help" ]] && { printf 'Usage: bats [OPTIONS] <tests>\n'; exit 0; }
exit 0
EOF
    chmod +x "$TEST_TMP/bin/bats"

    mkdir -p "$TEST_TMP/tests"
    touch "$TEST_TMP/tests/lint.bats"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    [ "$result" = "bats .claude/scripts/implement-issue-test/*.bats && bats tests/*.bats" ]
}

# =============================================================================
# _build_bash_test_command() — parallel bats (--jobs) support
# =============================================================================

@test "_build_bash_test_command uses parallel bats when bats supports --jobs" {
    # Mock bats with --jobs support
    cat > "$TEST_TMP/bin/bats" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' "Usage: bats [OPTIONS] <tests>" \
        "  -j, --jobs <jobs>  Number of parallel jobs"
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_TMP/bin/bats"

    # Mock parallel so the --jobs backend guard passes
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/parallel"
    chmod +x "$TEST_TMP/bin/parallel"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    # cpu_count is evaluated at runtime (nproc / sysctl / 4 fallback)
    [[ "$result" == *" --jobs "* ]] || \
        fail "Expected '--jobs' in command. Got: $result"
    [[ "$result" == *".claude/scripts/implement-issue-test/"*".bats" ]] || \
        fail "Expected pipeline bats suite in command. Got: $result"
}

@test "_build_bash_test_command appends parallel bats to tests/*.bats when --jobs supported" {
    # Mock bats with --jobs support
    cat > "$TEST_TMP/bin/bats" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' "Usage: bats [OPTIONS] <tests>" \
        "  -j, --jobs <jobs>  Number of parallel jobs"
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_TMP/bin/bats"

    # Mock parallel so the --jobs backend guard passes
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/parallel"
    chmod +x "$TEST_TMP/bin/parallel"

    mkdir -p "$TEST_TMP/tests"
    touch "$TEST_TMP/tests/foo.bats"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    # cpu_count is evaluated at runtime; just confirm --jobs precedes tests/*.bats
    [[ "$result" == *"&& bats --jobs "* ]] || \
        fail "Expected '&& bats --jobs' suffix. Got: $result"
    [[ "$result" == *" tests/"*".bats" ]] || \
        fail "Expected 'tests/*.bats' in command. Got: $result"
}

@test "_build_bash_test_command uses plain bats when bats does not support --jobs" {
    # Mock bats without --jobs in help output
    cat > "$TEST_TMP/bin/bats" << 'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--help" ]] && { printf 'Usage: bats [OPTIONS] <tests>\n'; exit 0; }
exit 0
EOF
    chmod +x "$TEST_TMP/bin/bats"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    [ "$result" = "bats .claude/scripts/implement-issue-test/*.bats" ]
}

@test "_build_bash_test_command run-tests.sh used but appended tests use parallel bats when --jobs supported" {
    # Mock bats with --jobs support
    cat > "$TEST_TMP/bin/bats" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
    printf '%s\n' "Usage: bats [OPTIONS] <tests>" \
        "  -j, --jobs <jobs>  Number of parallel jobs"
    exit 0
fi
exit 0
EOF
    chmod +x "$TEST_TMP/bin/bats"

    # Mock parallel so the --jobs backend guard passes
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_TMP/bin/parallel"
    chmod +x "$TEST_TMP/bin/parallel"

    mkdir -p "$TEST_TMP/.claude/scripts/implement-issue-test"
    touch "$TEST_TMP/.claude/scripts/implement-issue-test/run-tests.sh"
    mkdir -p "$TEST_TMP/tests"
    touch "$TEST_TMP/tests/lint.bats"

    local result
    result=$(_build_bash_test_command "$TEST_TMP")
    # run-tests.sh prefix is unchanged; cpu_count is runtime-evaluated
    [[ "$result" == "bash .claude/scripts/implement-issue-test/run-tests.sh && bats --jobs "* ]] || \
        fail "Expected run-tests.sh prefix with parallel bats. Got: $result"
    [[ "$result" == *" tests/"*".bats" ]] || \
        fail "Expected 'tests/*.bats' in command. Got: $result"
}

