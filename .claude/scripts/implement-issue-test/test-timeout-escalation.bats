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
# PARALLEL TASK WALL CLOCK vs SERIAL STAGE TIMEOUT (issue #673)
#
# MAX_TASK_WALL_TIME_SECS bounds a task run in PARALLEL (the watchdog in
# run_task_in_worktree's launcher); get_stage_timeout("implement-task-*")
# bounds the same task retried SERIALLY after a failed parallel batch. The
# two are set independently — one in platform.sh's config override, the
# other as the orchestrator's in-source ${:-1800} fallback — and drifted
# apart once already (platform.sh stayed at 900 after the orchestrator
# default rose 900->1800). When the parallel ceiling is tighter, a task
# that would succeed serially gets killed in parallel, the whole batch is
# discarded, and every task in it re-runs serially, paying for the work
# twice.
#
# Environment-override sourcing path: BOTH copies of the fallback —
# platform.sh:140 and implement-issue-orchestrator.sh:134 — use the exact
# same `${MAX_TASK_WALL_TIME_SECS:-1800}` pattern, and production sources
# platform.sh first (orchestrator.sh:70) before reaching its own line 134.
# So an operator's env-var override has exactly one live entry point:
# platform.sh's line resolves env-var-or-default, and by the time the
# orchestrator reaches its own line the var is already set, making that
# second fallback an inert no-op re-assignment there — PROVIDED platform.sh
# is actually in the sourcing chain, which implement-issue-orchestrator.sh
# itself always guarantees (it loud-aborts at line ~63 if platform.sh can't
# be resolved). The orchestrator's own fallback only does real work when
# something sources its functions WITHOUT going through that guard —
# exactly what source_orchestrator_functions() below does: it awk-extracts
# MAX_* declarations into orchestrator_functions.bash, and that extraction
# drops the `source platform.sh` line along with it, which is why setup()
# has to source the real platform.sh itself, in the right order, before
# sourcing the extracted file. This mirrors the drift-prone gap #673 fell
# into: platform.sh's override capped parallel tasks at 900s while the
# orchestrator's own fallback (only reachable when platform.sh isn't in
# the chain) had moved on to 1800s.
#
# setup()'s source_orchestrator_functions call sources the REAL
# .claude/config/platform.sh (via the config/ -> .claude/config symlink
# installed by setup_test_env) BEFORE the orchestrator's own fallback line,
# the same order production sourcing uses — so MAX_TASK_WALL_TIME_SECS
# below reflects whatever this repo's platform.sh actually resolves to, and
# these tests fail the instant it drops below the serial timeout again.
#
# Why the control test below ("a MAX_TASK_WALL_TIME_SECS below the serial
# timeout fails the invariant") re-sources in an isolated `bash -c`
# subprocess rather than reusing this shell: setup() already sourced
# platform.sh once here, so MAX_TASK_WALL_TIME_SECS is already a set
# variable in this process — assigning a new env override and re-running
# the fallback in-place wouldn't cleanly prove the override actually flows
# through `${:-1800}` the way a fresh process sees it. A genuinely fresh
# `bash -c` process, given the override only via `env`, reproduces exactly
# what a real invocation resolves to. It also sidesteps the `readonly -a`
# array redeclaration hazard documented on that test's own re-source call
# (see MODEL_CONFIG_ARRAYS_FILE in helpers/test-helper.bash) by sourcing
# only platform.sh and the extracted orchestrator functions there — never
# model-config.sh a second time in a shell that already has it.
# =============================================================================

@test "serial implement-task stage timeout is 1800s (issue #673 baseline)" {
    source "$MODEL_CONFIG_ARRAYS_FILE"
    local serial_timeout
    serial_timeout=$(get_stage_timeout "implement-task-1" "")
    [ "$serial_timeout" -eq 1800 ] || \
        fail "Expected serial implement-task timeout=1800, got: $serial_timeout"
}

# assert_wall_time_covers_serial <resolved_wall> <serial_timeout> <label>
#
# Shared issue #673 invariant: the resolved parallel wall time must never
# be tighter than the serial implement-task stage timeout it stands in
# for — otherwise a task that would succeed serially gets killed in
# parallel and the whole batch re-runs serially. Extracted so the guard
# test below (proving today's real values satisfy it) and the control
# test further down (proving the same comparison actually catches a
# drifted value) run the exact same check rather than two copies that
# could silently diverge.
assert_wall_time_covers_serial() {
    local resolved_wall="$1"
    local serial_timeout="$2"
    local label="$3"

    (( resolved_wall >= serial_timeout )) || \
        fail "${label}: wall_time=${resolved_wall}s <" \
            "serial stage timeout=${serial_timeout}s — a task that would" \
            "succeed serially is killed in parallel and the whole batch" \
            "re-runs serially (issue #673)"
}

@test "MAX_TASK_WALL_TIME_SECS (parallel) is not tighter than the serial implement-task timeout, across all complexities" {
    # Parametrised over the full complexity axis ("" S M L) rather than
    # just the empty/default case: get_stage_timeout escalates the
    # serial implement-task timeout to 3600s at complexity=L (see
    # implement-issue-orchestrator.sh's get_stage_timeout). The flat
    # MAX_TASK_WALL_TIME_SECS constant deliberately stays at 1800s (raising
    # it would give small/medium tasks the same oversized watchdog as L
    # tasks — see the wiring test below); per-task coverage comes from
    # get_task_wall_time(), which takes max(MAX_TASK_WALL_TIME_SECS,
    # get_stage_timeout("implement-task", cx)). Checking get_task_wall_time
    # here (rather than the raw constant) still catches the #673 drift class
    # for every complexity tier, without re-litigating what tests 37-40
    # already prove about get_task_wall_time's own formula.
    source "$MODEL_CONFIG_ARRAYS_FILE"

    local -a complexities=("" "S" "M" "L")
    local cx serial_timeout resolved_wall
    for cx in "${complexities[@]}"; do
        serial_timeout=$(get_stage_timeout "implement-task-1" "$cx")

        if [[ "$cx" == "L" ]]; then
            [ "$serial_timeout" -eq 3600 ] || \
                fail "Expected get_stage_timeout(implement-task-1, L)=3600," \
                    "got: $serial_timeout"
        fi

        resolved_wall=$(get_task_wall_time "$cx")
        assert_wall_time_covers_serial "$resolved_wall" "$serial_timeout" \
            "complexity='${cx}'"
    done
}

@test "parallel watchdog region resolves a per-task wall time for L, not the flat global (issue #673 wiring)" {
    # A "fix" that just raises MAX_TASK_WALL_TIME_SECS to 3600s for every
    # task would satisfy a flat-constant invariant while giving small
    # (S/M) tasks the same oversized watchdog as L tasks — defeating the
    # point of a wall-time guard. The real fix (issue #678) resolves a
    # PER-TASK wall time via get_task_wall_time() (using the task's
    # already-computed $tsize), which itself wraps get_stage_timeout and
    # is proven correct by the get_task_wall_time unit tests below. Search
    # a window wide enough to cover both the per-task resolution (computed
    # once per loop iteration, ahead of the launch) and the launch itself.
    local watchdog_region
    watchdog_region=$(grep -B 40 -A 20 -F \
        'Launch in background subshell with wall-time guard' \
        "$ORCHESTRATOR_SCRIPT")

    [[ -n "$watchdog_region" ]] || \
        fail "Could not locate the parallel watchdog launch region in" \
            "$ORCHESTRATOR_SCRIPT"

    printf '%s\n' "$watchdog_region" | grep -q 'get_task_wall_time' || \
        fail "Expected the parallel watchdog region to resolve a" \
            "per-task wall time via get_task_wall_time (using tsize)," \
            "not rely solely on the flat MAX_TASK_WALL_TIME_SECS global." \
            $'\nRegion:\n'"$watchdog_region"
}

@test "a MAX_TASK_WALL_TIME_SECS below the serial timeout fails the invariant" {
    # Proves the guard above actually discriminates rather than trivially
    # passing: reproduce the pre-fix drift (platform.sh pinned at 900,
    # serial timeout risen to 1800) for real — pre-set
    # MAX_TASK_WALL_TIME_SECS=900 in the environment and re-source the
    # actual production platform.sh plus the extracted orchestrator
    # functions in an ISOLATED subshell, then run the shared invariant
    # helper against that live resolved value.
    #
    # This must NOT re-source .claude/scripts/model-config.sh in this
    # test's own shell: setup()'s source_orchestrator_functions already
    # sourced it once here, and a second source in the same (unforked)
    # process hits the `readonly -a` array redeclaration hazard documented
    # on MODEL_CONFIG_ARRAYS_FILE in helpers/test-helper.bash.
    # get_stage_timeout/get_task_wall_time never touch model-config.sh, so
    # the subshell below sources only platform.sh (for the drifted
    # constant) and the orchestrator functions file — nothing that trips
    # the guard.
    run env MAX_TASK_WALL_TIME_SECS=900 bash -c '
        source "$TEST_TMP/config/platform.sh"
        source "$TEST_TMP/orchestrator_functions.bash"
        printf "%s %s\n" \
            "$MAX_TASK_WALL_TIME_SECS" \
            "$(get_stage_timeout "implement-task-1" "")"
    '
    [ "$status" -eq 0 ] || \
        fail "Isolated config/orchestrator-functions subshell failed:" \
            "$output"

    local resolved_wall serial_timeout
    read -r resolved_wall serial_timeout <<< "$output"

    [ "$resolved_wall" = "900" ] || \
        fail "Expected the re-sourced MAX_TASK_WALL_TIME_SECS to resolve" \
            "to 900, got: $resolved_wall"

    ! assert_wall_time_covers_serial "$resolved_wall" "$serial_timeout" \
        "drift repro" || \
        fail "Expected the shared invariant helper to report a" \
            "violation for a live wall_time=${resolved_wall}s against" \
            "serial_timeout=${serial_timeout}s"
}

# =============================================================================
# get_task_wall_time() — per-task watchdog budget (issue #678)
#
# The tests above only assert the flat MAX_TASK_WALL_TIME_SECS constant
# happens to be >= the serial implement-task timeout today; nothing stops
# them drifting apart again the way #673 did. get_task_wall_time() removes
# the drift risk structurally: the parallel watchdog now always takes
# max(MAX_TASK_WALL_TIME_SECS, get_stage_timeout("implement-task", size)),
# so an "L" task's watchdog can never be tighter than its own stage timeout.
# =============================================================================

@test "get_task_wall_time is defined" {
    [ "$(type -t get_task_wall_time)" = "function" ]
}

@test "get_task_wall_time matches MAX_TASK_WALL_TIME_SECS for default size" {
    local result
    result=$(get_task_wall_time "")
    [ "$result" -eq "$MAX_TASK_WALL_TIME_SECS" ] || \
        fail "Expected get_task_wall_time('')=$MAX_TASK_WALL_TIME_SECS," \
            "got: $result"
}

@test "get_task_wall_time widens the watchdog for L-complexity tasks" {
    local result stage_timeout
    stage_timeout=$(get_stage_timeout "implement-task" "L")
    result=$(get_task_wall_time "L")
    [ "$result" -eq "$stage_timeout" ] || \
        fail "Expected get_task_wall_time('L')=$stage_timeout," \
            "got: $result"
    (( result >= MAX_TASK_WALL_TIME_SECS )) || \
        fail "get_task_wall_time('L')=$result must never be tighter than" \
            "MAX_TASK_WALL_TIME_SECS=$MAX_TASK_WALL_TIME_SECS"
}

@test "get_task_wall_time never returns less than MAX_TASK_WALL_TIME_SECS" {
    # Simulate the #673 drift (platform.sh pinned low) and confirm the
    # per-task watchdog still can't fall below the flat floor.
    local result
    result=$(MAX_TASK_WALL_TIME_SECS=900 get_task_wall_time "")
    (( result >= 900 )) || \
        fail "get_task_wall_time must not return below" \
            "MAX_TASK_WALL_TIME_SECS=900, got: $result"
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
