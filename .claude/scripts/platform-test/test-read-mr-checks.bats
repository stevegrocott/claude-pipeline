#!/usr/bin/env bats
#
# test-read-mr-checks.bats
# Tests for platform/read-mr-checks.sh
#

bats_require_minimum_version 1.5.0

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
# GITHUB MODE: JOBS API FALLBACK
# =============================================================================

# What gh does for a finished job of a run that is still in progress.
refuse_run_view() {
    export MOCK_GH_RUN_EXIT_CODE=1
    export MOCK_GH_RUN_ERR="run 222 is still in progress; logs will be \
available when it is complete"
}

# A commit status: its URL names a run but no job.
use_check_url_without_job() {
    export MOCK_GH_PR_VIEW_JSON='{"headRefOid":"abc123","statusCheckRollup":[{"name":"lint","status":"COMPLETED","conclusion":"FAILURE","detailsUrl":"https://github.com/o/r/actions/runs/222"}]}'
}

@test "read-mr-checks github: an empty log falls back to the jobs API log" {
    export GIT_HOST="github"
    refuse_run_view
    export MOCK_GH_API_LOG="2026-01-02T03:04:05.1234567Z not ok 3 a thing"
    run --separate-stderr run_platform_script read-mr-checks.sh 99 \
        --failed-log lint
    [ "$status" -eq 0 ]
    [ "$output" == "not ok 3 a thing" ]
    [ -z "$stderr" ]
    assert_mock_called_with "gh run view 222 --log-failed --job 7"
    assert_mock_called_with "gh api repos/{owner}/{repo}/actions/jobs/7/logs"
}

@test "read-mr-checks github: an empty log from a successful run view also falls back" {
    export GIT_HOST="github"
    export MOCK_GH_API_LOG="2026-01-02T03:04:05Z from the api"
    run run_platform_script read-mr-checks.sh 99 --failed-log lint
    [ "$status" -eq 0 ]
    [ "$output" == "from the api" ]
}

@test "read-mr-checks github: jobs API log has the byte order mark and timestamps removed" {
    export GIT_HOST="github"
    refuse_run_view
    export MOCK_GH_API_LOG=$'\xef\xbb\xbf2026-01-02T03:04:05.1234567Z not ok 3 a thing\n2026-01-02T03:04:06.0000000Z # (in test file x.bats, line 4)\n2026-01-02T03:04:07.0000000Z   indented\ttext\nuntimed line'
    run run_platform_script read-mr-checks.sh 99 --failed-log lint
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 4 ]
    [ "${lines[0]}" == "not ok 3 a thing" ]
    [ "${lines[1]}" == "# (in test file x.bats, line 4)" ]
    [ "${lines[2]}" == $'  indented\ttext' ]
    [ "${lines[3]}" == "untimed line" ]
}

@test "read-mr-checks github: a log from run view means no jobs API call" {
    export GIT_HOST="github"
    export MOCK_GH_RUN_LOG="lint: error on line 4"
    export MOCK_GH_API_LOG="2026-01-02T03:04:05Z must not be printed"
    run run_platform_script read-mr-checks.sh 99 --failed-log lint
    [ "$status" -eq 0 ]
    [ "$output" == "lint: error on line 4" ]
    assert_mock_not_called_with "gh api"
}

@test "read-mr-checks github: a URL with no job id skips the jobs API and reports why" {
    export GIT_HOST="github"
    use_check_url_without_job
    refuse_run_view
    export MOCK_GH_API_LOG="2026-01-02T03:04:05Z must not be printed"
    run --separate-stderr run_platform_script read-mr-checks.sh 99 \
        --failed-log lint
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" == "$MOCK_GH_RUN_ERR" ]
    assert_mock_called_with "gh run view 222 --log-failed"
    assert_mock_not_called_with "--job"
    assert_mock_not_called_with "gh api"
}

@test "read-mr-checks github: a failed jobs API call reports its error, not its body" {
    export GIT_HOST="github"
    refuse_run_view
    export MOCK_GH_API_EXIT_CODE=1
    export MOCK_GH_API_LOG='{"message":"Not Found","status":"404"}'
    export MOCK_GH_API_ERR="gh: Not Found (HTTP 404)"
    run --separate-stderr run_platform_script read-mr-checks.sh 99 \
        --failed-log lint
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" == "gh: Not Found (HTTP 404)" ]
}

@test "read-mr-checks github: an empty jobs API reply reports the run view error" {
    export GIT_HOST="github"
    refuse_run_view
    run --separate-stderr run_platform_script read-mr-checks.sh 99 \
        --failed-log lint
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$stderr" == "$MOCK_GH_RUN_ERR" ]
    assert_mock_called_with "gh api repos/{owner}/{repo}/actions/jobs/7/logs"
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
