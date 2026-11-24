#!/usr/bin/env bats
#
# test-status-functions.bats
# Tests for status file management functions
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env

    # Set required variables
    export ISSUE_NUMBER=123
    export BASE_BRANCH=test
    export STATUS_FILE="$TEST_TMP/status.json"
    export LOG_BASE="$TEST_TMP/logs/test"
    export LOG_FILE="$LOG_BASE/orchestrator.log"
    export STAGE_COUNTER=0

    mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"

    # Source the orchestrator functions
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# INIT_STATUS
# =============================================================================

@test "init_status creates status file with valid JSON" {
    init_status
    [ -f "$STATUS_FILE" ]
    # Verify it's valid JSON, not an empty or corrupt file
    jq -e '.' "$STATUS_FILE" >/dev/null 2>&1 || fail "Status file is not valid JSON"
    # Verify it has the expected top-level structure
    local keys
    keys=$(jq -r 'keys[]' "$STATUS_FILE" | sort | tr '\n' ',')
    [[ "$keys" == *"state,"* ]] || fail "Missing 'state' key in status file"
    [[ "$keys" == *"stages,"* ]] || fail "Missing 'stages' key in status file"
}

@test "init_status sets state to initializing" {
    init_status
    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "initializing" ]
}

@test "init_status sets issue number" {
    init_status
    local issue
    issue=$(jq -r '.issue' "$STATUS_FILE")
    [ "$issue" = "123" ]
}

@test "init_status stores issue as string type (supports Jira keys like KIN-123)" {
    export ISSUE_NUMBER="KIN-456"
    init_status
    local issue_type
    issue_type=$(jq -r '.issue | type' "$STATUS_FILE")
    [ "$issue_type" = "string" ]
    local issue_val
    issue_val=$(jq -r '.issue' "$STATUS_FILE")
    [ "$issue_val" = "KIN-456" ]
}

@test "init_status initializes all stages as pending" {
    init_status
    local parse_issue_status validate_plan_status impl_status quality_status
    local test_loop_status docs_status pr_status pr_review_status complete_status
    parse_issue_status=$(jq -r '.stages.parse_issue.status' "$STATUS_FILE")
    validate_plan_status=$(jq -r '.stages.validate_plan.status' "$STATUS_FILE")
    impl_status=$(jq -r '.stages.implement.status' "$STATUS_FILE")
    quality_status=$(jq -r '.stages.quality_loop.status' "$STATUS_FILE")
    test_loop_status=$(jq -r '.stages.test_loop.status' "$STATUS_FILE")
    docs_status=$(jq -r '.stages.docs.status' "$STATUS_FILE")
    pr_status=$(jq -r '.stages.pr.status' "$STATUS_FILE")
    pr_review_status=$(jq -r '.stages.pr_review.status' "$STATUS_FILE")
    complete_status=$(jq -r '.stages.complete.status' "$STATUS_FILE")

    [ "$parse_issue_status" = "pending" ]
    [ "$validate_plan_status" = "pending" ]
    [ "$impl_status" = "pending" ]
    [ "$quality_status" = "pending" ]
    [ "$test_loop_status" = "pending" ]
    [ "$docs_status" = "pending" ]
    [ "$pr_status" = "pending" ]
    [ "$pr_review_status" = "pending" ]
    [ "$complete_status" = "pending" ]
}

@test "init_status initializes stages with null timestamps" {
    init_status
    local parse_issue_started validate_plan_started parse_issue_completed validate_plan_completed
    parse_issue_started=$(jq -r '.stages.parse_issue.started_at' "$STATUS_FILE")
    validate_plan_started=$(jq -r '.stages.validate_plan.started_at' "$STATUS_FILE")
    parse_issue_completed=$(jq -r '.stages.parse_issue.completed_at' "$STATUS_FILE")
    validate_plan_completed=$(jq -r '.stages.validate_plan.completed_at' "$STATUS_FILE")

    [ "$parse_issue_started" = "null" ]
    [ "$validate_plan_started" = "null" ]
    [ "$parse_issue_completed" = "null" ]
    [ "$validate_plan_completed" = "null" ]
}

@test "init_status sets log_dir" {
    init_status
    local log_dir
    log_dir=$(jq -r '.log_dir' "$STATUS_FILE")
    [ "$log_dir" = "$LOG_BASE" ]
}

@test "init_status initializes empty tasks array" {
    init_status
    local tasks_len
    tasks_len=$(jq '.tasks | length' "$STATUS_FILE")
    [ "$tasks_len" = "0" ]
}

# =============================================================================
# UPDATE_STAGE
# =============================================================================

@test "update_stage changes stage status and updates current_stage" {
    init_status
    update_stage "setup" "in_progress"

    local status
    status=$(jq -r '.stages.setup.status' "$STATUS_FILE")
    [ "$status" = "in_progress" ]

    # Verify current_stage was also updated
    local current
    current=$(jq -r '.current_stage' "$STATUS_FILE")
    [ "$current" = "setup" ]
}

@test "update_stage with extra field" {
    init_status
    update_stage "implement" "in_progress" "task_progress" "2/5"

    local progress
    progress=$(jq -r '.stages.implement.task_progress' "$STATUS_FILE")
    [ "$progress" = "2/5" ]
}

@test "update_stage updates current_stage" {
    init_status
    update_stage "quality_loop" "in_progress"

    local current
    current=$(jq -r '.current_stage' "$STATUS_FILE")
    [ "$current" = "quality_loop" ]
}

@test "update_stage updates last_update timestamp" {
    init_status
    local before
    before=$(jq -r '.last_update' "$STATUS_FILE")

    sleep 1
    update_stage "docs" "completed"

    local after
    after=$(jq -r '.last_update' "$STATUS_FILE")
    [ "$before" != "$after" ]
}

# =============================================================================
# SET_STAGE_STARTED / SET_STAGE_COMPLETED
# =============================================================================

@test "set_stage_started sets status to in_progress" {
    init_status
    set_stage_started "setup"

    local status
    status=$(jq -r '.stages.setup.status' "$STATUS_FILE")
    [ "$status" = "in_progress" ]
}

@test "set_stage_started sets started_at timestamp in ISO format" {
    init_status
    set_stage_started "setup"

    local started_at
    started_at=$(jq -r '.stages.setup.started_at' "$STATUS_FILE")
    [ "$started_at" != "null" ]
    # Verify it looks like a timestamp (starts with a year)
    [[ "$started_at" =~ ^20[0-9]{2}- ]] || fail "started_at should be ISO timestamp, got: $started_at"
}

@test "set_stage_started sets state to running" {
    init_status
    set_stage_started "setup"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "running" ]
}

@test "set_stage_completed sets status to completed" {
    init_status
    set_stage_completed "setup"

    local status
    status=$(jq -r '.stages.setup.status' "$STATUS_FILE")
    [ "$status" = "completed" ]
}

@test "set_stage_completed sets completed_at timestamp in ISO format" {
    init_status
    set_stage_completed "setup"

    local completed_at
    completed_at=$(jq -r '.stages.setup.completed_at' "$STATUS_FILE")
    [ "$completed_at" != "null" ]
    # Verify it looks like a timestamp
    [[ "$completed_at" =~ ^20[0-9]{2}- ]] || fail "completed_at should be ISO timestamp, got: $completed_at"
}

# =============================================================================
# SET_TASKS
# =============================================================================

@test "set_tasks populates tasks array" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test"},{"id":2,"description":"Task 2","agent":"test"}]'
    set_tasks "$tasks"

    local count
    count=$(jq '.tasks | length' "$STATUS_FILE")
    [ "$count" = "2" ]
}

@test "set_tasks updates task_progress" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test"},{"id":2,"description":"Task 2","agent":"test"},{"id":3,"description":"Task 3","agent":"test"}]'
    set_tasks "$tasks"

    local progress
    progress=$(jq -r '.stages.implement.task_progress' "$STATUS_FILE")
    [ "$progress" = "0/3" ]
}

# =============================================================================
# UPDATE_TASK
# =============================================================================

@test "update_task changes task status" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test","status":"pending"}]'
    set_tasks "$tasks"

    update_task 1 "in_progress"

    local status
    status=$(jq -r '.tasks[0].status' "$STATUS_FILE")
    [ "$status" = "in_progress" ]
}

@test "update_task sets review_attempts" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test","status":"pending"}]'
    set_tasks "$tasks"

    update_task 1 "completed" 2

    local attempts
    attempts=$(jq -r '.tasks[0].review_attempts' "$STATUS_FILE")
    [ "$attempts" = "2" ]
}

@test "update_task sets current_task" {
    init_status
    local tasks='[{"id":1,"description":"Task 1","agent":"test"},{"id":2,"description":"Task 2","agent":"test"}]'
    set_tasks "$tasks"

    update_task 2 "in_progress"

    local current
    current=$(jq -r '.current_task' "$STATUS_FILE")
    [ "$current" = "2" ]
}

# =============================================================================
# SET_FINAL_STATE
# =============================================================================

@test "set_final_state sets state to completed" {
    init_status
    set_final_state "completed"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "completed" ]
}

@test "set_final_state sets state to error" {
    init_status
    set_final_state "error"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "error" ]
}

@test "set_final_state sets state to max_iterations_quality" {
    init_status
    set_final_state "max_iterations_quality"

    local state
    state=$(jq -r '.state' "$STATUS_FILE")
    [ "$state" = "max_iterations_quality" ]
}

# =============================================================================
# INCREMENT ITERATION COUNTERS
# =============================================================================

@test "increment_quality_iteration increments counter" {
    init_status
    increment_quality_iteration
    increment_quality_iteration

    local count
    count=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$count" = "2" ]
}

@test "increment_quality_iteration updates stage iteration" {
    init_status
    increment_quality_iteration
    increment_quality_iteration
    increment_quality_iteration

    local iteration
    iteration=$(jq -r '.stages.quality_loop.iteration' "$STATUS_FILE")
    [ "$iteration" = "3" ]
}

@test "increment_pr_review_iteration increments counter" {
    init_status
    increment_pr_review_iteration

    local count
    count=$(jq -r '.pr_review_iterations' "$STATUS_FILE")
    [ "$count" = "1" ]
}

@test "increment_pr_review_iteration updates stage iteration" {
    init_status
    increment_pr_review_iteration
    increment_pr_review_iteration

    local iteration
    iteration=$(jq -r '.stages.pr_review.iteration' "$STATUS_FILE")
    [ "$iteration" = "2" ]
}

# =============================================================================
# WORKTREE CWD — status writes target repo-root status.json
# =============================================================================

@test "status write from worktree subdirectory cwd updates repo-root status.json" {
    # STATUS_FILE is an absolute path set by setup; init at repo root
    init_status

    # Simulate the worktree subdirectory the orchestrator cds into during run_stage
    local wt_subdir="$TEST_TMP/logs/implement-issue/issue-123/worktrees/task-1"
    mkdir -p "$wt_subdir"

    # Move cwd into the worktree subdirectory
    cd "$wt_subdir"

    # Write status from within the subdirectory
    update_stage "setup" "in_progress"

    # The repo-root status.json (absolute path) must reflect the update
    local status
    status=$(jq -r '.stages.setup.status' "$STATUS_FILE")
    [ "$status" = "in_progress" ]

    # No stray status.json should appear in the worktree subdirectory
    [ ! -f "./status.json" ]
}

# =============================================================================
# CONCURRENT WRITERS (issue #642)
#
# status_json_write() gives every write its own mktemp temp path, which stops
# two overlapping writers from clobbering each other's temp FILE -- it does
# not, on its own, stop two overlapping read-modify-write cycles from losing
# an update (writer B's jq read can predate writer A's mv, so B's write
# silently overwrites A's). These tests drive REAL concurrent writers
# (background subshells + wait) against one status.json and assert neither
# failure mode from #642 occurs: a lost update, or a malformed status.json.
# =============================================================================

# Wait for a set of background PIDs, with a hard deadline so a stuck/
# deadlocked writer fails the test instead of hanging the whole suite.
# Usage: _wait_pids_or_fail <timeout_secs> <pid> [pid...]
_wait_pids_or_fail() {
    local timeout_secs="$1"
    shift
    local deadline=$((SECONDS + timeout_secs))
    local pid
    for pid in "$@"; do
        while kill -0 "$pid" 2>/dev/null; do
            if ((SECONDS >= deadline)); then
                kill -9 "$pid" 2>/dev/null
                fail "PID $pid did not finish within ${timeout_secs}s" \
                    "(possible deadlock/stale lock)"
            fi
            sleep 0.1
        done
        # A writer that returns non-zero lost its update (lock timeout / jq
        # failure). Without this check a starved lock passes as green.
        wait "$pid" || fail "PID $pid exited non-zero — its status write failed"
    done
}

@test "status_json_write: concurrent increments of the same counter are not lost" {
    init_status

    local n=20
    local -a pids=()
    local i
    for ((i = 1; i <= n; i++)); do
        increment_quality_iteration &
        pids+=("$!")
    done
    _wait_pids_or_fail 30 "${pids[@]}"

    jq -e '.' "$STATUS_FILE" >/dev/null 2>&1 \
        || fail "status.json is not valid JSON after concurrent writers"

    local count
    count=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$count" = "$n" ] || fail \
        "expected quality_iterations=$n after $n concurrent increments," \
        "got $count instead (an update was lost to a write race)"
}

@test "status_json_write: two concurrent writers to distinct fields both land their updates" {
    init_status

    (status_json_write --arg v "writer-a" '.merge_blocked_reason = $v') &
    local pid_a=$!
    (status_json_write --arg v "writer-b" '.branch = $v') &
    local pid_b=$!
    _wait_pids_or_fail 15 "$pid_a" "$pid_b"

    jq -e '.' "$STATUS_FILE" >/dev/null 2>&1 \
        || fail "status.json is not valid JSON after concurrent writers"

    local reason branch
    reason=$(jq -r '.merge_blocked_reason' "$STATUS_FILE")
    branch=$(jq -r '.branch' "$STATUS_FILE")
    [ "$reason" = "writer-a" ] || fail "writer-a's update is missing, got: $reason"
    [ "$branch" = "writer-b" ] || fail "writer-b's update is missing, got: $branch"
}

@test "status.json stays valid JSON and both stages land after a parallel post-task-style run" {
    # Mirrors run_parallel_post_task_stages: two independent stages started
    # and completed from concurrent subshells (issue #642 AC2).
    init_status

    (
        set_stage_started "e2e_verify"
        set_stage_completed "e2e_verify"
    ) &
    local pid_e2e=$!
    (
        set_stage_started "acceptance_test"
        set_stage_completed "acceptance_test"
    ) &
    local pid_accept=$!
    _wait_pids_or_fail 15 "$pid_e2e" "$pid_accept"

    jq -e '.' "$STATUS_FILE" >/dev/null 2>&1 \
        || fail "status.json is not valid JSON after a parallel stage run"

    local e2e_status accept_status
    e2e_status=$(jq -r '.stages.e2e_verify.status' "$STATUS_FILE")
    accept_status=$(jq -r '.stages.acceptance_test.status' "$STATUS_FILE")
    [ "$e2e_status" = "completed" ] || fail "e2e_verify update is missing: $e2e_status"
    [ "$accept_status" = "completed" ] || fail "acceptance_test update is missing: $accept_status"
}

@test "status_json_write: many concurrent writers all land their update and leave valid JSON" {
    init_status

    local n=30
    local -a pids=()
    local i
    # Each writer sets its OWN key, so a lost update is visible as a missing
    # key. Asserting only `jq -e .` would pass even if most writers timed out.
    for ((i = 1; i <= n; i++)); do
        status_json_write --arg k "w$i" --arg v "done" '.stress[$k] = $v' &
        pids+=("$!")
    done
    _wait_pids_or_fail 60 "${pids[@]}"

    [ -s "$STATUS_FILE" ] || fail "status.json is empty after concurrent writers"
    jq -e '.' "$STATUS_FILE" >/dev/null 2>&1 \
        || fail "status.json is not valid JSON after $n concurrent writers"

    local landed
    landed=$(jq -r '.stress | length' "$STATUS_FILE")
    [ "$landed" = "$n" ] || fail \
        "only $landed of $n concurrent updates landed (updates lost to a write race)"
}

# =============================================================================
# MKDIR FALLBACK LOCK (issue #642 AC4)
#
# CI has flock(1), so status_json_write's mkdir fallback — the only path with
# pidfile-based stale-lock detection — would otherwise never run here.
# STATUS_LOCK_IMPL=mkdir forces it so both branches are covered.
# =============================================================================

# Poll until a file exists, or fail. Usage: _wait_for_file <path> <timeout>
_wait_for_file() {
    local path="$1" deadline=$((SECONDS + ${2:-10}))
    while [[ ! -e "$path" ]]; do
        ((SECONDS >= deadline)) && fail "timed out waiting for $path"
        sleep 0.05
    done
}

@test "status_json_write: mkdir fallback serialises concurrent writers without losing updates" {
    export STATUS_LOCK_IMPL=mkdir
    init_status

    local n=15
    local -a pids=()
    local i
    for ((i = 1; i <= n; i++)); do
        increment_quality_iteration &
        pids+=("$!")
    done
    _wait_pids_or_fail 60 "${pids[@]}"

    local count
    count=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$count" = "$n" ] || fail \
        "expected quality_iterations=$n under the mkdir lock, got $count" \
        "(lost update, or waiters starved by a fixed-cadence backoff)"
}

@test "status lock: exactly one of N racing acquirers wins (#1151)" {
	export STATUS_LOCK_IMPL=mkdir
	export STATUS_LOCK_TIMEOUT=0
	init_status

	local n=12 i
	local -a pids=()
	for ((i = 1; i <= n; i++)); do
		(
			if _status_lock_acquire 2>/dev/null; then
				: > "$TEST_TMP/winner-$i"
			fi
			sleep 5
		) &
		pids+=("$!")
	done
	sleep 2

	# Count only files that exist: an unmatched glob stays literal, which
	# would make a zero-winner run look like exactly one winner.
	local -a winners=()
	local f
	for f in "$TEST_TMP"/winner-*; do
		[[ -e "$f" ]] && winners+=("$f")
	done
	kill "${pids[@]}" 2>/dev/null
	wait "${pids[@]}" 2>/dev/null || true
	[ "${#winners[@]}" -eq 1 ] || fail \
		"expected exactly 1 lock winner, got ${#winners[@]}: ${winners[*]}"
}

@test "status_json_write: mkdir lock left by a killed writer is broken as stale" {
    export STATUS_LOCK_IMPL=mkdir
    export STATUS_LOCK_TIMEOUT=5
    init_status

    # A writer that dies while holding the lock (SIGKILL mid read-modify-write)
    # leaves the lockdir behind. Its pidfile must name the SUBSHELL's pid --
    # recording the parent shell's $$ would leave a live-looking pid, stale
    # detection would never fire, and every later write would burn the timeout.
    (
        _status_lock_acquire
        : > "$TEST_TMP/holder-ready"
        sleep 60
    ) &
    local holder=$!
    _wait_for_file "$TEST_TMP/holder-ready" 10

    [ -d "${STATUS_FILE}.lockdir" ] || fail "holder did not create the lockdir"

    kill -9 "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null || true

    [ -d "${STATUS_FILE}.lockdir" ] \
        || skip "lockdir vanished before the stale-lock path could be exercised"

    run status_json_write --arg v "after-kill" '.branch = $v'
    [ "$status" -eq 0 ] || fail \
        "write after a killed lock holder failed (stale lock never broken): $output"

    local branch
    branch=$(jq -r '.branch' "$STATUS_FILE")
    [ "$branch" = "after-kill" ] || fail "update lost after stale-lock recovery: $branch"
}

@test "status lock: several waiters on a dead lock all land, none lost (#1151)" {
    export STATUS_LOCK_IMPL=mkdir
    export STATUS_LOCK_TIMEOUT=20
    init_status

    (
        _status_lock_acquire
        : > "$TEST_TMP/holder-ready"
        sleep 60
    ) &
    local holder=$!
    _wait_for_file "$TEST_TMP/holder-ready" 10
    kill -9 "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null || true

    local n=8 i
    local -a pids=()
    for ((i = 1; i <= n; i++)); do
        increment_quality_iteration &
        pids+=("$!")
    done
    _wait_pids_or_fail 40 "${pids[@]}"

    local count
    count=$(jq -r '.quality_iterations' "$STATUS_FILE")
    [ "$count" = "$n" ] || fail \
        "expected $n increments after dead-lock break, got $count"
}

@test "status lock: stale break file is removed and the stale lock broken" {
    export STATUS_LOCK_IMPL=mkdir
    export STATUS_LOCK_TIMEOUT=10
    export LOCK_STALE_AGE=5
    init_status

    mkdir -p "${STATUS_FILE}.lockdir"
    printf '%s\n' 999999 > "${STATUS_FILE}.lockdir/pid"
    : > "${STATUS_FILE}.lockdir.break"
    touch -t 200001010000 "${STATUS_FILE}.lockdir.break"

    run status_json_write --arg v "after-break" '.branch = $v'
    [ "$status" -eq 0 ] || fail "write blocked by orphaned break file: $output"
    [ "$(jq -r '.branch' "$STATUS_FILE")" = "after-break" ] \
        || fail "update lost after stale break file removal"
    [ ! -e "${STATUS_FILE}.lockdir.break" ] || fail "break file left behind"
}

@test "status lock: fresh break file makes the waiter time out, not spin" {
    export STATUS_LOCK_IMPL=mkdir
    export STATUS_LOCK_TIMEOUT=2
    export LOCK_STALE_AGE=3600
    init_status

    mkdir -p "${STATUS_FILE}.lockdir"
    printf '%s\n' 999999 > "${STATUS_FILE}.lockdir/pid"
    : > "${STATUS_FILE}.lockdir.break"

    local start=$SECONDS
    run _status_lock_acquire
    [ "$status" -eq 1 ] || fail "expected timeout (1), got $status: $output"
    (( SECONDS - start >= 2 )) || fail "returned before the deadline"
    (( SECONDS - start < 8 )) || fail "overran the deadline"
    [ -e "${STATUS_FILE}.lockdir.break" ] || fail "fresh break file removed"
}

@test "status lock: empty pidfile older than LOCK_STALE_AGE is broken" {
    export STATUS_LOCK_IMPL=mkdir
    export STATUS_LOCK_TIMEOUT=10
    export LOCK_STALE_AGE=5
    init_status

    mkdir -p "${STATUS_FILE}.lockdir"
    : > "${STATUS_FILE}.lockdir/pid"
    touch -t 200001010000 "${STATUS_FILE}.lockdir/pid"

    run status_json_write --arg v "after-empty" '.branch = $v'
    [ "$status" -eq 0 ] || fail "old empty pidfile blocked the write: $output"
    [ "$(jq -r '.branch' "$STATUS_FILE")" = "after-empty" ] \
        || fail "update lost after empty-pidfile break"
}

@test "status lock: empty pidfile younger than LOCK_STALE_AGE is waited on" {
    export STATUS_LOCK_IMPL=mkdir
    export STATUS_LOCK_TIMEOUT=2
    export LOCK_STALE_AGE=3600
    init_status

    mkdir -p "${STATUS_FILE}.lockdir"
    : > "${STATUS_FILE}.lockdir/pid"

    local start=$SECONDS
    run _status_lock_acquire
    [ "$status" -eq 1 ] || fail "expected timeout (1), got $status: $output"
    (( SECONDS - start >= 2 )) || fail "returned before the deadline"
    [ -e "${STATUS_FILE}.lockdir/pid" ] || fail "young empty pidfile removed"
}

@test "status_json_write: proceeds when mkdir lock is held by its own pid (#1117)" {
    export STATUS_LOCK_IMPL=mkdir
    export STATUS_LOCK_TIMEOUT=3
    init_status

    # Simulate an interrupted write whose trap handler writes status again.
    _status_lock_acquire

    local start=$SECONDS
    # Called directly, not via `run`: that forks a subshell with a new pid.
    status_json_write --arg v "reentrant" '.branch = $v' \
        || fail "self-held lock blocked the write"
    ((SECONDS - start < 2)) || fail "write waited on its own lock"

    local branch
    branch=$(jq -r '.branch' "$STATUS_FILE")
    [ "$branch" = "reentrant" ] || fail "update lost: $branch"
}

@test "status_json_write: still waits on a different live lock holder (#1117)" {
    export STATUS_LOCK_IMPL=mkdir
    export STATUS_LOCK_TIMEOUT=1
    init_status

    (
        _status_lock_acquire
        : > "$TEST_TMP/holder-ready"
        sleep 30
    ) &
    local holder=$!
    _wait_for_file "$TEST_TMP/holder-ready" 10

    run status_json_write --arg v "blocked" '.branch = $v'
    kill -9 "$holder" 2>/dev/null
    wait "$holder" 2>/dev/null || true

    [ "$status" -ne 0 ] || fail "write proceeded despite a live foreign holder"
    local branch
    branch=$(jq -r '.branch' "$STATUS_FILE")
    [ "$branch" != "blocked" ] || fail "foreign-held lock was bypassed"
}

# =============================================================================
# SYNC_STATUS_TO_LOG (issue #1057 — cp race fix)
# =============================================================================

@test "sync_status_to_log copies status.json to LOG_BASE" {
	init_status
	sync_status_to_log

	[ -f "$LOG_BASE/status.json" ] \
		|| fail "sync_status_to_log did not create $LOG_BASE/status.json"
	jq -e '.' "$LOG_BASE/status.json" >/dev/null 2>&1 \
		|| fail "synced status.json is not valid JSON"
}

@test "sync_status_to_log produces file identical to STATUS_FILE" {
	init_status
	update_stage "setup" "in_progress"
	sync_status_to_log

	local orig synced
	orig=$(jq -c '.' "$STATUS_FILE")
	synced=$(jq -c '.' "$LOG_BASE/status.json")
	[ "$orig" = "$synced" ] \
		|| fail "synced status.json differs from STATUS_FILE"
}

@test "sync_status_to_log does not leave temp files in LOG_BASE" {
	init_status
	sync_status_to_log

	local tmp_count
	tmp_count=$(find "$LOG_BASE" -maxdepth 1 -name '.status.json.*' | wc -l)
	[ "$tmp_count" -eq 0 ] \
		|| fail "temp file(s) left behind after sync: $tmp_count found"
}

@test "sync_status_to_log returns 0 when LOG_BASE is unset" {
	init_status
	local saved_log_base="$LOG_BASE"
	unset LOG_BASE
	run sync_status_to_log
	export LOG_BASE="$saved_log_base"
	[ "$status" -eq 0 ] \
		|| fail "sync_status_to_log returned $status when LOG_BASE is unset"
}

@test "sync_status_to_log returns 0 when STATUS_FILE does not exist" {
	local missing="$TEST_TMP/nonexistent-status.json"
	export STATUS_FILE="$missing"
	run sync_status_to_log
	[ "$status" -eq 0 ] \
		|| fail "sync_status_to_log returned $status for missing STATUS_FILE"
}

@test "sync_status_to_log is idempotent — calling twice leaves valid JSON" {
	init_status
	sync_status_to_log
	update_stage "setup" "completed"
	sync_status_to_log

	jq -e '.' "$LOG_BASE/status.json" >/dev/null 2>&1 \
		|| fail "status.json not valid JSON after second sync"
	local status_val
	status_val=$(jq -r '.stages.setup.status' "$LOG_BASE/status.json")
	[ "$status_val" = "completed" ] \
		|| fail "second sync did not reflect latest state: $status_val"
}

# Shadow cp with a stand-in that records every call in $TEST_TMP/cp-calls and
# fails the first $1 of them the way GNU cp does when the source is renamed
# over mid-copy (the Linux CI race, #1057); later calls run the real cp.
# Callers restore PATH themselves.
_shadow_cp_failing_first() {
	local fail_first="$1" real_cp mock_bin="$TEST_TMP/mock-bin"
	real_cp="$(command -v cp)"
	mkdir -p "$mock_bin"
	printf '%s\n' \
		'#!/usr/bin/env bash' \
		"echo call >> '$TEST_TMP/cp-calls'" \
		"if (( \$(wc -l < '$TEST_TMP/cp-calls') <= $fail_first )); then" \
		"	echo \"cp: skipping file '\$1', as it was replaced while being copied\" >&2" \
		'	exit 1' \
		'fi' \
		"exec '$real_cp' \"\$@\"" \
		> "$mock_bin/cp"
	chmod +x "$mock_bin/cp"
	export PATH="$mock_bin:$PATH"
}

@test "sync_status_to_log retries after one cp failure and leaves a byte-identical copy" {
	init_status
	update_stage "setup" "in_progress"

	# Stale target: only a copy that really happened can make it match.
	printf '%s\n' '{"state":"stale"}' > "$LOG_BASE/status.json"

	local orig_path="$PATH"
	_shadow_cp_failing_first 1
	run sync_status_to_log
	export PATH="$orig_path"

	[ "$status" -eq 0 ] \
		|| fail "sync_status_to_log returned $status after one transient cp failure"
	cmp -s "$STATUS_FILE" "$LOG_BASE/status.json" \
		|| fail "synced status.json is not byte-identical to STATUS_FILE after the retry"

	local calls
	calls=$(wc -l < "$TEST_TMP/cp-calls")
	[ "$calls" -eq 2 ] \
		|| fail "expected cp to be called twice (one failure, one success); got $calls"

	local tmp_count
	tmp_count=$(find "$LOG_BASE" -maxdepth 1 -name '.status.json.*' | wc -l)
	[ "$tmp_count" -eq 0 ] \
		|| fail "temp file(s) left behind after a retried sync: $tmp_count found"
	if grep -q 'WARN: sync_status_to_log' "$LOG_FILE"; then
		fail "a sync that succeeded on retry must not warn"
	fi
}

@test "sync_status_to_log emits one warning naming both paths when all cp retries fail" {
	init_status

	# A target left by an earlier sync must survive a failed one untouched.
	local earlier='{"state":"earlier-sync"}'
	printf '%s\n' "$earlier" > "$LOG_BASE/status.json"

	local orig_path="$PATH"
	_shadow_cp_failing_first 99
	run sync_status_to_log
	export PATH="$orig_path"

	[ "$status" -eq 0 ] \
		|| fail "sync_status_to_log must return 0 even when cp always fails; got $status"

	# The retry bound stated in sync_status_to_log is 3 attempts.
	local calls
	calls=$(wc -l < "$TEST_TMP/cp-calls")
	[ "$calls" -eq 3 ] \
		|| fail "expected exactly 3 cp attempts when every one fails; got $calls"

	# log_warn writes to LOG_FILE when LOG_FILE is set — verify exactly one
	# warning, naming both the source and the target path.
	local warnings
	warnings=$(grep -c 'WARN: sync_status_to_log' "$LOG_FILE" || true)
	[ "$warnings" -eq 1 ] \
		|| fail "expected exactly one sync warning in $LOG_FILE; got $warnings"
	grep 'WARN: sync_status_to_log' "$LOG_FILE" | grep -qF "$STATUS_FILE" \
		|| fail "warning did not name STATUS_FILE ($STATUS_FILE) in $LOG_FILE"
	grep 'WARN: sync_status_to_log' "$LOG_FILE" | grep -qF "$LOG_BASE/status.json" \
		|| fail "warning did not name target ($LOG_BASE/status.json) in $LOG_FILE"

	[ "$(cat "$LOG_BASE/status.json")" = "$earlier" ] \
		|| fail "existing target was modified by a sync whose every attempt failed"
	local tmp_count
	tmp_count=$(find "$LOG_BASE" -maxdepth 1 -name '.status.json.*' | wc -l)
	[ "$tmp_count" -eq 0 ] \
		|| fail "temp file(s) left behind after a failed sync: $tmp_count found"
}

@test "sync_status_to_log does not abort a set -e subshell when cp always fails" {
	init_status

	# A fresh bash, not a subshell of `run`: `run` calls its command where
	# errexit is ignored, which would make this pass whatever the function
	# returned.
	export -f sync_status_to_log log_warn

	local orig_path="$PATH"
	_shadow_cp_failing_first 99
	run bash -c 'set -e; sync_status_to_log; echo "after-sync"'
	export PATH="$orig_path"

	[ "$status" -eq 0 ] \
		|| fail "set -e subshell exited $status after a failed sync"
	[[ "$output" == *"after-sync"* ]] \
		|| fail "set -e subshell stopped at sync_status_to_log: $output"
}

# =============================================================================
# PR BODY FROM STATUS
# =============================================================================

@test "build_pr_body lists closing keyword and each task with status" {
    cat > "$STATUS_FILE" <<'JSON'
{"tasks":[{"id":"1","status":"completed","description":"Add flag"},
{"id":"2","status":"failed","description":"Wire it up; $(whoami) 'q'"}]}
JSON
    run build_pr_body
    [ "$status" -eq 0 ]
    [[ "$output" == "Closes #123"* ]]
    [[ "$output" == *"- Task 1 [completed] (size: ?, agent: ?): Add flag"* ]]
    [[ "$output" == *"- Task 2 [failed] (size: ?, agent: ?): Wire it up; \$(whoami) 'q'"* ]]
}

@test "build_pr_body falls back to closing keyword without tasks" {
    echo '{"tasks":[]}' > "$STATUS_FILE"
    run build_pr_body
    [ "$status" -eq 0 ]
    [[ "$output" == "Closes #123"* ]]
    [[ "$output" != *"## Tasks"* ]]
}

@test "write_pr_body_file writes body to file and prints its path" {
    echo '{"tasks":[{"id":"1","status":"completed","description":"Do x"}]}' \
        > "$STATUS_FILE"
    run write_pr_body_file
    [ "$status" -eq 0 ]
    [ "$output" = "$LOG_BASE/pr-body.md" ]
    grep -qF 'Closes #123' "$output"
    grep -qF -- '- Task 1 [completed] (size: ?, agent: ?): Do x' "$output"
}

@test "build_pr_body shows task size and agent, tests, and run-scope note" {
    cat > "$STATUS_FILE" <<'JSON'
{"test_iterations":3,"stages":{"test_loop":{"status":"completed"}},
"tasks":[{"id":"1","status":"completed","size":"M","agent":"bash-script-craftsman","description":"Do x"}]}
JSON
    DEGRADED_STAGES=()
    run build_pr_body
    [ "$status" -eq 0 ]
    [[ "$output" == *"(size: M, agent: bash-script-craftsman): Do x"* ]]
    [[ "$output" == *"## Tests"* ]]
    [[ "$output" == *"Test iterations: 3"* ]]
    [[ "$output" == *"test_loop=completed"* ]]
    [[ "$output" == *"up to PR creation"* ]]
    [[ "$output" != *"## Degraded stages"* ]]
}

@test "build_pr_body lists degraded stages when present" {
    echo '{"tasks":[]}' > "$STATUS_FILE"
    DEGRADED_STAGES=("quality:max_iterations:x:iter=2")
    run build_pr_body
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Degraded stages"* ]]
    [[ "$output" == *"- quality:max_iterations:x:iter=2"* ]]
}

@test "build_pr_body caps task rows and states the true total" {
    jq -n '{tasks:[range(1;46)|{id:(.|tostring),status:"completed",description:"t\(.)"}]}' \
        > "$STATUS_FILE"
    run build_pr_body
    [ "$status" -eq 0 ]
    [[ "$output" == *"- Task 30 ["* ]]
    [[ "$output" != *"- Task 31 ["* ]]
    [[ "$output" == *"Showing 30 of 45 tasks"* ]]
}

@test "write_pr_body_file fails when the body file cannot be written" {
    mkdir -p "$LOG_BASE/pr-body.md"
    run write_pr_body_file
    [ "$status" -ne 0 ]
}

@test "orchestrator PR prompt pins --body-file command and one-line fallback" {
    local src="${BATS_TEST_DIRNAME}/../implement-issue-orchestrator.sh"
    grep -qF -- "--body-file '\$pr_body_file'" "$src"
    grep -qF -- "--body 'Closes #\$ISSUE_NUMBER'" "$src"
    run bash -c 'source /dev/stdin <<<"$(sed -n "/^build_pr_body()/,/^}/p" "$1")"; STATUS_FILE=/nonexistent ISSUE_NUMBER=7 build_pr_body | head -1' _ "$src"
    [ "$output" = "Closes #7" ]
}

# Runs the orchestrator's real PR-stage prompt assembly (extracted from the
# orchestrator source) and prints the resulting pr_prompt.
_pr_stage_prompt() {
    local src="${BATS_TEST_DIRNAME}/../implement-issue-orchestrator.sh"
    local frag="$TEST_TMP/pr-stage-fragment.bash"
    {
        printf 'build_pr_stage_prompt() {\n'
        printf '    local branch=feat/x pr_creation_skill=""\n'
        printf '    local PLATFORM_DIR=/plat\n'
        sed -n '/^        local pr_body_file$/,/^\$pr_creation_skill}"$/p' "$src"
        printf '\n    printf "%%s" "$pr_prompt"\n}\n'
    } > "$frag"
    source "$frag"
    build_pr_stage_prompt
}

@test "PR stage prompt carries the body file path when the write succeeds" {
    echo '{"tasks":[{"id":"1","status":"completed","description":"Do x"}]}' \
        > "$STATUS_FILE"
    run _pr_stage_prompt
    [ "$status" -eq 0 ]
    [[ "$output" == *"--body-file '$LOG_BASE/pr-body.md'"* ]]
    [[ "$output" != *"--body 'Closes"* ]]
    grep -qF 'Closes #123' "$LOG_BASE/pr-body.md"
}

@test "PR stage prompt falls back to the one-line body when the write fails" {
    echo '{"tasks":[]}' > "$STATUS_FILE"
    mkdir -p "$LOG_BASE/pr-body.md"
    run _pr_stage_prompt
    [ "$status" -eq 0 ]
    [[ "$output" == *"--body 'Closes #123'"* ]]
    [[ "$output" != *"--body-file"* ]]
}
