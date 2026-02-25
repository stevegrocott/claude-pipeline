#!/usr/bin/env bats
#
# test-transition-issue.bats
# Tests for platform/transition-issue.sh
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

@test "transition-issue github: calls gh issue close" {
    export TRACKER="github"
    run run_platform_script transition-issue.sh 42
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh issue close 42"
}

@test "transition-issue github: ignores second argument (transition name)" {
    export TRACKER="github"
    run run_platform_script transition-issue.sh 42 "In Review"
    [ "$status" -eq 0 ]
    # GitHub mode always calls close regardless of transition name
    assert_mock_called_with "gh issue close 42"
}

# =============================================================================
# JIRA MODE
# =============================================================================

@test "transition-issue jira: uses default JIRA_DONE_TRANSITION" {
    export TRACKER="jira"
    export JIRA_DONE_TRANSITION="Done"
    run run_platform_script transition-issue.sh TEST-42
    [ "$status" -eq 0 ]
    assert_mock_called_with "acli jira transition-issue --issue TEST-42 --transition Done"
}

@test "transition-issue jira: accepts custom transition name" {
    export TRACKER="jira"
    run run_platform_script transition-issue.sh TEST-42 "In Review"
    [ "$status" -eq 0 ]
    assert_mock_called_with "acli jira transition-issue --issue TEST-42 --transition In Review"
}

@test "transition-issue jira: uses In Progress transition" {
    export TRACKER="jira"
    run run_platform_script transition-issue.sh TEST-42 "In Progress"
    [ "$status" -eq 0 ]
    assert_mock_called_with "acli jira transition-issue --issue TEST-42 --transition In Progress"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "transition-issue github: fails when gh exits non-zero" {
    export TRACKER="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script transition-issue.sh 42
    [ "$status" -ne 0 ]
}

@test "transition-issue jira: fails when acli exits non-zero" {
    export TRACKER="jira"
    export MOCK_ACLI_EXIT_CODE=1
    run run_platform_script transition-issue.sh TEST-42
    [ "$status" -ne 0 ]
}
