#!/usr/bin/env bats
#
# test-read-mr-comments.bats
# Tests for platform/read-mr-comments.sh
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

@test "read-mr-comments github: returns array of comment bodies" {
    export GIT_HOST="github"
    export MOCK_GH_PR_VIEW_JSON='{"comments":[{"body":"first"},{"body":"second"}]}'
    run run_platform_script read-mr-comments.sh 99
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '. == ["first", "second"]'
}

@test "read-mr-comments github: calls gh pr view with correct MR number" {
    export GIT_HOST="github"
    export MOCK_GH_PR_VIEW_JSON='{"comments":[]}'
    run run_platform_script read-mr-comments.sh 123
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh pr view 123 --json comments"
}

# =============================================================================
# GITLAB MODE
# =============================================================================

@test "read-mr-comments gitlab: calls glab mr note list with correct MR number" {
    export GIT_HOST="gitlab"
    run run_platform_script read-mr-comments.sh 55
    [ "$status" -eq 0 ]
    assert_mock_called_with "glab mr note list 55"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "read-mr-comments github: fails when gh exits non-zero" {
    export GIT_HOST="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script read-mr-comments.sh 99
    [ "$status" -ne 0 ]
}

@test "read-mr-comments: fails loudly on an unrecognised GIT_HOST instead of no-op" {
    export GIT_HOST="bitbucket"
    run run_platform_script read-mr-comments.sh 99
    [ "$status" -ne 0 ]
    assert_output_contains "unrecognised GIT_HOST"
    assert_output_contains "bitbucket"
    ! assert_mock_called_with "gh pr view"
    ! assert_mock_called_with "glab mr note list"
}
