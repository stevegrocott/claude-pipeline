#!/usr/bin/env bats
#
# test-find-mr.bats
# Tests for platform/find-mr.sh
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

@test "find-mr github: returns PR number from gh pr list" {
    export GIT_HOST="github"
    export MOCK_GH_PR_LIST_JSON='[{"number":99}]'
    run run_platform_script find-mr.sh --branch "feature-branch"
    [ "$status" -eq 0 ]
    [[ "$output" == *"99"* ]]
    assert_mock_called_with "gh pr list --head feature-branch --state open"
}

@test "find-mr github: passes state flag" {
    export GIT_HOST="github"
    export MOCK_GH_PR_LIST_JSON='[{"number":50}]'
    run run_platform_script find-mr.sh --branch "feature-branch" --state "closed"
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh pr list --head feature-branch --state closed"
}

@test "find-mr github: returns empty when no match" {
    export GIT_HOST="github"
    export MOCK_GH_PR_LIST_JSON='[]'
    run run_platform_script find-mr.sh --branch "nonexistent-branch"
    [ "$status" -eq 0 ]
    # Output should be empty (jq '.[0].number // empty' on empty array)
    [[ -z "$output" || "$output" == "null" || "$output" == "" ]]
}

# =============================================================================
# GITLAB MODE
# =============================================================================

@test "find-mr gitlab: returns MR number from glab mr list" {
    export GIT_HOST="gitlab"
    export MOCK_GLAB_MR_LIST_JSON='[{"iid":55}]'
    run run_platform_script find-mr.sh --branch "feature-branch"
    [ "$status" -eq 0 ]
    [[ "$output" == *"55"* ]]
    assert_mock_called_with "glab mr list --source-branch feature-branch"
}

@test "find-mr gitlab: returns empty when no match" {
    export GIT_HOST="gitlab"
    export MOCK_GLAB_MR_LIST_JSON='[]'
    run run_platform_script find-mr.sh --branch "nonexistent-branch"
    [ "$status" -eq 0 ]
    [[ -z "$output" || "$output" == "null" || "$output" == "" ]]
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "find-mr github: fails when gh exits non-zero" {
    export GIT_HOST="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script find-mr.sh --branch "feature-branch"
    [ "$status" -ne 0 ]
}

@test "find-mr gitlab: fails when glab exits non-zero" {
    export GIT_HOST="gitlab"
    export MOCK_GLAB_EXIT_CODE=1
    run run_platform_script find-mr.sh --branch "feature-branch"
    [ "$status" -ne 0 ]
}
