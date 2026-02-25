#!/usr/bin/env bats
#
# test-merge-mr.bats
# Tests for platform/merge-mr.sh
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

@test "merge-mr github squash: calls gh pr merge --squash" {
    export GIT_HOST="github"
    export MERGE_STYLE="squash"
    run run_platform_script merge-mr.sh 99
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh pr merge 99 --squash --delete-branch"
}

@test "merge-mr github merge: calls gh pr merge --merge" {
    export GIT_HOST="github"
    export MERGE_STYLE="merge"
    run run_platform_script merge-mr.sh 99
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh pr merge 99 --merge --delete-branch"
}

@test "merge-mr github rebase: calls gh pr merge --rebase" {
    export GIT_HOST="github"
    export MERGE_STYLE="rebase"
    run run_platform_script merge-mr.sh 99
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh pr merge 99 --rebase --delete-branch"
}

# =============================================================================
# GITLAB MODE
# =============================================================================

@test "merge-mr gitlab squash: calls glab mr merge --squash" {
    export GIT_HOST="gitlab"
    export MERGE_STYLE="squash"
    run run_platform_script merge-mr.sh 55
    [ "$status" -eq 0 ]
    assert_mock_called_with "glab mr merge 55 --squash --remove-source-branch --yes"
}

@test "merge-mr gitlab merge: calls glab mr merge without --squash" {
    export GIT_HOST="gitlab"
    export MERGE_STYLE="merge"
    run run_platform_script merge-mr.sh 55
    [ "$status" -eq 0 ]
    assert_mock_called_with "glab mr merge 55 --remove-source-branch --yes"
}

@test "merge-mr gitlab rebase: calls glab mr merge --rebase" {
    export GIT_HOST="gitlab"
    export MERGE_STYLE="rebase"
    run run_platform_script merge-mr.sh 55
    [ "$status" -eq 0 ]
    assert_mock_called_with "glab mr merge 55 --rebase --remove-source-branch --yes"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "merge-mr github: fails when gh exits non-zero" {
    export GIT_HOST="github"
    export MERGE_STYLE="squash"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script merge-mr.sh 99
    [ "$status" -ne 0 ]
}

@test "merge-mr gitlab: fails when glab exits non-zero" {
    export GIT_HOST="gitlab"
    export MERGE_STYLE="squash"
    export MOCK_GLAB_EXIT_CODE=1
    run run_platform_script merge-mr.sh 55
    [ "$status" -ne 0 ]
}
