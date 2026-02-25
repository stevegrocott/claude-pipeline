#!/usr/bin/env bats
#
# test-read-issue.bats
# Tests for platform/read-issue.sh
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

@test "read-issue github: returns normalised JSON with title, body, status" {
    export TRACKER="github"
    export MOCK_GH_ISSUE_JSON='{"title":"My Issue","body":"Description here","state":"OPEN"}'
    run run_platform_script read-issue.sh 42
    [ "$status" -eq 0 ]
    # The script pipes through jq to normalise: { title, body, status: .state }
    echo "$output" | jq -e '.title == "My Issue"'
    echo "$output" | jq -e '.body == "Description here"'
    echo "$output" | jq -e '.status == "OPEN"'
}

@test "read-issue github: calls gh issue view with correct issue number" {
    export TRACKER="github"
    run run_platform_script read-issue.sh 123
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh issue view 123"
}

# =============================================================================
# JIRA MODE
# =============================================================================

@test "read-issue jira: returns normalised JSON with title, body, status" {
    export TRACKER="jira"
    export MOCK_ACLI_ISSUE_JSON='{"fields":{"summary":"Jira Task","description":"Jira description","status":{"name":"In Progress"}}}'
    run run_platform_script read-issue.sh TEST-456
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.title == "Jira Task"'
    echo "$output" | jq -e '.body == "Jira description"'
    echo "$output" | jq -e '.status == "In Progress"'
}

@test "read-issue jira: calls acli jira get-issue with correct issue key" {
    export TRACKER="jira"
    run run_platform_script read-issue.sh TEST-456
    [ "$status" -eq 0 ]
    assert_mock_called_with "acli jira get-issue --issue TEST-456"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "read-issue github: fails when gh exits non-zero" {
    export TRACKER="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script read-issue.sh 42
    [ "$status" -ne 0 ]
}

@test "read-issue jira: fails when acli exits non-zero" {
    export TRACKER="jira"
    export MOCK_ACLI_EXIT_CODE=1
    run run_platform_script read-issue.sh TEST-1
    [ "$status" -ne 0 ]
}
