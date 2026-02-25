#!/usr/bin/env bats
#
# test-create-issue.bats
# Tests for platform/create-issue.sh
#

load 'helpers/test-helper'

setup() {
    setup_test_env
    install_mocks
}

teardown() {
    teardown_test_env
}

# =============================================================================
# GITHUB MODE
# =============================================================================

@test "create-issue github: calls gh issue create and returns issue number" {
    export TRACKER="github"
    run run_platform_script create-issue.sh --title "Bug fix" --body "Fix the bug"
    [ "$status" -eq 0 ]
    [[ "$output" == *"42"* ]]
    assert_mock_called_with "gh issue create --title Bug fix --body Fix the bug"
}

@test "create-issue github: passes labels to gh" {
    export TRACKER="github"
    run run_platform_script create-issue.sh --title "Bug" --body "Body" --labels "bug,critical"
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh issue create"
    assert_mock_called_with "--label bug,critical"
}

# =============================================================================
# JIRA MODE
# =============================================================================

@test "create-issue jira: calls acli jira create-issue and returns issue key" {
    export TRACKER="jira"
    export JIRA_PROJECT="TEST"
    run run_platform_script create-issue.sh --title "Jira task" --body "Task body"
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEST-123"* ]]
    assert_mock_called_with "acli jira create-issue"
    assert_mock_called_with "--project TEST"
    assert_mock_called_with "--summary Jira task"
}

@test "create-issue jira: uses configured issue type" {
    export TRACKER="jira"
    export JIRA_DEFAULT_ISSUE_TYPE="Bug"
    run run_platform_script create-issue.sh --title "A bug" --body "Bug details"
    [ "$status" -eq 0 ]
    assert_mock_called_with "--type Bug"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "create-issue github: fails when gh exits non-zero" {
    export TRACKER="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script create-issue.sh --title "Fail" --body "Should fail"
    [ "$status" -ne 0 ]
}
