#!/usr/bin/env bash
#
# batch-orchestrator.sh
# Orchestrates batch processing of GitHub issues using Claude Agent SDK
#
# Usage:
#   ./batch-orchestrator.sh --manifest <path>
#   ./batch-orchestrator.sh --issues "123,124,125" --branch "test"
#   ./batch-orchestrator.sh --manifest <path> --agent react-frontend-developer
#
# Agent Selection:
#   --agent <name>  Specify agent for implement-issue (e.g., react-frontend-developer,
#                   fastify-backend-developer). Process-pr always uses code-reviewer.
#
# Outputs:
#   - status.json: Real-time progress (read by handle-issues skill)
#   - logs/batch-<timestamp>/: Per-issue logs and final summary
#
# Exit codes:
#   0  - All issues processed successfully
#   1  - Some issues failed (check status.json)
#   2  - Circuit breaker triggered
#   3  - Configuration/argument error
#

set -uo pipefail  # Note: not -e, we handle errors explicitly

# =============================================================================
# PORTABLE TIMEOUT (macOS does not ship GNU timeout)
# =============================================================================

if ! command -v timeout &>/dev/null; then
    timeout() {
        local duration="$1"; shift
        perl -e '
            use POSIX ":sys_wait_h";
            alarm shift @ARGV;
            $SIG{ALRM} = sub { kill 15, $pid; waitpid($pid, 0); exit 124 };
            $pid = fork // die "fork: $!";
            if ($pid == 0) { exec @ARGV; die "exec: $!" }
            waitpid($pid, 0);
            exit ($? >> 8);
        ' "$duration" "$@"
    }
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$SCRIPT_DIR/schemas"
source "$SCRIPT_DIR/../config/platform.sh"
# claude-usage.sh provides is_model_exhausted / model_reset_at for the
# pre-flight log line. Sourcing is no-op when CLAUDE_USAGE_SESSION_KEY is
# unset (graceful fallback — see claude-usage.sh).
source "$SCRIPT_DIR/claude-usage.sh"
PLATFORM_DIR="$SCRIPT_DIR/platform"
LOG_BASE="logs/batch-$(date +%Y%m%d-%H%M%S)"
STATUS_FILE="status.json"
LOCK_FILE="logs/.batch-orchestrator.lock"

# Timeouts and limits
readonly ISSUE_TIMEOUT=10800  # 180 minutes per issue
readonly MAX_CONSECUTIVE_FAILURES=3
readonly RATE_LIMIT_BUFFER=60  # Extra seconds to wait after rate limit reset
readonly RATE_LIMIT_DEFAULT_WAIT=3600  # Default 1 hour if we can't determine wait time

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

MANIFEST=""
ISSUES=""
BRANCH=""
AGENT=""

usage() {
    echo "Usage: $0 --manifest <path>"
    echo "       $0 --issues \"123,124,125\" --branch \"test\""
    echo "       $0 --manifest <path> --agent react-frontend-developer"
    echo ""
    echo "Options:"
    echo "  --manifest <path>   Path to manifest.json with issues and branch"
    echo "  --issues <list>     Comma-separated list of issue numbers"
    echo "  --branch <name>     Base branch for PRs"
    echo "  --agent <name>      Agent for implement-issue stage (optional)"
    echo ""
    echo "Available agents:"
    echo "  react-frontend-developer        React, Next.js, shadcn/ui, Tailwind"
    echo "  fastify-backend-developer        TypeScript, Fastify, routes, services"
    echo "  (none specified)                Default claude behavior"
    echo ""
    echo "Note: process-pr stage always uses code-reviewer agent"
    exit 3
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest)
            [[ -n "${2:-}" ]] || { echo "ERROR: --manifest requires a value" >&2; exit 3; }
            MANIFEST="$2"
            shift 2
            ;;
        --issues)
            [[ -n "${2:-}" ]] || { echo "ERROR: --issues requires a value" >&2; exit 3; }
            ISSUES="$2"
            shift 2
            ;;
        --branch)
            [[ -n "${2:-}" ]] || { echo "ERROR: --branch requires a value" >&2; exit 3; }
            BRANCH="$2"
            shift 2
            ;;
        --agent)
            [[ -n "${2:-}" ]] || { echo "ERROR: --agent requires a value" >&2; exit 3; }
            AGENT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Load from manifest if provided
if [[ -n "$MANIFEST" ]]; then
    if [[ ! -f "$MANIFEST" ]]; then
        echo "ERROR: Manifest file not found: $MANIFEST"
        exit 3
    fi
    ISSUES=$(jq -r '.issues | join(",")' "$MANIFEST")
    BRANCH=$(jq -r '.base_branch' "$MANIFEST")
    # Load agent from manifest if not specified on command line
    if [[ -z "$AGENT" ]]; then
        AGENT=$(jq -r '.agent // empty' "$MANIFEST")
    fi
fi

if [[ -z "$ISSUES" || -z "$BRANCH" ]]; then
    echo "ERROR: Must provide --manifest or both --issues and --branch"
    usage
fi

# Convert comma-separated to array
IFS=',' read -ra ISSUE_ARRAY <<< "$ISSUES"

# Load schemas as single-line JSON for CLI
# Note: implement-issue now uses its own orchestrator script with separate schemas
if [[ ! -f "$SCHEMA_DIR/process-pr.json" ]]; then
    echo "ERROR: Schema not found: $SCHEMA_DIR/process-pr.json"
    exit 3
fi

PROCESS_SCHEMA=$(jq -c . "$SCHEMA_DIR/process-pr.json")

# =============================================================================
# LOCKING
# =============================================================================

acquire_lock() {
    mkdir -p "$(dirname "$LOCK_FILE")"

    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            echo "ERROR: Another batch is running (PID: $lock_pid)"
            echo "Lock file: $LOCK_FILE"
            echo "If stale, remove manually: rm $LOCK_FILE"
            exit 3
        fi
        echo "Removing stale lock file (PID $lock_pid not running)"
        rm -f "$LOCK_FILE"
    fi

    echo $$ > "$LOCK_FILE"
}

release_lock() {
    if [[ -f "$LOCK_FILE" ]] && [[ "$(cat "$LOCK_FILE" 2>/dev/null)" == "$$" ]]; then
        rm -f "$LOCK_FILE"
    fi
}

trap release_lock EXIT
acquire_lock

# =============================================================================
# LOGGING
# =============================================================================

mkdir -p "$LOG_BASE"
LOG_FILE="$LOG_BASE/orchestrator.log"

log() {
    local msg="[$(date -Iseconds)] $*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    printf '%s\n' "$msg" >&2
}

log_error() {
    local msg="[$(date -Iseconds)] ERROR: $*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    printf '%s\n' "$msg" >&2
}

log_warn() {
    local msg="[$(date -Iseconds)] WARN: $*"
    printf '%s\n' "$msg" >> "$LOG_FILE"
    printf '%s\n' "$msg" >&2
}

# =============================================================================
# STRUCTURED EVENT EMISSION
# =============================================================================
#
# emit_event <event_type> [key=value ...]
#
# Builds a JSON envelope with ts/run_id/event/stage and forwards it to
# event-emit.sh, which validates against schemas/pipeline-event.json and
# appends one JSONL line to $LOG_BASE/events.jsonl under flock.
#
# Design notes:
#   - Parallel to existing text logs: every text-log call site that maps to one
#     of the 8 event types (stage_start, stage_end, escalation, retry,
#     model_call, rate_limit_hit, schema_validation_fail, status_change) gets
#     a parallel emit_event call.  Text logs are retained verbatim for human
#     debugging — see issue #180.
#   - Safe-by-default: silently no-ops when event-emit.sh is missing or
#     LOG_BASE is unset (e.g. during early init or when the helper has not yet
#     landed in this branch).  A schema-invalid emit exits non-zero from
#     event-emit.sh but never crashes the orchestrator (stderr-redirected,
#     `|| true`).
#   - run_id is derived from the LOG_BASE basename which already encodes
#     issue+timestamp (e.g. "issue-180-20260502-183541").
emit_event() {
    local event_type="$1"
    shift

    # Parallel-task safety: if the helper hasn't been added yet (sub-issue
    # tasks land out of order), skip silently rather than break the pipeline.
    local emit_script="$SCRIPT_DIR/event-emit.sh"
    if [[ ! -x "$emit_script" ]]; then
        return 0
    fi

    # Skip if LOG_BASE isn't established yet (very early init paths).
    if [[ -z "${LOG_BASE:-}" ]]; then
        return 0
    fi

    local run_id="${LOG_BASE##*/}"

    local -a jq_args=(
        --arg ts "$(date -Iseconds)"
        --arg run_id "$run_id"
        --arg event "$event_type"
    )
    local filter='{ts: $ts, run_id: $run_id, event: $event}'

    local kv key value safe_key json_value
    for kv in "$@"; do
        # Support `key:=value` for JSON-typed values (numbers, booleans, null)
        # in addition to `key=value` for strings. Required because the schema
        # types fields like attempt/max_attempts/stage_attempt as integer.
        if [[ "$kv" == *":="* ]]; then
            key="${kv%%:=*}"
            value="${kv#*:=}"
            json_value=true
        else
            key="${kv%%=*}"
            value="${kv#*=}"
            json_value=false
        fi
        # Defensive: only allow alphanumeric/underscore in keys to keep the
        # generated jq filter safe.
        safe_key="${key//[^A-Za-z0-9_]/}"
        if [[ -z "$safe_key" ]]; then
            continue
        fi
        if $json_value; then
            jq_args+=(--argjson "$safe_key" "$value")
        else
            jq_args+=(--arg "$safe_key" "$value")
        fi
        filter+=" | .${safe_key} = \$${safe_key}"
    done

    local event_json
    event_json=$(jq -nc "${jq_args[@]}" "$filter" 2>/dev/null) || return 0

    LOG_DIR="$LOG_BASE" "$emit_script" "$event_json" >/dev/null 2>&1 || true
}

# =============================================================================
# STATUS FILE MANAGEMENT
# =============================================================================

init_status() {
    local issues_json="[]"
    for issue in "${ISSUE_ARRAY[@]}"; do
        issues_json=$(printf '%s' "$issues_json" | jq --arg num "$issue" '. + [{
            "number": $num,
            "status": "pending",
            "stage": null,
            "pr": null,
            "session_id": null,
            "error": null,
            "follow_ups": [],
            "started_at": null,
            "stage_started_at": null,
            "completed_at": null
        }]')
    done

    jq -n \
        --arg state "running" \
        --arg branch "$BRANCH" \
        --argjson total "${#ISSUE_ARRAY[@]}" \
        --argjson issues "$issues_json" \
        --arg log_dir "$LOG_BASE" \
        '{
            state: $state,
            base_branch: $branch,
            current_issue: null,
            progress: {
                total: $total,
                completed: 0,
                failed: 0,
                pending: $total,
                in_progress: 0
            },
            issues: $issues,
            rate_limit: {
                waiting: false,
                resume_at: null,
                session_id: null
            },
            last_update: (now | todate),
            log_dir: $log_dir
        }' > "$STATUS_FILE"

    log "Initialized status file: $STATUS_FILE"
}

update_issue_field() {
    local issue_num="$1"
    local field="$2"
    local value="$3"
    local is_json="${4:-false}"

    if [[ "$is_json" == "true" ]]; then
        jq --arg num "$issue_num" \
           --arg field "$field" \
           --argjson val "$value" \
           '(.issues[] | select(.number == $num))[$field] = $val |
            .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    else
        jq --arg num "$issue_num" \
           --arg field "$field" \
           --arg val "$value" \
           '(.issues[] | select(.number == $num))[$field] = $val |
            .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    fi
}

update_progress() {
    jq '.progress.completed = ([.issues[] | select(.status == "completed" or .status == "already_done")] | length) |
        .progress.failed = ([.issues[] | select(.status == "failed" or .status == "skipped")] | length) |
        .progress.in_progress = ([.issues[] | select(.status == "in_progress")] | length) |
        .progress.pending = ([.issues[] | select(.status == "pending")] | length) |
        .last_update = (now | todate)' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

set_current_issue() {
    local issue_num="$1"
    jq --arg num "$issue_num" '.current_issue = $num | .last_update = (now | todate)' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

set_rate_limit() {
    local waiting="$1"
    local resume_at="${2:-null}"
    local session_id="${3:-null}"

    if [[ "$resume_at" == "null" || -z "$resume_at" ]]; then
        resume_at="null"
    else
        resume_at="\"$resume_at\""
    fi

    if [[ "$session_id" == "null" || -z "$session_id" ]]; then
        session_id="null"
    else
        session_id="\"$session_id\""
    fi

    jq --argjson waiting "$waiting" \
       --argjson resume "$resume_at" \
       --argjson session "$session_id" \
       '.rate_limit = {waiting: $waiting, resume_at: $resume, session_id: $session} |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

set_state() {
    local state="$1"
    jq --arg state "$state" '.state = $state | .last_update = (now | todate)' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# =============================================================================
# RATE LIMIT DETECTION
# =============================================================================

detect_rate_limit() {
    local output="$1"
    local exit_code="${2:-0}"

    # Check structured output first (most reliable)
    local status
    status=$(printf '%s' "$output" | jq -r '.structured_output.status // empty' 2>/dev/null)

    # If structured output shows success, definitively NOT rate limited
    if [[ "$status" == "success" || "$status" == "merged" || "$status" == "changes_requested" ]]; then
        return 1
    fi

    # If structured output explicitly says rate_limit
    if [[ "$status" == "rate_limit" ]]; then
        return 0
    fi

    # Only check text patterns if structured output is empty/error (fallback detection)
    # Check result text for rate limit indicators
    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)
    if echo "$result" | grep -qiE 'rate.limit|429|too many requests|quota.exceeded|secondary rate'; then
        return 0
    fi

    # Check raw output only if JSON parsing failed (no valid structured_output)
    # Use word boundaries to avoid matching field names like "rate_limit" in JSON
    if [[ -z "$status" ]]; then
        if echo "$output" | grep -qiE '\brate limit\b|HTTP 429|\btoo many requests\b|quota exceeded'; then
            return 0
        fi
    fi

    return 1
}

extract_wait_time() {
    local output="$1"
    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)

    # Combine result and raw output for searching
    local search_text="$result $output"

    # Try to find retry-after seconds
    local retry_after
    retry_after=$(echo "$search_text" | grep -oiE 'retry.after[^0-9]*([0-9]+)' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$retry_after" ]] && (( retry_after > 0 )); then
        echo "$retry_after"
        return
    fi

    # Try to find "wait X minutes/hours"
    local wait_mins
    wait_mins=$(echo "$search_text" | grep -oiE 'wait[^0-9]*([0-9]+)[^0-9]*min' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$wait_mins" ]] && (( wait_mins > 0 )); then
        echo $((wait_mins * 60))
        return
    fi

    local wait_hours
    wait_hours=$(echo "$search_text" | grep -oiE 'wait[^0-9]*([0-9]+)[^0-9]*hour' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$wait_hours" ]] && (( wait_hours > 0 )); then
        echo $((wait_hours * 3600))
        return
    fi

    # Default to configured wait time
    echo "$RATE_LIMIT_DEFAULT_WAIT"
}

# =============================================================================
# COMPOSITION ROUTING
# =============================================================================
#
# dispatch_composition routes a skill invocation to the Skill-tool path
# (non-isolated, decision/review skills) or the subprocess path (worktree-
# isolated implementation skills).
#
# Usage:
#   dispatch_composition "<prompt>" [isolated] [extra claude args...]
#
# Arguments:
#   prompt   — slash-command prompt (e.g. "/process-pr 1 2 main")
#   isolated — "true" for subprocess path, "false"/omitted for skill path
#   ...      — additional flags forwarded to the claude invocation
#
# Kill-switch: COMPOSITION_BACKEND env var overrides auto-routing.
#   subprocess — always use subprocess path
#   skill      — always use skill path
#   (unset)    — auto-route based on the isolated argument

dispatch_composition() {
	local prompt="$1"
	local isolated="${2:-false}"
	local -a extra_args=()
	if (( $# > 2 )); then
		shift 2
		extra_args=("$@")
	fi

	local backend
	if [[ -n "${COMPOSITION_BACKEND:-}" ]]; then
		case "$COMPOSITION_BACKEND" in
			subprocess|skill)
				backend="$COMPOSITION_BACKEND"
				;;
			*)
				printf 'ERROR: unknown COMPOSITION_BACKEND value: %s\n' \
					"$COMPOSITION_BACKEND" >&2
				return 1
				;;
		esac
	elif [[ "$isolated" == "true" ]]; then
		backend="subprocess"
	else
		backend="skill"
	fi

	case "$backend" in
		subprocess)
			run_composition_subprocess "$prompt" "${extra_args[@]+"${extra_args[@]}"}"
			;;
		skill)
			run_composition_skill "$prompt" "${extra_args[@]+"${extra_args[@]}"}"
			;;
	esac
}

# run_composition_subprocess — invoke a skill as a worktree-isolated subprocess.
# Used for skills that require git worktree isolation (e.g. implement-issue).
run_composition_subprocess() {
	local prompt="$1"
	shift
	log "Composition dispatch → subprocess: $prompt"
	timeout "$ISSUE_TIMEOUT" env -u CLAUDECODE claude -p "$prompt" \
		--dangerously-skip-permissions \
		--output-format json \
		"$@" \
		2>&1
}

# run_composition_skill — invoke a skill via the Skill-tool path.
# Used for skills that orchestrate decisions without worktree isolation
# (e.g. process-pr, plan, review).
#
# Unlike run_composition_subprocess, this path does NOT set
# --dangerously-skip-permissions, so the sub-Claude session can use
# interactive tools (including the Skill tool itself) and AskUserQuestion.
# Output format is not forced here — callers that need structured JSON must
# pass --output-format json (and --json-schema) explicitly.
run_composition_skill() {
	local prompt="$1"
	shift
	log "Composition dispatch → skill: $prompt"
	timeout "$ISSUE_TIMEOUT" env -u CLAUDECODE claude -p "$prompt" \
		"$@" \
		2>&1
}

# =============================================================================
# ISSUE PROCESSING
# =============================================================================

process_issue() {
    local issue_num="$1"
    local issue_log="$LOG_BASE/issue-$issue_num.log"

    log "=========================================="
    log "Starting issue #$issue_num"
    log "=========================================="
    emit_event "issue_start" "issue_num=$issue_num"

    set_current_issue "$issue_num"
    update_issue_field "$issue_num" "status" "in_progress"
    update_issue_field "$issue_num" "started_at" "$(date -Iseconds)"
    update_issue_field "$issue_num" "stage" "implement-issue"
    update_issue_field "$issue_num" "stage_started_at" "$(date -Iseconds)"
    update_progress

    # Set up feature branch for this issue
    local feature_branch="feature/issue-$issue_num"
    log "Setting up feature branch: $feature_branch"
    git checkout "$BRANCH" 2>/dev/null
    git pull --ff-only 2>/dev/null || true
    if git show-ref --verify --quiet "refs/heads/$feature_branch" 2>/dev/null; then
        git checkout "$feature_branch" 2>/dev/null
    else
        git checkout -b "$feature_branch" "$BRANCH" 2>/dev/null
    fi

    # -------------------------------------------------------------------------
    # IMPLEMENT-ISSUE (via orchestrator script)
    # -------------------------------------------------------------------------
    local issue_status_file="$LOG_BASE/issue-$issue_num-status.json"

    local -a agent_args=()
    if [[ -n "$AGENT" ]]; then
        agent_args=(--agent "$AGENT")
    fi

    log "Running: implement-issue-orchestrator.sh --issue $issue_num --branch $BRANCH ${agent_args[@]+"${agent_args[@]}"}"

    local impl_exit=0

    printf '%s\n' "=== implement-issue output ===" >> "$issue_log"
    "$SCRIPT_DIR/implement-issue-orchestrator.sh" \
        --issue "$issue_num" \
        --branch "$BRANCH" \
        ${agent_args[@]+"${agent_args[@]}"} \
        --status-file "$issue_status_file" \
        2>&1 | tee -a "$issue_log"
    impl_exit=${PIPESTATUS[0]}
    printf '%s\n' "=== exit code: $impl_exit ===" >> "$issue_log"

    # Parse result from status file
    local impl_status="error"
    local pr_number=""
    local impl_error=""

    if [[ -f "$issue_status_file" ]]; then
        local state
        state=$(jq -r '.state' "$issue_status_file")

        # Map script states to expected values
        case "$state" in
            completed)
                impl_status="success"
                # Extract PR number from stages.pr or from the status file
                pr_number=$(jq -r '.stages.pr.pr_number // empty' "$issue_status_file" 2>/dev/null)
                ;;
            already_implemented)
                impl_status="already_implemented"
                ;;
            error|max_iterations_quality|max_iterations_pr_review)
                impl_status="error"
                impl_error="Script exited with state: $state"
                ;;
            *)
                impl_status="error"
                impl_error="Unknown state: $state"
                ;;
        esac

        # Recovery: if the orchestrator exited with a non-completed state but
        # stages.pr.pr_number was already written (PR created before crash),
        # treat it as recoverable success. Handles the case where the script is
        # killed or crashes after PR creation but before set_final_state("completed").
        if [[ "$impl_status" == "error" ]]; then
            local recovered_pr
            recovered_pr=$(jq -r '.stages.pr.pr_number // empty' "$issue_status_file" 2>/dev/null)
            if [[ -n "$recovered_pr" && "$recovered_pr" =~ ^[0-9]+$ ]]; then
                log_warn "Orchestrator exited with state='$state' but PR #$recovered_pr exists — recovering as success"
                impl_status="success"
                pr_number="$recovered_pr"
                impl_error=""
            fi
        fi
    else
        impl_error="Status file not created"
    fi

    log "implement-issue status: $impl_status, PR: ${pr_number:-none}"

    # Log location of metrics.json emitted by the orchestrator's EXIT trap
    if [[ -f "$issue_status_file" ]]; then
        local issue_log_dir
        issue_log_dir=$(jq -r '.log_dir // empty' "$issue_status_file" 2>/dev/null)
        if [[ -n "$issue_log_dir" && -f "$issue_log_dir/metrics.json" ]]; then
            log "Metrics available: $issue_log_dir/metrics.json"
        fi
    fi

    if [[ "$impl_status" == "already_implemented" ]]; then
        log "Issue #$issue_num was already implemented in a prior run — skipping PR creation."
        update_issue_field "$issue_num" "status" "already_done"
        update_progress
        git checkout "$BRANCH" 2>/dev/null || true
        return 0
    fi

    if [[ "$impl_status" != "success" ]]; then
        log_error "implement-issue failed for #$issue_num: ${impl_error:-unknown error}"
        update_issue_field "$issue_num" "status" "failed"
        update_issue_field "$issue_num" "error" "${impl_error:-implement-issue failed with status: $impl_status}"
        update_progress
        git checkout "$BRANCH" 2>/dev/null || true
        return 1
    fi

    if [[ -z "$pr_number" ]]; then
        log_error "implement-issue succeeded but no PR number found for #$issue_num"
        update_issue_field "$issue_num" "status" "failed"
        update_issue_field "$issue_num" "error" "No PR number in status file or output"
        update_progress
        git checkout "$BRANCH" 2>/dev/null || true
        return 1
    fi
    log "implement-issue complete. PR #$pr_number created"
    update_issue_field "$issue_num" "pr" "$pr_number" "true"
    update_issue_field "$issue_num" "stage" "process-pr"

    # -------------------------------------------------------------------------
    # PROCESS-PR (always uses code-reviewer agent)
    # -------------------------------------------------------------------------
    log "Running: claude -p \"/process-pr $pr_number $issue_num $BRANCH\" --agent code-reviewer --json-schema ..."

    local proc_exit=0

    printf '%s\n' "=== process-pr output ===" >> "$issue_log"
    dispatch_composition "/process-pr $pr_number $issue_num $BRANCH" "false" \
        --agent code-reviewer \
        --output-format json \
        --json-schema "$PROCESS_SCHEMA" \
        | tee -a "$issue_log"
    proc_exit=${PIPESTATUS[0]}
    printf '%s\n' "=== exit code: $proc_exit ===" >> "$issue_log"

    # Update session ID from last JSON line in log
    local session_id
    session_id=$(grep -E '^\{' "$issue_log" | tail -1 | jq -r '.session_id // empty' 2>/dev/null)
    if [[ -n "$session_id" ]]; then
        update_issue_field "$issue_num" "session_id" "$session_id"
    fi

    # Check for rate limit
    local proc_last_json
    proc_last_json=$(grep -E '^\{' "$issue_log" | tail -1)
    if detect_rate_limit "$proc_last_json" "$proc_exit"; then
        local wait_time
        wait_time=$(extract_wait_time "$proc_last_json")
        wait_time=$((wait_time + RATE_LIMIT_BUFFER))
        local resume_at
        resume_at=$(date -Iseconds -d "+${wait_time} seconds" 2>/dev/null || date -v+${wait_time}S -Iseconds 2>/dev/null)

        log "Rate limit hit during process-pr. Waiting ${wait_time}s"
        emit_event "rate_limit_hit" "stage=process-pr" "retry_after_seconds:=$wait_time"
        set_rate_limit "true" "$resume_at" "$session_id"

        sleep "$wait_time"

        set_rate_limit "false" "" ""

        # Resume — retry-with-backoff: parent already slept for the rate-limit
        # window; restart fresh rather than resuming with "please continue"
        # (the --resume subprocess is replaced by a clean retry here).
        printf '%s\n' "=== process-pr resume output ===" >> "$issue_log"
        dispatch_composition "/process-pr $pr_number $issue_num $BRANCH" "false" \
            --agent code-reviewer \
            --output-format json \
            --json-schema "$PROCESS_SCHEMA" \
            | tee -a "$issue_log"
        proc_exit=${PIPESTATUS[0]}
        proc_last_json=$(grep -E '^\{' "$issue_log" | tail -1)
    fi

    # Check for timeout
    if (( proc_exit == 124 )); then
        log_error "Issue #$issue_num timed out during process-pr (${ISSUE_TIMEOUT}s)"
        update_issue_field "$issue_num" "status" "failed"
        update_issue_field "$issue_num" "error" "Timeout after ${ISSUE_TIMEOUT}s during process-pr"
        update_progress
        git checkout "$BRANCH" 2>/dev/null || true
        return 1
    fi

    # Parse structured output
    local proc_status
    local follow_ups
    local proc_error

    proc_status=$(printf '%s' "$proc_last_json" | jq -r '.structured_output.status // "error"' 2>/dev/null)
    follow_ups=$(printf '%s' "$proc_last_json" | jq -c '.structured_output.follow_up_issues // []' 2>/dev/null)
    proc_error=$(printf '%s' "$proc_last_json" | jq -r '.structured_output.error // empty' 2>/dev/null)

    log "process-pr status: $proc_status"

    case "$proc_status" in
        merged)
            log "Issue #$issue_num completed. PR #$pr_number merged."
            update_issue_field "$issue_num" "status" "completed"
            update_issue_field "$issue_num" "completed_at" "$(date -Iseconds)"
            update_issue_field "$issue_num" "follow_ups" "$follow_ups" "true"
            # Push feature branch and return to base
            git push -u origin "$feature_branch" 2>/dev/null || true
            git checkout "$BRANCH" 2>/dev/null || true
            ;;
        changes_requested)
            # process-pr handles re-implementation internally by calling implement-issue again
            # If we get here with changes_requested, it means the re-implementation cycle completed
            log "Issue #$issue_num: changes were requested and addressed"
            update_issue_field "$issue_num" "status" "completed"
            update_issue_field "$issue_num" "completed_at" "$(date -Iseconds)"
            ;;
        error|rate_limit|*)
            log_error "process-pr failed for #$issue_num: ${proc_error:-status was $proc_status}"
            update_issue_field "$issue_num" "status" "failed"
            update_issue_field "$issue_num" "error" "${proc_error:-process-pr failed with status: $proc_status}"
            update_progress
            git checkout "$BRANCH" 2>/dev/null || true
            return 1
            ;;
    esac

    update_progress
    return 0
}

# =============================================================================
# MAIN LOOP
# =============================================================================

log "=========================================="
log "Batch Orchestrator Starting"
log "=========================================="
log "Issues: ${ISSUE_ARRAY[*]}"
log "Branch: $BRANCH"
log "Implement agent: ${AGENT:-default}"
log "Process-PR agent: code-reviewer"
log "Log dir: $LOG_BASE"
log "Timeout per issue: ${ISSUE_TIMEOUT}s"
log "Max consecutive failures: $MAX_CONSECUTIVE_FAILURES"
emit_event "batch_start" "total_issues:=${#ISSUE_ARRAY[@]}" "branch=$BRANCH"

init_status

# Pre-flight usage check. When the user has configured CLAUDE_USAGE_SESSION_KEY,
# log current per-model utilization + reset times so operators can see at a
# glance whether the batch will hit a wall. Per-stage escalation in the
# subprocess (implement-issue-orchestrator.sh) handles actual routing — this
# is an observability gate, not a control point.
if [[ -n "${CLAUDE_USAGE_SESSION_KEY:-}${CLAUDE_USAGE_SESSION_KEY_FILE:-}" ]] \
        && declare -F is_model_exhausted >/dev/null 2>&1; then
    for _m in sonnet opus; do
        _pct=$(usage_for_model "$_m" 2>/dev/null || echo "0")
        _reset=$(model_reset_at "$_m" 2>/dev/null || echo "unknown")
        if is_model_exhausted "$_m" 2>/dev/null; then
            log "Pre-flight: $_m exhausted (utilization ${_pct}%, resets $_reset) — subprocess will escalate"
        else
            log "Pre-flight: $_m available (utilization ${_pct}%, resets $_reset)"
        fi
    done
fi

consecutive_failures=0
exit_code=0

for issue in "${ISSUE_ARRAY[@]}"; do
    # Check idempotency - skip if already completed in a previous run
    current_status=$(jq -r --arg num "$issue" '.issues[] | select(.number == $num) | .status' "$STATUS_FILE")

    if [[ "$current_status" == "completed" ]]; then
        log "Skipping issue #$issue (already completed)"
        continue
    fi

    if process_issue "$issue"; then
        consecutive_failures=0
        log "Issue #$issue processed successfully"
        emit_event "issue_end" "issue_num=$issue" "outcome=success"
    else
        consecutive_failures=$((consecutive_failures + 1))
        exit_code=1
        log "Issue #$issue failed. Consecutive failures: $consecutive_failures / $MAX_CONSECUTIVE_FAILURES"
        emit_event "issue_end" "issue_num=$issue" "outcome=failed"

        if (( consecutive_failures >= MAX_CONSECUTIVE_FAILURES )); then
            log_error "CIRCUIT BREAKER: $MAX_CONSECUTIVE_FAILURES consecutive failures. Stopping batch."
            set_state "circuit_breaker"
            emit_event "batch_paused" "consecutive_failures:=$consecutive_failures" "max_failures:=$MAX_CONSECUTIVE_FAILURES"
            exit_code=2
            break
        fi
    fi
done

# Final state
final_failed=$(jq '.progress.failed' "$STATUS_FILE")
if (( exit_code == 2 )); then
    # Circuit breaker already set state
    :
elif (( final_failed > 0 )); then
    set_state "completed_with_errors"
else
    set_state "completed"
fi

log "=========================================="
log "Batch Complete"
log "=========================================="
log "Final state: $(jq -r '.state' "$STATUS_FILE")"
log "Progress: $(jq -c '.progress' "$STATUS_FILE")"
_batch_outcome=$(jq -r '.state' "$STATUS_FILE" 2>/dev/null)
[[ -z "$_batch_outcome" || "$_batch_outcome" == "null" ]] && _batch_outcome="failed"
emit_event "batch_end" "outcome=$_batch_outcome"

# Write summary
jq '{
    state: .state,
    base_branch: .base_branch,
    progress: .progress,
    issues: [.issues[] | {number, status, pr, follow_ups, error}],
    log_dir: .log_dir,
    completed_at: (now | todate)
}' "$STATUS_FILE" > "$LOG_BASE/summary.json"

log "Summary written to $LOG_BASE/summary.json"

exit $exit_code
