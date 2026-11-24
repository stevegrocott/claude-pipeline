#!/usr/bin/env bats
#
# test-comment-issue.bats
# Tests for platform/comment-issue.sh path redaction
#
# comment-issue.sh dispatches on TRACKER (github|jira), not GIT_HOST, so the
# "gitlab" case pins GIT_HOST=gitlab and asserts the body is still redacted
# and posted through the tracker CLI.
#

load 'helpers/test-helper'

setup() {
    setup_test_env
    install_mocks
    export HOME="/home/someone"
    export PIPELINE_REDACT_ROOT="/home/someone/work/repo"
}

teardown() {
    teardown_test_env
}

# =============================================================================
# GITHUB
# =============================================================================

@test "comment-issue github: posts redacted body, never the original path" {
    export GIT_HOST="github"
    run run_platform_script comment-issue.sh 7 \
        "blocked on /home/someone/work/repo/depends-on:3"
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh issue comment 7 --body blocked on depends-on:3"
    assert_mock_not_called_with "/home/someone"
    assert_mock_not_called_with "work/repo/depends-on:3"
}

# =============================================================================
# GITLAB
# =============================================================================

@test "comment-issue gitlab: posts redacted body, never the original path" {
    export GIT_HOST="gitlab"
    export GIT_CLI="glab"
    run run_platform_script comment-issue.sh 7 \
        "blocked on /home/someone/work/repo/depends-on:3"
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh issue comment 7 --body blocked on depends-on:3"
    assert_mock_not_called_with "/home/someone"
    assert_mock_not_called_with "work/repo/depends-on:3"
}

# =============================================================================
# EDGE CASES
# =============================================================================

@test "comment-issue: redacts HOME paths and keeps -R repo arg" {
    run run_platform_script comment-issue.sh 7 \
        "cfg /home/someone/.cfg" "owner/repo"
    [ "$status" -eq 0 ]
    assert_mock_called_with "gh issue comment 7 -R owner/repo --body cfg ~/.cfg"
    assert_mock_not_called_with "/home/someone"
}
