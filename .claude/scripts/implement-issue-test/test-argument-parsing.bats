#!/usr/bin/env bats
#
# test-argument-parsing.bats
# Tests for implement-issue-orchestrator.sh argument parsing
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    # Create minimal schema so the script can start
    echo '{}' > "$TEST_TMP/schemas/implement-issue-setup.json"
    # Set GITHUB_REPO so valid-arg tests pass repo detection
    export GITHUB_REPO="test-owner/test-repo"
}

teardown() {
    teardown_test_env
}

# =============================================================================
# REQUIRED ARGUMENTS
# =============================================================================

@test "fails without any arguments" {
    run bash "$ORCHESTRATOR_SCRIPT" 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue and --branch are required"* ]]
}

@test "fails with only --issue" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue and --branch are required"* ]]
}

@test "fails with only --branch" {
    run bash "$ORCHESTRATOR_SCRIPT" --branch test 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue and --branch are required"* ]]
}

@test "fails with --issue but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--issue requires a value"* ]]
}

@test "fails with --branch but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--branch requires a value"* ]]
}

# =============================================================================
# OPTIONAL ARGUMENTS
# =============================================================================

@test "accepts --agent option" {
    # Run with timeout so the script doesn't hang past the header.
    # We only care that the header reflects the parsed --agent value.
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --agent fastify-backend-developer 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Agent: fastify-backend-developer"* ]]
}

@test "fails with --agent but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --agent 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--agent requires a value"* ]]
}

@test "accepts --status-file option" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --status-file custom-status.json 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Status file: custom-status.json"* ]]
}

@test "fails with --status-file but no value" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --status-file 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"--status-file requires a value"* ]]
}

# =============================================================================
# HELP
# =============================================================================

@test "--help shows usage" {
    run bash "$ORCHESTRATOR_SCRIPT" --help 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"--issue"* ]]
    [[ "$output" == *"--branch"* ]]
}

@test "-h shows usage" {
    run bash "$ORCHESTRATOR_SCRIPT" -h 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# UNKNOWN OPTIONS
# =============================================================================

@test "fails with unknown option" {
    run bash "$ORCHESTRATOR_SCRIPT" --unknown 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" == *"Unknown option: --unknown"* ]]
}

# =============================================================================
# VALID INVOCATION OUTPUT
# =============================================================================

@test "prints issue number in header" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 456 --branch main 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Issue: #456"* ]]
}

@test "prints branch name in header" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch feature-branch 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Branch: feature-branch"* ]]
}

@test "defaults agent to 'default' when not specified" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Agent: default"* ]]
}

@test "defaults status file to status.json" {
    run timeout 2 bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test 2>&1
    [ -n "$output" ]
    [[ "$output" == *"Status file: status.json"* ]]
}

# =============================================================================
# --quiet FLAG
# =============================================================================

@test "--quiet flag is accepted without error" {
    run bash "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --quiet --help 2>&1
    [ "$status" -eq 3 ]
    [[ "$output" != *"Unknown option: --quiet"* ]]
}

@test "--quiet flag does not appear as unknown option" {
    run bash "$ORCHESTRATOR_SCRIPT" --quiet 2>&1
    # --quiet without required args still fails, but NOT as unknown option
    [ "$status" -ne 0 ]
    [[ "$output" != *"Unknown option: --quiet"* ]]
}
