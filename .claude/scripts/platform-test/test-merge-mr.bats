#!/usr/bin/env bats
#
# test-merge-mr.bats
# Tests for platform/merge-mr.sh
#

load 'helpers/test-helper'

setup() {
    setup_test_env
    install_mocks

    # Keep wait_for_mergeable's poll loop fast in tests instead of the
    # real 10s/90s defaults.
    export MERGE_MR_POLL_INTERVAL=1
    export MERGE_MR_POLL_MAX=2
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

# =============================================================================
# MERGE-STATE GATE (mergeStateStatus, default-on)
# =============================================================================

@test "merge-mr github: mergeStateStatus DIRTY refuses without calling merge" {
    export GIT_HOST="github"
    export MERGE_STYLE="squash"
    export MOCK_GH_PR_VIEW_JSON='{"mergeStateStatus":"DIRTY","statusCheckRollup":[]}'
    run run_platform_script merge-mr.sh 99
    [ "$status" -ne 0 ]
    assert_output_contains "unresolvable merge conflicts"
    ! assert_mock_called_with "gh pr merge"
}

@test "merge-mr github: concluded check failure refuses instead of waiting out the timeout" {
    export GIT_HOST="github"
    export MERGE_STYLE="squash"
    export MOCK_GH_PR_VIEW_JSON='{"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]}'
    run run_platform_script merge-mr.sh 99
    [ "$status" -ne 0 ]
    assert_output_contains "refusing to wait"
    ! assert_mock_called_with "gh pr merge"
}

@test "merge-mr github: pending check keeps waiting instead of refusing" {
    export GIT_HOST="github"
    export MERGE_STYLE="squash"
    export MOCK_GH_PR_VIEW_JSON='{"mergeStateStatus":"BLOCKED","statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]}'
    run run_platform_script merge-mr.sh 99
    [ "$status" -ne 0 ]
    assert_output_contains "Waiting for PR"
    assert_output_contains "Timed out waiting"
    [[ "$output" != *"refusing to wait"* ]]
    ! assert_mock_called_with "gh pr merge"
}

@test "merge-mr github: MERGE_MR_MERGE_STATE_GATE=0 falls back to legacy mergeable field" {
    export GIT_HOST="github"
    export MERGE_STYLE="squash"
    export MERGE_MR_MERGE_STATE_GATE=0
    # mergeStateStatus says DIRTY (would refuse under the new gate) but the
    # legacy `mergeable` field says MERGEABLE — proves the override flag
    # actually switches which field gates the merge.
    export MOCK_GH_PR_VIEW_JSON='{"mergeable":"MERGEABLE","mergeStateStatus":"DIRTY","statusCheckRollup":[]}'
    run run_platform_script merge-mr.sh 99
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh pr merge 99 --squash --delete-branch"
}
