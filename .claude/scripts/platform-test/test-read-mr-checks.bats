#!/usr/bin/env bats
#
# test-read-mr-checks.bats
# Tests for platform/read-mr-checks.sh
#

load 'helpers/test-helper'

setup() {
    setup_test_env
    install_mocks
    export MOCK_GH_PR_VIEW_JSON='{"headRefOid":"abc123","statusCheckRollup":[{"name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/111/job/1"},{"name":"lint","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/222/job/7"}]}'
}

teardown() {
    teardown_test_env
}

# =============================================================================
# GITHUB MODE
# =============================================================================

@test "read-mr-checks github: returns head sha and checks as JSON" {
    export GIT_HOST="github"
    run run_platform_script read-mr-checks.sh 99
    [ "$status" -eq 0 ]
    jq -e '.head_sha == "abc123"' <<< "$output"
    jq -e '(.checks | length) == 2' <<< "$output"
    jq -e '.checks[1].name == "lint" and .checks[1].conclusion == "FAILURE"' \
        <<< "$output"
    assert_mock_called_with "gh pr view 99 --json headRefOid,statusCheckRollup"
}

@test "read-mr-checks github: no checks yields empty array" {
    export GIT_HOST="github"
    export MOCK_GH_PR_VIEW_JSON='{"headRefOid":"def456","statusCheckRollup":[]}'
    run run_platform_script read-mr-checks.sh 99
    [ "$status" -eq 0 ]
    jq -e '.head_sha == "def456" and .checks == []' <<< "$output"
}

@test "read-mr-checks github: named check returns failed log via run id and job" {
    export GIT_HOST="github"
    export MOCK_GH_RUN_LOG="lint: error on line 4"
    run run_platform_script read-mr-checks.sh 99 lint
    [ "$status" -eq 0 ]
    [ "$output" == "lint: error on line 4" ]
    assert_mock_called_with "gh run view 222 --log-failed --job 7"
    assert_mock_not_called_with "gh run view 111"
}

@test "read-mr-checks github: unknown check name fails without fetching log" {
    export GIT_HOST="github"
    run run_platform_script read-mr-checks.sh 99 nonesuch
    [ "$status" -ne 0 ]
    assert_output_contains "no check named 'nonesuch'"
    assert_mock_not_called_with "gh run view"
}

# =============================================================================
# GITLAB MODE
# =============================================================================

@test "read-mr-checks gitlab: empty output and no CLI calls" {
    export GIT_HOST="gitlab"
    run run_platform_script read-mr-checks.sh 55
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    assert_mock_not_called_with "gh "
    assert_mock_not_called_with "glab "
}

@test "read-mr-checks gitlab: empty output with a check name too" {
    export GIT_HOST="gitlab"
    run run_platform_script read-mr-checks.sh 55 lint
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# =============================================================================
# ERROR HANDLING
# =============================================================================

@test "read-mr-checks github: fails when gh exits non-zero" {
    export GIT_HOST="github"
    export MOCK_GH_EXIT_CODE=1
    run run_platform_script read-mr-checks.sh 99
    [ "$status" -ne 0 ]
}

@test "read-mr-checks: fails without an MR number" {
    export GIT_HOST="github"
    run run_platform_script read-mr-checks.sh
    [ "$status" -ne 0 ]
    assert_output_contains "Usage"
}

@test "read-mr-checks: fails loudly on an unrecognised GIT_HOST" {
    export GIT_HOST="bitbucket"
    run run_platform_script read-mr-checks.sh 99
    [ "$status" -ne 0 ]
    assert_output_contains "unrecognised GIT_HOST"
}
