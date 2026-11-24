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
# PATH REDACTION
# =============================================================================

@test "create-mr github: redacts repo root and HOME from body" {
    export GIT_HOST="github"
    export HOME="/home/someone"
    export PIPELINE_REDACT_ROOT="/home/someone/work/repo"
    run run_platform_script create-mr.sh --source "f" --target "main" --title "T" \
        --body "see /home/someone/work/repo/src/a.sh and /home/someone/.cfg"
    [ "$status" -eq 0 ]
    assert_mock_called_with "--body see src/a.sh and ~/.cfg"
    assert_mock_not_called_with "/home/someone"
}

@test "create-mr gitlab: redacts local paths from description" {
    export GIT_HOST="gitlab"
    export HOME="/home/someone"
    export PIPELINE_REDACT_ROOT="/home/someone/work/repo"
    run run_platform_script create-mr.sh --source "f" --target "main" --title "T" \
        --body "at /home/someone/work/repo/x"
    [ "$status" -eq 0 ]
    assert_mock_called_with "--description at x"
    assert_mock_not_called_with "/home/someone"
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

@test "create-mr: fails loudly on an unrecognised GIT_HOST instead of no-op" {
    export GIT_HOST="bitbucket"
    run run_platform_script create-mr.sh --source "x" --target "main" --title "T" --body "B"
    [ "$status" -ne 0 ]
    assert_output_contains "unrecognised GIT_HOST"
    assert_output_contains "bitbucket"
    assert_mock_not_called_with "gh pr create"
    assert_mock_not_called_with "glab mr create"
}

# =============================================================================
# BODY FILE
# =============================================================================

@test "create-mr github: --body-file content is passed as the body" {
    export GIT_HOST="github"
    printf 'line one\nline two\n' > "$TEST_TMP/body.md"
    run run_platform_script create-mr.sh --source "f" --target "main" --title "T" \
        --body-file "$TEST_TMP/body.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"99"* ]]
    assert_mock_called_with "--body line one"
    assert_mock_called_with "line two"
}

@test "create-mr gitlab: --body-file content is passed as the description" {
    export GIT_HOST="gitlab"
    printf 'from file\n' > "$TEST_TMP/body.md"
    run run_platform_script create-mr.sh --source "f" --target "main" --title "T" \
        --body-file "$TEST_TMP/body.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"55"* ]]
    assert_mock_called_with "--description from file"
}

@test "create-mr github: --body-file content is path-redacted" {
    export GIT_HOST="github"
    export HOME="/home/someone"
    export PIPELINE_REDACT_ROOT="/home/someone/work/repo"
    printf 'see /home/someone/work/repo/src/a.sh\n' > "$TEST_TMP/body.md"
    run run_platform_script create-mr.sh --source "f" --target "main" --title "T" \
        --body-file "$TEST_TMP/body.md"
    [ "$status" -eq 0 ]
    assert_mock_called_with "--body see src/a.sh"
    assert_mock_not_called_with "/home/someone"
}

@test "create-mr: --body-file wins over --body" {
    export GIT_HOST="github"
    printf 'file wins' > "$TEST_TMP/body.md"
    run run_platform_script create-mr.sh --source "f" --target "main" --title "T" \
        --body "inline loses" --body-file "$TEST_TMP/body.md"
    [ "$status" -eq 0 ]
    assert_mock_called_with "--body file wins"
    assert_mock_not_called_with "inline loses"
}

@test "create-mr: fails on a missing --body-file without calling the host" {
    export GIT_HOST="github"
    run run_platform_script create-mr.sh --source "f" --target "main" --title "T" \
        --body-file "$TEST_TMP/nope.md"
    [ "$status" -ne 0 ]
    assert_output_contains "body file not readable"
    assert_mock_not_called_with "gh pr create"
}
