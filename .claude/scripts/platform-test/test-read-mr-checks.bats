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
    run run_platform_script read-mr-checks.sh 99 --failed-log lint
    [ "$status" -eq 0 ]
    [ "$output" == "lint: error on line 4" ]
    assert_mock_called_with "gh run view 222 --log-failed --job 7"
    assert_mock_not_called_with "gh run view 111"
}

@test "read-mr-checks github: unknown check name gives empty output, exit 0, no log fetch" {
    export GIT_HOST="github"
    run run_platform_script read-mr-checks.sh 99 --failed-log nonesuch
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    assert_mock_not_called_with "gh run view"
}

@test "read-mr-checks github: failing log command gives empty output, exit 0" {
    export GIT_HOST="github"
    cat > "$TEST_TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
[[ "$1" == run ]] && exit 1
echo "$MOCK_GH_PR_VIEW_JSON"
GH
    run run_platform_script read-mr-checks.sh 99 --failed-log lint
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "read-mr-checks github: failed log has the job, step and timestamp columns removed" {
    export GIT_HOST="github"
    export MOCK_GH_RUN_LOG=$'lint\tRun bats\t2026-01-02T03:04:05.1234567Z not ok 3 a thing\nlint\tRun bats\t2026-01-02T03:04:06.0000000Z # (in test file x.bats, line 4)\nlint\tRun bats\t2026-01-02T03:04:07.0000000Z   indented\ttext'
    run run_platform_script read-mr-checks.sh 99 --failed-log lint
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "not ok 3 a thing" ]
    [ "${lines[1]}" == "# (in test file x.bats, line 4)" ]
    [ "${lines[2]}" == $'  indented\ttext' ]
}

@test "read-mr-checks github: a line without gh's columns is printed unchanged" {
    export GIT_HOST="github"
    export MOCK_GH_RUN_LOG="2026-01-02T03:04:05Z plain line"
    run run_platform_script read-mr-checks.sh 99 --failed-log lint
    [ "$status" -eq 0 ]
    [ "$output" == "2026-01-02T03:04:05Z plain line" ]
}

@test "read-mr-checks github: a name shared by a passed and a failed run reads the failed run" {
    export GIT_HOST="github"
    export MOCK_GH_PR_VIEW_JSON='{"headRefOid":"abc123","statusCheckRollup":[{"name":"lint","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://github.com/o/r/actions/runs/111/job/1"},{"name":"lint","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/222/job/7"}]}'
    export MOCK_GH_RUN_LOG="lint: error on line 4"
    run run_platform_script read-mr-checks.sh 99 --failed-log lint
    [ "$status" -eq 0 ]
    [ "$output" == "lint: error on line 4" ]
    assert_mock_called_with "gh run view 222 --log-failed --job 7"
    assert_mock_not_called_with "gh run view 111"
}

@test "read-mr-checks github: a check with no failed run gives empty output, exit 0, no log fetch" {
    export GIT_HOST="github"
    export MOCK_GH_RUN_LOG="must not be printed"
    run run_platform_script read-mr-checks.sh 99 --failed-log build
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    assert_mock_not_called_with "gh run view"
}

@test "read-mr-checks github: a non-Actions check URL gives empty output, exit 0, no log fetch" {
    export GIT_HOST="github"
    export MOCK_GH_PR_VIEW_JSON='{"headRefOid":"abc123","statusCheckRollup":[{"context":"ci/external","state":"FAILURE","targetUrl":"https://ci.example.com/build/5"}]}'
    export MOCK_GH_RUN_LOG="must not be printed"
    run run_platform_script read-mr-checks.sh 99 --failed-log ci/external
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    assert_mock_not_called_with "gh run view"
}

@test "read-mr-checks: rejects a bare positional check name" {
    export GIT_HOST="github"
    run run_platform_script read-mr-checks.sh 99 lint
    [ "$status" -ne 0 ]
    assert_output_contains "Usage"
}

# =============================================================================
# GITLAB MODE
# =============================================================================

@test "read-mr-checks gitlab: empty checks object and no CLI calls" {
    export GIT_HOST="gitlab"
    run run_platform_script read-mr-checks.sh 55
    [ "$status" -eq 0 ]
    [ "$(jq -c '.checks' <<< "$output")" == "[]" ]
    assert_mock_not_called_with "gh "
    assert_mock_not_called_with "glab "
}

@test "read-mr-checks gitlab: empty output with --failed-log" {
    export GIT_HOST="gitlab"
    run run_platform_script read-mr-checks.sh 55 --failed-log lint
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
