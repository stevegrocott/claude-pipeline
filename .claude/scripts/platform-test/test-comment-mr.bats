#!/usr/bin/env bats
#
# test-comment-mr.bats
# Tests for platform/comment-mr.sh
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

@test "comment-mr github: calls gh pr comment with body" {
    export GIT_HOST="github"
    run run_platform_script comment-mr.sh 99 "Looks good"
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh pr comment 99 --body Looks good"
}

@test "comment-mr github: passes -R when repo arg given" {
    export GIT_HOST="github"
    run run_platform_script comment-mr.sh 99 "Looks good" "owner/repo"
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh pr comment 99 -R owner/repo --body Looks good"
}

# =============================================================================
# GITLAB MODE
# =============================================================================

@test "comment-mr gitlab: calls glab mr note with message" {
    export GIT_HOST="gitlab"
    run run_platform_script comment-mr.sh 55 "Looks good"
    [ "$status" -eq 0 ]
    assert_mock_called_with "glab mr note 55 --message Looks good"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "comment-mr github: fails when gh exits non-zero" {
    export GIT_HOST="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script comment-mr.sh 99 "Looks good"
    [ "$status" -ne 0 ]
}

@test "comment-mr gitlab: fails when glab exits non-zero" {
    export GIT_HOST="gitlab"
    export MOCK_GLAB_EXIT_CODE=1
    run run_platform_script comment-mr.sh 55 "Looks good"
    [ "$status" -ne 0 ]
}

@test "comment-mr: fails loudly on an unrecognised GIT_HOST instead of no-op" {
    export GIT_HOST="bitbucket"
    run run_platform_script comment-mr.sh 99 "Looks good"
    [ "$status" -ne 0 ]
    assert_output_contains "unrecognised GIT_HOST"
    assert_output_contains "bitbucket"
    ! assert_mock_called_with "gh pr comment"
    ! assert_mock_called_with "glab mr note"
}
