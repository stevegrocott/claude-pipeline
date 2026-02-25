#!/usr/bin/env bats
#
# test-create-mr.bats
# Tests for platform/create-mr.sh
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

@test "create-mr github: calls gh pr create and returns PR number" {
    export GIT_HOST="github"
    run run_platform_script create-mr.sh --source "feature-branch" --target "main" --title "Add feature" --body "PR body"
    [ "$status" -eq 0 ]
    [[ "$output" == *"99"* ]]
    assert_mock_called_with "gh pr create --head feature-branch --base main --title Add feature --body PR body"
}

@test "create-mr github: extracts number from URL" {
    export GIT_HOST="github"
    run run_platform_script create-mr.sh --source "fix" --target "main" --title "Fix" --body "Fix body"
    [ "$status" -eq 0 ]
    # The script does grep -oE '[0-9]+$' on the URL, extracting "99"
    [[ "$output" =~ ^[0-9]+$ ]]
}

# =============================================================================
# GITLAB MODE
# =============================================================================

@test "create-mr gitlab: calls glab mr create and returns MR number" {
    export GIT_HOST="gitlab"
    run run_platform_script create-mr.sh --source "feature-branch" --target "main" --title "Add feature" --body "MR body"
    [ "$status" -eq 0 ]
    [[ "$output" == *"55"* ]]
    assert_mock_called_with "glab mr create --source-branch feature-branch --target-branch main"
}

@test "create-mr gitlab: passes squash-on-merge and no-editor flags" {
    export GIT_HOST="gitlab"
    run run_platform_script create-mr.sh --source "feat" --target "main" --title "T" --body "B"
    [ "$status" -eq 0 ]
    assert_mock_called_with "--squash-on-merge"
    assert_mock_called_with "--no-editor"
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "create-mr github: fails when gh exits non-zero" {
    export GIT_HOST="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script create-mr.sh --source "x" --target "main" --title "T" --body "B"
    [ "$status" -ne 0 ]
}

@test "create-mr gitlab: fails when glab exits non-zero" {
    export GIT_HOST="gitlab"
    export MOCK_GLAB_EXIT_CODE=1
    run run_platform_script create-mr.sh --source "x" --target "main" --title "T" --body "B"
    [ "$status" -ne 0 ]
}
