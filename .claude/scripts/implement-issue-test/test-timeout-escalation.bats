#!/usr/bin/env bats
#
# test-timeout-escalation.bats
# Tests for timeout→model escalation, empty output recovery,
# PR stage model tier, and selective git add enforcement.
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    install_mocks

    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0
    export _CONSECUTIVE_TIMEOUTS=0
    export _TIMED_OUT_STAGE_NAMES=""
    export SCHEMA_DIR="$TEST_TMP/schemas"

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
    mkdir -p "$SCHEMA_DIR"

    # Create a valid test schema
    cat > "$SCHEMA_DIR/test-schema.json" << 'EOF'
{
    "type": "object",
    "properties": {
        "status": {"type": "string"},
        "result": {"type": "string"}
    }
}
EOF

    # Create minimal status.json for record_escalation
    cat > "$STATUS_FILE" << 'EOF'
{"escalations": [], "stages": {}}
EOF

    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# TIMEOUT → MODEL ESCALATION (AC1)
# =============================================================================

@test "double timeout escalates haiku to sonnet instead of failing" {
    source "$TEST_TMP/model-config.sh"
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"

    timeout() {
        local t="$1"; shift; shift; shift; shift  # timeout, env, -u, CLAUDECODE
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        echo "$@" > "$TEST_TMP/call-$n-args.txt"
        if (( n <= 2 )); then
            return 124  # first two calls: timeout
        fi
        # Third call (escalated model): succeed
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export counter_file

    # test-iter-1 resolves to haiku
    local result
    result=$(run_stage "test-iter-1" "prompt" "test-schema.json" "" "" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.status')
    [ "$status_val" = "success" ] || \
        fail "Expected success after escalation, got: $status_val"

    # Third call must use escalated model (sonnet)
    local third_call_args
    third_call_args=$(cat "$TEST_TMP/call-3-args.txt" 2>/dev/null)
    [[ "$third_call_args" == *"--model sonnet"* ]] || \
        fail "Expected --model sonnet in escalated retry. Args: $third_call_args"
}

@test "double timeout at opus ceiling still fails (cannot escalate)" {
    source "$TEST_TMP/model-config.sh"
    timeout() {
        shift; shift; shift; shift
        return 124
    }
    export -f timeout

    # implement resolves to opus (ceiling)
    run run_stage "implement-task-1" "prompt" "test-schema.json" "" ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"timeout"* ]] || \
        fail "Expected timeout error. Got: $output"
}

@test "double timeout records escalation event in status.json" {
    source "$TEST_TMP/model-config.sh"
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"

    timeout() {
        local t="$1"; shift; shift; shift; shift
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        if (( n <= 2 )); then
            return 124
        fi
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export counter_file

    run_stage "test-iter-1" "prompt" "test-schema.json" "" "" >/dev/null 2>/dev/null

    # Check escalation was recorded
    local reason
    reason=$(jq -r '.escalations[0].reason // empty' "$STATUS_FILE")
    [ "$reason" = "double_timeout" ] || \
        fail "Expected escalation reason 'double_timeout', got: $reason"
}

@test "double timeout logs escalation message" {
    source "$TEST_TMP/model-config.sh"
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"

    timeout() {
        local t="$1"; shift; shift; shift; shift
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        if (( n <= 2 )); then
            return 124
        fi
        echo '{"result":"ok","structured_output":{"status":"success"}}'
    }
    export -f timeout
    export counter_file

    run_stage "test-iter-1" "prompt" "test-schema.json" "" "" >/dev/null 2>/dev/null

    grep -q "timed out twice.*escalating" "$LOG_FILE" || \
        fail "Expected escalation log message. Log: $(cat "$LOG_FILE")"
}

# =============================================================================
# EMPTY OUTPUT → MODEL ESCALATION (AC2)
# =============================================================================

@test "empty output escalates to next model instead of failing" {
    source "$TEST_TMP/model-config.sh"
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"

    timeout() {
        local t="$1"; shift; shift; shift; shift
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        echo "$@" > "$TEST_TMP/call-$n-args.txt"
        if (( n == 1 )); then
            # First call: return output with no structured_output and is_error:true
            echo '{"is_error":true,"result":"gibberish"}'
        else
            # Escalated call: succeed
            echo '{"result":"ok","structured_output":{"status":"success","data":"recovered"}}'
        fi
    }
    export -f timeout
    export counter_file

    # test-iter-1 resolves to haiku
    local result
    result=$(run_stage "test-iter-1" "prompt" "test-schema.json" "" "" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.status')
    [ "$status_val" = "success" ] || \
        fail "Expected success after escalation, got: $status_val"

    # Second call must use escalated model (sonnet)
    local second_call_args
    second_call_args=$(cat "$TEST_TMP/call-2-args.txt" 2>/dev/null)
    [[ "$second_call_args" == *"--model sonnet"* ]] || \
        fail "Expected --model sonnet for empty output escalation. Args: $second_call_args"
}

@test "empty output records escalation with reason 'empty_output'" {
    source "$TEST_TMP/model-config.sh"
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"

    timeout() {
        local t="$1"; shift; shift; shift; shift
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        if (( n == 1 )); then
            echo '{"is_error":true,"result":"error"}'
        else
            echo '{"result":"ok","structured_output":{"status":"success"}}'
        fi
    }
    export -f timeout
    export counter_file

    run_stage "test-iter-1" "prompt" "test-schema.json" "" "" >/dev/null 2>/dev/null

    local reason
    reason=$(jq -r '.escalations[0].reason // empty' "$STATUS_FILE")
    [ "$reason" = "empty_output" ] || \
        fail "Expected escalation reason 'empty_output', got: $reason"
}

@test "empty output escalation uses .result fallback when no structured_output" {
    source "$TEST_TMP/model-config.sh"
    local counter_file="$TEST_TMP/call-counter.txt"
    printf '0' > "$counter_file"

    timeout() {
        local t="$1"; shift; shift; shift; shift
        local n
        n=$(cat "$counter_file")
        n=$((n + 1))
        printf '%s' "$n" > "$counter_file"
        if (( n == 1 )); then
            echo '{"is_error":true,"result":"error"}'
        else
            # Escalated call returns .result but no .structured_output
            echo '{"result":"Recovered successfully","is_error":false}'
        fi
    }
    export -f timeout
    export counter_file

    local result
    result=$(run_stage "test-iter-1" "prompt" "test-schema.json" "" "" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.status')
    [ "$status_val" = "success" ] || \
        fail "Expected success from .result fallback, got: $status_val"
}

# =============================================================================
# PR STAGE MODEL TIER (AC3)
# =============================================================================

@test "PR stage tier is standard (not light)" {
    source "$TEST_TMP/model-config.sh"
    local tier
    tier=$(_stage_to_tier "pr")
    [ "$tier" = "standard" ] || \
        fail "Expected PR stage tier='standard', got: $tier"
}

@test "PR stage resolves to sonnet" {
    source "$TEST_TMP/model-config.sh"
    local model
    model=$(resolve_model "pr" "")
    [ "$model" = "sonnet" ] || \
        fail "Expected PR stage model='sonnet', got: $model"
}

# =============================================================================
# SELECTIVE GIT ADD — sanitize_worktree_commits (AC4)
# =============================================================================

@test "sanitize_worktree_commits removes binary files from commits" {
    # Create a test git repo to work with
    local test_repo="$TEST_TMP/test-repo"
    mkdir -p "$test_repo"
    git -C "$test_repo" init -b main >/dev/null 2>&1
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"

    # Initial commit
    echo "readme" > "$test_repo/README.md"
    git -C "$test_repo" add README.md
    git -C "$test_repo" commit -m "init" >/dev/null 2>&1

    # Create a branch with a binary file committed
    git -C "$test_repo" checkout -b feature >/dev/null 2>&1
    echo "source code" > "$test_repo/app.sh"
    dd if=/dev/zero of="$test_repo/data.db" bs=1024 count=1 2>/dev/null
    git -C "$test_repo" add app.sh data.db
    git -C "$test_repo" commit -m "add files" >/dev/null 2>&1

    cd "$test_repo" || fail "Could not cd to test repo"

    sanitize_worktree_commits "." "main" "test-1"

    # Verify data.db was removed from the commit
    local files_in_diff
    files_in_diff=$(git diff main...HEAD --name-only)
    [[ "$files_in_diff" == *"app.sh"* ]] || \
        fail "Expected app.sh to remain. Files: $files_in_diff"
    [[ "$files_in_diff" != *"data.db"* ]] || \
        fail "Expected data.db to be removed. Files: $files_in_diff"
}

@test "sanitize_worktree_commits ignores repos with no binary files" {
    local test_repo="$TEST_TMP/clean-repo"
    mkdir -p "$test_repo"
    git -C "$test_repo" init -b main >/dev/null 2>&1
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"

    echo "readme" > "$test_repo/README.md"
    git -C "$test_repo" add README.md
    git -C "$test_repo" commit -m "init" >/dev/null 2>&1

    git -C "$test_repo" checkout -b feature >/dev/null 2>&1
    echo "clean source" > "$test_repo/app.ts"
    git -C "$test_repo" add app.ts
    git -C "$test_repo" commit -m "add source" >/dev/null 2>&1

    cd "$test_repo" || fail "Could not cd to test repo"

    # Should return 0 and not modify anything
    sanitize_worktree_commits "." "main" "test-2"

    local files_in_diff
    files_in_diff=$(git diff main...HEAD --name-only)
    [[ "$files_in_diff" == *"app.ts"* ]] || \
        fail "Expected app.ts to remain. Files: $files_in_diff"
}

@test "sanitize_worktree_commits removes .silo-downloads files" {
    local test_repo="$TEST_TMP/silo-repo"
    mkdir -p "$test_repo/.silo-downloads"
    git -C "$test_repo" init -b main >/dev/null 2>&1
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"

    echo "readme" > "$test_repo/README.md"
    git -C "$test_repo" add README.md
    git -C "$test_repo" commit -m "init" >/dev/null 2>&1

    git -C "$test_repo" checkout -b feature >/dev/null 2>&1
    echo "code" > "$test_repo/index.ts"
    echo "binary data" > "$test_repo/.silo-downloads/big-file.bin"
    git -C "$test_repo" add -A
    git -C "$test_repo" commit -m "add files" >/dev/null 2>&1

    cd "$test_repo" || fail "Could not cd to test repo"

    sanitize_worktree_commits "." "main" "test-3"

    local files_in_diff
    files_in_diff=$(git diff main...HEAD --name-only)
    [[ "$files_in_diff" != *".silo-downloads"* ]] || \
        fail "Expected .silo-downloads to be removed. Files: $files_in_diff"
    [[ "$files_in_diff" == *"index.ts"* ]] || \
        fail "Expected index.ts to remain. Files: $files_in_diff"
}

@test "sanitize_worktree_commits logs removed file names" {
    local test_repo="$TEST_TMP/log-repo"
    mkdir -p "$test_repo"
    git -C "$test_repo" init -b main >/dev/null 2>&1
    git -C "$test_repo" config user.email "test@test.com"
    git -C "$test_repo" config user.name "Test"

    echo "readme" > "$test_repo/README.md"
    git -C "$test_repo" add README.md
    git -C "$test_repo" commit -m "init" >/dev/null 2>&1

    git -C "$test_repo" checkout -b feature >/dev/null 2>&1
    echo "source" > "$test_repo/lib.sh"
    echo "binary" > "$test_repo/archive.tar.gz"
    git -C "$test_repo" add -A
    git -C "$test_repo" commit -m "add" >/dev/null 2>&1

    cd "$test_repo" || fail "Could not cd to test repo"

    sanitize_worktree_commits "." "main" "test-4"

    grep -q "archive.tar.gz" "$LOG_FILE" || \
        fail "Expected removed file logged. Log: $(cat "$LOG_FILE")"
}
