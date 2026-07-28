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
    install_decide_scripts

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

@test "double timeout escalates sonnet to opus instead of failing" {
    source "$MODEL_CONFIG_ARRAYS_FILE"
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

    # test-iter-1 resolves to sonnet (standard tier)
    local result
    result=$(run_stage "test-iter-1" "prompt" "test-schema.json" "" "" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.status')
    [ "$status_val" = "success" ] || \
        fail "Expected success after escalation, got: $status_val"

    # Third call must use escalated model (opus, the sonnet→opus step)
    local third_call_args
    third_call_args=$(cat "$TEST_TMP/call-3-args.txt" 2>/dev/null)
    [[ "$third_call_args" == *"--model opus"* ]] || \
        fail "Expected --model opus in escalated retry. Args: $third_call_args"
}

@test "double timeout at opus ceiling still fails (cannot escalate)" {
    source "$MODEL_CONFIG_ARRAYS_FILE"
    timeout() {
        shift; shift; shift; shift
        return 124
    }
    export -f timeout

    # implement-task-1 with complexity L resolves to opus (ceiling) — at the
    # opus ceiling decide-action.sh returns bail, so run_stage fails (exit 1).
    run run_stage "implement-task-1" "prompt" "test-schema.json" "" "L"
    [ "$status" -eq 1 ]
    [[ "$output" == *"timeout"* ]] || \
        fail "Expected timeout error. Got: $output"
}

@test "double timeout records escalation event in status.json" {
    source "$MODEL_CONFIG_ARRAYS_FILE"
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
    source "$MODEL_CONFIG_ARRAYS_FILE"
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

    grep -qE "escalating sonnet . opus" "$LOG_FILE" || \
        fail "Expected escalation log message. Log: $(cat "$LOG_FILE")"
}

# =============================================================================
# PER-RUN ESCALATION CAP + S-COMPLEXITY OPUS GATE (issue #579)
#
# These exercise decide-action.sh directly (bash backend, pinned by
# install_decide_scripts) with crafted stage_result + history JSON.  The cap
# bail is checked in main() before dispatch; the S-Opus gate lives in both
# _bash_decide and _compose_decide so the two backends agree.
# =============================================================================

@test "escalation cap: history length >= MAX_ESCALATIONS_PER_RUN bails" {
    local sr='{"status":"error","error_kind":"double_timeout","model":"sonnet","complexity":"M"}'
    local history='[{},{},{},{},{}]'   # length 5 == default cap
    run env MAX_ESCALATIONS_PER_RUN=5 ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" "$history"
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || fail "Expected bail at cap, got: $action ($output)"
    [[ "$output" == *"escalation cap reached"* ]] || \
        fail "Expected cap-reached reason, got: $output"
}

@test "escalation cap: history under cap still escalates" {
    local sr='{"status":"error","error_kind":"double_timeout","model":"sonnet","complexity":"M"}'
    local history='[{},{},{},{}]'   # length 4 < cap 5
    run env MAX_ESCALATIONS_PER_RUN=5 ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" "$history"
    [ "$status" -eq 0 ]
    local action model
    action=$(printf '%s' "$output" | jq -r '.action')
    model=$(printf '%s' "$output" | jq -r '.model')
    [ "$action" = "escalate" ] || fail "Expected escalate under cap, got: $action"
    [ "$model" = "opus" ] || fail "Expected opus, got: $model"
}

@test "escalation cap: env override raises the cap" {
    local sr='{"status":"error","error_kind":"double_timeout","model":"sonnet","complexity":"M"}'
    local history='[{},{},{},{},{}]'   # length 5, but cap raised to 7
    run env MAX_ESCALATIONS_PER_RUN=7 ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" "$history"
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "escalate" ] || \
        fail "Expected escalate with raised cap, got: $action ($output)"
}

@test "escalation cap: success at cap still accepts (cap only bails errors)" {
    local sr='{"status":"success","error_kind":"null","model":"sonnet","complexity":"S"}'
    local history='[{},{},{},{},{}]'
    run env MAX_ESCALATIONS_PER_RUN=5 ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" "$history"
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "accept" ] || fail "Expected accept for success, got: $action"
}

@test "S-complexity double_timeout at sonnet bails (does not escalate to opus)" {
    local sr='{"status":"error","error_kind":"double_timeout","model":"sonnet","complexity":"S"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || fail "Expected bail for S-at-sonnet, got: $action ($output)"
    [[ "$output" == *"S-complexity"* ]] || fail "Expected S-complexity reason, got: $output"
}

@test "S-complexity default error at sonnet bails (does not escalate to opus)" {
    local sr='{"status":"error","error_kind":"no_structured_output","model":"sonnet","complexity":"S"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || fail "Expected bail for S default-error, got: $action ($output)"
}

@test "M-complexity double_timeout at sonnet still escalates to opus" {
    local sr='{"status":"error","error_kind":"double_timeout","model":"sonnet","complexity":"M"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action model
    action=$(printf '%s' "$output" | jq -r '.action')
    model=$(printf '%s' "$output" | jq -r '.model')
    [ "$action" = "escalate" ] || fail "Expected escalate for M, got: $action"
    [ "$model" = "opus" ] || fail "Expected opus for M, got: $model"
}

@test "L-complexity default error at sonnet still escalates to opus" {
    local sr='{"status":"error","error_kind":"no_structured_output","model":"sonnet","complexity":"L"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action model
    action=$(printf '%s' "$output" | jq -r '.action')
    model=$(printf '%s' "$output" | jq -r '.model')
    [ "$action" = "escalate" ] || fail "Expected escalate for L, got: $action"
    [ "$model" = "opus" ] || fail "Expected opus for L, got: $model"
}

@test "empty complexity at sonnet still escalates to opus (no gate)" {
    local sr='{"status":"error","error_kind":"double_timeout","model":"sonnet","complexity":""}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "escalate" ] || fail "Expected escalate for empty complexity, got: $action"
}

@test "backend parity: compose path also bails S-at-sonnet double_timeout" {
    local sr='{"status":"error","error_kind":"double_timeout","model":"sonnet","complexity":"S"}'
    # Skill-native compose path (bash sub-backends), NOT ESCALATION_POLICY_BACKEND=bash
    run env RETRY_POLICY_BACKEND=bash MODEL_FALLBACK_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || fail "Expected compose bail for S-at-sonnet, got: $action ($output)"
}

@test "backend parity: compose path also bails at per-run cap" {
    local sr='{"status":"error","error_kind":"double_timeout","model":"sonnet","complexity":"M"}'
    run env MAX_ESCALATIONS_PER_RUN=5 RETRY_POLICY_BACKEND=bash MODEL_FALLBACK_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[{},{},{},{},{}]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || fail "Expected compose cap bail, got: $action ($output)"
    [[ "$output" == *"escalation cap reached"* ]] || \
        fail "Expected cap-reached reason in compose, got: $output"
}

# =============================================================================
# S-COMPLEXITY OPUS GATE — quality_stall branch (issue #579, AC1 + AC4)
#
# The S-gate must also cover error_kind=quality_stall, not only double_timeout
# and the default escalate.  run_quality_loop threads task_size through, so a
# fix/simplify stage quality-stalling on an S task reaches _bash_decide's
# quality_stall branch on a realistic path.  Both backends must agree.
# =============================================================================

@test "S-complexity quality_stall at sonnet bails in bash backend (does not escalate to opus)" {
    local sr='{"status":"error","error_kind":"quality_stall","model":"sonnet","complexity":"S"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || fail "Expected bail for S-at-sonnet quality_stall, got: $action ($output)"
    [[ "$output" == *"S-complexity"* ]] || fail "Expected S-complexity reason, got: $output"
}

@test "backend parity: compose path also bails S-at-sonnet quality_stall" {
    local sr='{"status":"error","error_kind":"quality_stall","model":"sonnet","complexity":"S"}'
    # Skill-native compose path (bash sub-backends), NOT ESCALATION_POLICY_BACKEND=bash
    run env RETRY_POLICY_BACKEND=bash MODEL_FALLBACK_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || fail "Expected compose bail for S-at-sonnet quality_stall, got: $action ($output)"
}

@test "M-complexity quality_stall at sonnet still escalates to opus (bash backend, no over-blocking)" {
    local sr='{"status":"error","error_kind":"quality_stall","model":"sonnet","complexity":"M"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action model
    action=$(printf '%s' "$output" | jq -r '.action')
    model=$(printf '%s' "$output" | jq -r '.model')
    [ "$action" = "escalate" ] || fail "Expected escalate for M quality_stall, got: $action ($output)"
    [ "$model" = "opus" ] || fail "Expected opus for M quality_stall, got: $model"
}

@test "L-complexity quality_stall at sonnet still escalates to opus (bash backend, no over-blocking)" {
    local sr='{"status":"error","error_kind":"quality_stall","model":"sonnet","complexity":"L"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action model
    action=$(printf '%s' "$output" | jq -r '.action')
    model=$(printf '%s' "$output" | jq -r '.model')
    [ "$action" = "escalate" ] || fail "Expected escalate for L quality_stall, got: $action ($output)"
    [ "$model" = "opus" ] || fail "Expected opus for L quality_stall, got: $model"
}

# =============================================================================
# S-COMPLEXITY UNCAPPED RETRY — max_turns_exhausted branch (issue #637)
#
# On error_max_turns the escalation path's real benefit is that the retry runs
# with the turn cap REMOVED, not that the model changes.  The #579 gate threw
# that cap-lift away along with the model upgrade, so an S task that merely
# needed more turns was recorded failed after a single capped attempt.
# decide-action must now return a SAME-MODEL retry (never opus) for
# S + sonnet + max_turns_exhausted, in both backends.
# =============================================================================

@test "S-complexity max_turns_exhausted at sonnet retries instead of bailing (issue #637)" {
    local sr='{"status":"error","error_kind":"max_turns_exhausted","model":"sonnet","complexity":"S"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "retry_same" ] || \
        fail "Expected retry_same for S-at-sonnet max_turns, got: $action ($output)"
}

@test "S-complexity max_turns retry is flagged uncapped and stays at sonnet" {
    local sr='{"status":"error","error_kind":"max_turns_exhausted","model":"sonnet","complexity":"S"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local uncapped model
    uncapped=$(printf '%s' "$output" | jq -r '.uncapped // false')
    model=$(printf '%s' "$output" | jq -r '.model // empty')
    [ "$uncapped" = "true" ] || \
        fail "Expected uncapped:true marker, got: $output"
    [ "$model" != "opus" ] || \
        fail "S task must never be routed to opus (issue #579), got: $output"
}

@test "backend parity: compose path also retries S-at-sonnet max_turns uncapped" {
    local sr='{"status":"error","error_kind":"max_turns_exhausted","model":"sonnet","complexity":"S"}'
    # Skill-native compose path (bash sub-backends), NOT ESCALATION_POLICY_BACKEND=bash
    run env RETRY_POLICY_BACKEND=bash MODEL_FALLBACK_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action uncapped
    action=$(printf '%s' "$output" | jq -r '.action')
    uncapped=$(printf '%s' "$output" | jq -r '.uncapped // false')
    [ "$action" = "retry_same" ] || \
        fail "Expected compose retry_same for S-at-sonnet max_turns, got: $action ($output)"
    [ "$uncapped" = "true" ] || \
        fail "Expected compose uncapped:true marker, got: $output"
}

@test "uncapped retry is still bounded by MAX_ESCALATIONS_PER_RUN (AC5)" {
    local sr='{"status":"error","error_kind":"max_turns_exhausted","model":"sonnet","complexity":"S"}'
    run env MAX_ESCALATIONS_PER_RUN=5 ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[{},{},{},{},{}]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || \
        fail "Uncapped retry must not bypass the per-run cap, got: $action ($output)"
    [[ "$output" == *"escalation cap reached"* ]] || \
        fail "Expected cap-reached reason, got: $output"
}

@test "S-complexity max_turns_exhausted_at_ceiling still bails (no uncapped retry)" {
    local sr='{"status":"error","error_kind":"max_turns_exhausted_at_ceiling","model":"sonnet","complexity":"S"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || \
        fail "Expected bail at ceiling, got: $action ($output)"
}

@test "S-complexity double_timeout at sonnet still bails (cap-lift is max_turns only)" {
    local sr='{"status":"error","error_kind":"double_timeout","model":"sonnet","complexity":"S"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action
    action=$(printf '%s' "$output" | jq -r '.action')
    [ "$action" = "bail" ] || \
        fail "double_timeout must not gain an uncapped retry, got: $action ($output)"
}

@test "M-complexity max_turns_exhausted at sonnet still escalates to opus" {
    local sr='{"status":"error","error_kind":"max_turns_exhausted","model":"sonnet","complexity":"M"}'
    run env ESCALATION_POLICY_BACKEND=bash \
        bash "$TEST_TMP/decide-action.sh" "$sr" '[]'
    [ "$status" -eq 0 ]
    local action model
    action=$(printf '%s' "$output" | jq -r '.action')
    model=$(printf '%s' "$output" | jq -r '.model')
    [ "$action" = "escalate" ] || \
        fail "Expected escalate for M max_turns, got: $action ($output)"
    [ "$model" = "opus" ] || fail "Expected opus for M max_turns, got: $model"
}

@test "stage_result envelope carries complexity field (issue #579)" {
    source "$MODEL_CONFIG_ARRAYS_FILE"
    local sr
    sr=$(_emit_stage_result "error" "null" "" "[]" "sonnet" '"double_timeout"' 100 "" "S")
    local cx
    cx=$(printf '%s' "$sr" | jq -r '.complexity')
    [ "$cx" = "S" ] || fail "Expected complexity=S in envelope, got: $cx ($sr)"
}

# =============================================================================
# EMPTY OUTPUT → MODEL ESCALATION (AC2)
# =============================================================================

@test "empty output escalates to next model instead of failing" {
    source "$MODEL_CONFIG_ARRAYS_FILE"
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

    # test-iter-1 resolves to sonnet (standard tier)
    local result
    result=$(run_stage "test-iter-1" "prompt" "test-schema.json" "" "" | grep '^{')
    [ -n "$result" ] || fail "run_stage returned no JSON output"

    local status_val
    status_val=$(printf '%s' "$result" | jq -r '.status')
    [ "$status_val" = "success" ] || \
        fail "Expected success after escalation, got: $status_val"

    # Second call must use escalated model (opus, the sonnet→opus step)
    local second_call_args
    second_call_args=$(cat "$TEST_TMP/call-2-args.txt" 2>/dev/null)
    [[ "$second_call_args" == *"--model opus"* ]] || \
        fail "Expected --model opus for empty output escalation. Args: $second_call_args"
}

@test "empty output records escalation with reason 'no_structured_output'" {
    source "$MODEL_CONFIG_ARRAYS_FILE"
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

    # The empty-output (is_error, no structured_output) path classifies as
    # error_kind=no_structured_output; decide-action.sh's default escalate
    # branch records the reason "no_structured_output: escalating from ...".
    local reason
    reason=$(jq -r '.escalations[0].reason // empty' "$STATUS_FILE")
    [[ "$reason" == "no_structured_output"* ]] || \
        fail "Expected escalation reason starting 'no_structured_output', got: $reason"
}

@test "empty output escalation uses .result fallback when no structured_output" {
    source "$MODEL_CONFIG_ARRAYS_FILE"
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
    source "$MODEL_CONFIG_ARRAYS_FILE"
    local tier
    tier=$(_stage_to_tier "pr")
    [ "$tier" = "standard" ] || \
        fail "Expected PR stage tier='standard', got: $tier"
}

@test "PR stage resolves to sonnet" {
    source "$MODEL_CONFIG_ARRAYS_FILE"
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
