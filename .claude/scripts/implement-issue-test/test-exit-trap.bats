#!/usr/bin/env bats
#
# test-exit-trap.bats
# Tests for EXIT trap state rewriting when the orchestrator is killed mid-stage.
#
# AC2: When the orchestrator exits with state="running", the EXIT trap rewrites
# it to interrupted_during_<stage> before metrics are exported.
# AC4: BATS test covers the SIGTERM-mid-stage scenario and passes.
#
# These tests cover _rewrite_running_to_interrupted(), the helper called from
# the EXIT trap, which is implemented alongside the trap update in
# implement-issue-orchestrator.sh (issue #325 task 2).
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# UNIT: _rewrite_running_to_interrupted
# =============================================================================

@test "_rewrite_running_to_interrupted rewrites state from running to interrupted_during_<stage>" {
    init_status
    set_stage_started "merge_pr"

    local pre_state
    pre_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$pre_state" = "running" ]

    _rewrite_running_to_interrupted

    local post_state
    post_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$post_state" = "interrupted_during_merge_pr" ]
}

@test "_rewrite_running_to_interrupted embeds current_stage in the new state name" {
    init_status
    set_stage_started "implement"

    _rewrite_running_to_interrupted

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "interrupted_during_implement" ]
}

@test "_rewrite_running_to_interrupted does not modify state when already completed" {
    init_status
    set_final_state "completed"

    _rewrite_running_to_interrupted

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "completed" ]
}

@test "_rewrite_running_to_interrupted does not modify state when already error" {
    init_status
    set_final_state "error"

    _rewrite_running_to_interrupted

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "error" ]
}

@test "_rewrite_running_to_interrupted uses unknown stage when current_stage is null" {
    init_status
    # Set state to running and explicitly null current_stage to simulate the
    # edge case of a very early exit before any stage has been started.
    # (init_status sets current_stage="parse_issue"; we must clear it here.)
    jq '.state = "running" | .current_stage = null' "$STATUS_FILE" \
        > "${STATUS_FILE}.tmp" \
        && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

    _rewrite_running_to_interrupted

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "interrupted_during_unknown" ]
}

@test "_rewrite_running_to_interrupted is a no-op when STATUS_FILE does not exist" {
    rm -f "$STATUS_FILE"
    # Must not error out when there is no file to rewrite.
    run _rewrite_running_to_interrupted
    [ "$status" -eq 0 ]
}

# =============================================================================
# INTEGRATION: SIGTERM mid-stage (full EXIT trap exercise)
# =============================================================================

@test "EXIT trap rewrites running state to interrupted_during_<stage> when process receives SIGTERM" {
    init_status
    set_stage_started "merge_pr"

    # Confirm precondition: we are mid-stage with state=running.
    local pre_state
    pre_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$pre_state" = "running" ]

    # Build a wrapper that sources the orchestrator's extracted functions and
    # registers the post-task-2 EXIT trap, then sleeps (simulating a blocked
    # stage).  Killing it with SIGTERM triggers the EXIT trap.
    # A ready-file handshake eliminates the race between sourcing the large
    # functions file and the test sending SIGTERM.
    local wrapper="$TEST_TMP/sigterm_wrapper.sh"
    local ready_file="$TEST_TMP/wrapper_ready"
    cat > "$wrapper" << WRAPPER
#!/usr/bin/env bash
source "$TEST_TMP/orchestrator_functions.bash"
export STATUS_FILE="$STATUS_FILE"
export LOG_BASE="$LOG_BASE"
export LOG_FILE="$LOG_FILE"
# EXIT trap as it will look after issue-325 task 2 is applied:
trap '_rewrite_running_to_interrupted; write_task_summary_to_status; export_metrics' EXIT
# SIGTERM trap mirrors the orchestrator: convert signal into a clean exit so
# the EXIT trap fires reliably (bash may not run EXIT when blocked on a
# foreground child process receiving an unhandled SIGTERM).
trap 'exit 143' TERM
# Signal readiness after all traps are registered, then block.
touch "$ready_file"
sleep 30
WRAPPER
    chmod +x "$wrapper"

    "$wrapper" &
    local pid=$!
    # Wait until the wrapper has sourced functions and registered its traps.
    local i=0
    while [[ ! -f "$ready_file" ]] && ((i++ < 50)); do
        sleep 0.1
    done
    kill -TERM "$pid"
    wait "$pid" 2>/dev/null || true

    local final_state
    final_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$final_state" = "interrupted_during_merge_pr" ]
}

@test "EXIT trap preserves terminal state when process exits normally" {
    init_status
    set_stage_started "merge_pr"
    set_final_state "completed"

    local wrapper="$TEST_TMP/normal_exit_wrapper.sh"
    cat > "$wrapper" << WRAPPER
#!/usr/bin/env bash
source "$TEST_TMP/orchestrator_functions.bash"
export STATUS_FILE="$STATUS_FILE"
export LOG_BASE="$LOG_BASE"
export LOG_FILE="$LOG_FILE"
trap '_rewrite_running_to_interrupted; write_task_summary_to_status; export_metrics' EXIT
trap 'exit 143' TERM
# Normal exit — state is already "completed"
exit 0
WRAPPER
    chmod +x "$wrapper"

    run "$wrapper"
    # Wrapper exits cleanly; state must remain completed, not be rewritten.
    local final_state
    final_state=$(jq -r '.state' "$STATUS_FILE")
    [ "$final_state" = "completed" ]
}

# =============================================================================
# END-TO-END: the REAL orchestrator process under SIGTERM
# =============================================================================
#
# The integration test above exercises a wrapper that re-registers the EXIT/TERM
# traps by hand, so it proves the helper works but NOT that the shipped
# implement-issue-orchestrator.sh actually wires the traps up.  This test runs
# the real script end-to-end: it blocks mid parse_issue stage (state=running),
# receives SIGTERM, and must leave status.json at interrupted_during_parse_issue
# — never "running".  If the `trap ... EXIT` or `trap 'exit 143' TERM` lines are
# ever dropped from the orchestrator, only this test catches it.

@test "real orchestrator: SIGTERM mid-stage leaves status.json interrupted_during_<stage>, not running" {
    # Mock gh so the first external call of the parse_issue stage
    # (read-issue.sh -> `gh issue view`) blocks indefinitely, pinning the
    # orchestrator at state=running mid-stage until we signal it.
    local mock_bin="$TEST_TMP/mockbin"
    mkdir -p "$mock_bin"
    cat > "$mock_bin/gh" << 'GH'
#!/usr/bin/env bash
# Block so the orchestrator stays inside the parse_issue stage. The sleep is a
# safety bound only — the process-group SIGTERM below kills it immediately.
exec sleep 60
GH
    chmod +x "$mock_bin/gh"
    export PATH="$mock_bin:$PATH"

    local status_file="$TEST_TMP/real_status.json"

    # Launch the REAL orchestrator in its own process group (monitor mode) so a
    # single process-group SIGTERM takes down the blocking child at once and the
    # orchestrator's own TERM/EXIT traps fire without waiting on that child.
    # (--quiet suppresses issue comments so no `gh` call happens before the
    # parse_issue stage.)
    set -m
    "$ORCHESTRATOR_SCRIPT" --issue 123 --branch test --quiet \
        --status-file "$status_file" > "$TEST_TMP/orch.out" 2>&1 &
    local pid=$!
    set +m

    # Wait until the orchestrator has reached state=running mid parse_issue.
    local i=0 state=""
    while ((i++ < 100)); do
        if [[ -f "$status_file" ]]; then
            state=$(jq -r '.state // empty' "$status_file" 2>/dev/null || true)
            [[ "$state" == "running" ]] && break
        fi
        sleep 0.1
    done

    # Precondition: genuinely mid-stage with state=running (not initializing).
    [ "$state" = "running" ]
    local pre_stage
    pre_stage=$(jq -r '.current_stage' "$status_file")
    [ "$pre_stage" = "parse_issue" ]

    # SIGTERM the whole process group; the orchestrator's traps must rewrite the
    # running state before the process exits.
    kill -TERM -"$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true

    # The EXIT trap must have rewritten running -> interrupted_during_parse_issue.
    local final_state
    final_state=$(jq -r '.state' "$status_file")
    [ "$final_state" = "interrupted_during_parse_issue" ]
    [ "$final_state" != "running" ]
}
