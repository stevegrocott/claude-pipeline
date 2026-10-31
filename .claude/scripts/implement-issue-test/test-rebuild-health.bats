#!/usr/bin/env bats
#
# test-rebuild-health.bats
# Tests for rebuild_and_health_check's stdout contract (issue #976):
#   - stdout carries only the JSON status object, even when docker-compose
#     writes several lines of output
#   - a non-zero rebuild reports .rebuild == "failed" (not "skipped")
#   - elapsed_secs and poll_secs are readable from the returned JSON
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    export ISSUE_NUMBER=99
    export BASE_BRANCH=main
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0
    export _CONSECUTIVE_TIMEOUTS=0
    export SCHEMA_DIR="$TEST_TMP/schemas"
    export TRACKER="github"

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    source_orchestrator_functions

    # Production runs under `set -uo pipefail`; the sourced functions do not
    # inherit it, and the `| tail -5` pipe masks a failed build without it.
    set -o pipefail

    # Mocked docker-compose and curl: build/up emit several lines of
    # output; DOCKER_BUILD_RC controls the build exit status.
    mkdir -p "$TEST_TMP/rebuild-bin"
    cat > "$TEST_TMP/rebuild-bin/docker-compose" <<'EOF'
#!/usr/bin/env bash
for i in 1 2 3 4 5 6 7 8; do
    echo "docker-compose $1 line $i"
done
if [[ "$1" == "build" ]]; then
    exit "${DOCKER_BUILD_RC:-0}"
fi
exit 0
EOF
    cat > "$TEST_TMP/rebuild-bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TEST_TMP/rebuild-bin/docker-compose" "$TEST_TMP/rebuild-bin/curl"
    export PATH="$TEST_TMP/rebuild-bin:$PATH"
}

teardown() {
    teardown_test_env
}

@test "rebuild_and_health_check stdout parses as JSON when docker-compose emits multiple lines" {
    export DOCKER_BUILD_RC=0
    local out
    out=$(rebuild_and_health_check "http://localhost:1" 5 2>/dev/null)

    run jq -e . <<<"$out"
    [ "$status" -eq 0 ]

    run jq -r '.rebuild' <<<"$out"
    [ "$output" = "success" ]
    run jq -r '.health' <<<"$out"
    [ "$output" = "healthy" ]
}

@test "rebuild_and_health_check reports rebuild failed (not skipped) when the build exits non-zero" {
    export DOCKER_BUILD_RC=1
    local out rc=0
    out=$(rebuild_and_health_check "http://localhost:1" 5 2>/dev/null) || rc=$?

    [ "$rc" -eq 1 ]

    run jq -e . <<<"$out"
    [ "$status" -eq 0 ]

    run jq -r '.rebuild' <<<"$out"
    [ "$output" = "failed" ]
    run jq -r '.health' <<<"$out"
    [ "$output" = "skipped" ]
}

@test "rebuild_and_health_check exposes elapsed_secs and poll_secs as numbers" {
    export DOCKER_BUILD_RC=0
    local out
    out=$(rebuild_and_health_check "http://localhost:1" 5 2>/dev/null)

    run jq -e '(.elapsed_secs | type) == "number" and (.poll_secs | type) == "number"' <<<"$out"
    [ "$status" -eq 0 ]
}

@test "rebuild_and_health_check keeps docker-compose output visible on stderr" {
    export DOCKER_BUILD_RC=0
    local err_file="$TEST_TMP/stderr.txt"
    rebuild_and_health_check "http://localhost:1" 5 >/dev/null 2>"$err_file"

    grep -q "docker-compose up line" "$err_file"
}
