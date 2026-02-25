#!/usr/bin/env bats
#
# test-list-issues.bats
# Tests for platform/list-issues.sh
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

@test "list-issues github: returns normalised JSON array" {
    export TRACKER="github"
    export MOCK_GH_ISSUES_JSON='[{"number":1,"title":"Issue 1","state":"OPEN"},{"number":2,"title":"Issue 2","state":"CLOSED"}]'
    run run_platform_script list-issues.sh
    [ "$status" -eq 0 ]
    # The script normalises to [{id, title, status}]
    echo "$output" | jq -e '.[0].id == "1"'
    echo "$output" | jq -e '.[0].title == "Issue 1"'
    echo "$output" | jq -e '.[0].status == "OPEN"'
    echo "$output" | jq -e '.[1].id == "2"'
}

@test "list-issues github: passes state flag" {
    export TRACKER="github"
    run run_platform_script list-issues.sh --state closed
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh issue list --state closed"
}

@test "list-issues github: passes assignee flag" {
    export TRACKER="github"
    run run_platform_script list-issues.sh --assignee "@me"
    [ "$status" -eq 0 ]
    assert_mock_called_with "--assignee @me"
}

@test "list-issues github: passes label flag" {
    export TRACKER="github"
    run run_platform_script list-issues.sh --labels "bug"
    [ "$status" -eq 0 ]
    assert_mock_called_with "--label bug"
}

# =============================================================================
# JIRA MODE
# =============================================================================

@test "list-issues jira with explicit JQL: passes JQL to acli" {
    export TRACKER="jira"
    local jql='project = TEST AND status = "To Do"'
    run run_platform_script list-issues.sh --jql "$jql"
    [ "$status" -eq 0 ]
    assert_mock_called_with "acli jira list-issues"
    assert_mock_called_with "--jql"
}

@test "list-issues jira without JQL: builds default query from JIRA_PROJECT" {
    export TRACKER="jira"
    export JIRA_PROJECT="MYPROJ"
    run run_platform_script list-issues.sh
    [ "$status" -eq 0 ]
    # Default JQL is: project = $JIRA_PROJECT AND status != Done ORDER BY priority DESC
    assert_mock_called_with "--jql project = MYPROJ AND status != Done ORDER BY priority DESC"
}

@test "list-issues jira: returns normalised JSON array" {
    export TRACKER="jira"
    export MOCK_ACLI_ISSUES_JSON='[{"key":"TEST-1","fields":{"summary":"Task 1","status":{"name":"To Do"}}},{"key":"TEST-2","fields":{"summary":"Task 2","status":{"name":"Done"}}}]'
    run run_platform_script list-issues.sh
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.[0].id == "TEST-1"'
    echo "$output" | jq -e '.[0].title == "Task 1"'
    echo "$output" | jq -e '.[0].status == "To Do"'
    echo "$output" | jq -e '.[1].id == "TEST-2"'
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "list-issues github: fails when gh exits non-zero" {
    export TRACKER="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script list-issues.sh
    [ "$status" -ne 0 ]
}

@test "list-issues jira: fails when acli exits non-zero" {
    export TRACKER="jira"
    export MOCK_ACLI_EXIT_CODE=1
    run run_platform_script list-issues.sh
    [ "$status" -ne 0 ]
}
