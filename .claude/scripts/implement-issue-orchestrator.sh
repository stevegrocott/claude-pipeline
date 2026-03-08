#!/usr/bin/env bash
#
# implement-issue-orchestrator.sh
# Orchestrates implement-issue workflow via Claude CLI calls per stage
#
# Usage:
#   ./implement-issue-orchestrator.sh --issue 123 --branch test
#   ./implement-issue-orchestrator.sh --issue 123 --branch test --agent precis-backend-developer
#
# Outputs:
#   - status.json: Real-time progress
#   - logs/implement-issue/<timestamp>/: Per-stage logs
#

set -uo pipefail  # Note: not -e, we handle errors explicitly

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$SCRIPT_DIR/schemas"
source "$SCRIPT_DIR/model-config.sh"
source "$SCRIPT_DIR/../config/platform.sh"
PLATFORM_DIR="$SCRIPT_DIR/platform"

# Timeouts and limits
readonly MAX_QUALITY_ITERATIONS=5
readonly MAX_TEST_ITERATIONS=7
# Cap at 2: merged spec+code review per iteration makes each pass thorough
# enough that a 3rd iteration rarely finds new issues, while saving ~15 min.
readonly MAX_PR_REVIEW_ITERATIONS=2
readonly MAX_VALIDATION_FIX_ITERATIONS=2
readonly RATE_LIMIT_BUFFER=60
readonly RATE_LIMIT_DEFAULT_WAIT=3600

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
# STAGE-TYPE-BASED TIMEOUTS
# =============================================================================
#
# Replaces the flat STAGE_TIMEOUT constant with per-stage timeouts.
# Compound prefixes (test-iter, pr-review) are matched first to avoid
# being swallowed by their shorter generic siblings (test, pr).
#

get_stage_timeout() {
    local stage_name="${1:-}"

    case "$stage_name" in
        test-iter*)     printf '%s' 900 ;;
        pr-review*)     printf '%s' 1800 ;;
        deploy-verify*) printf '%s' 900 ;;
        e2e-verify*)    printf '%s' 600 ;;
        fix-e2e*)       printf '%s' 900 ;;
        test*|docs*|pr*) printf '%s' 600 ;;
        task-review*)    printf '%s' 900 ;;
        implement*|fix*) printf '%s' 1800 ;;
        *)               printf '%s' 1800 ;;
    esac
}

# =============================================================================
# BRANCH VERIFICATION
# =============================================================================
#
# Guards fix stages against committing on the wrong branch.  Called before
# each fix-* stage invocation so that a stale checkout or unexpected HEAD
# is caught early rather than silently committing to the wrong ref.
#

verify_on_feature_branch() {
    local expected="${1:-}"

    if [[ -z "$expected" ]]; then
        log_error "verify_on_feature_branch: no expected branch provided"
        return 1
    fi

    local actual
    actual=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)

    if [[ "$actual" != "$expected" ]]; then
        log_error "Expected branch '$expected' but HEAD is on '$actual'"
        return 1
    fi

    return 0
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

ISSUE_NUMBER=""
BASE_BRANCH=""
AGENT=""
STATUS_FILE="status.json"
RESUME_MODE=""
RESUME_LOG_DIR=""
QUIET=false

usage() {
    cat <<EOF
Usage: $0 --issue <number> --branch <name> [options]
       $0 --resume [--status-file <path>]
       $0 --resume-from <log-dir>

Options:
  --issue <number>       Issue number or key (required for new runs)
  --branch <name>        Base branch for PR (required for new runs)
  --agent <name>         Default agent for setup stage (optional)
  --status-file <path>   Custom status file path (optional)
  --quiet                Suppress all issue comments (no tracker noise)
  --resume               Resume from existing status.json
  --resume-from <dir>    Resume from specific log directory

Resume modes:
  --resume uses the current status.json (or --status-file path)
  --resume-from reads status.json from the specified log directory

Agents are determined per-task from setup output.
EOF
    exit 3
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            [[ -n "${2:-}" ]] || { echo "ERROR: --issue requires a value" >&2; exit 3; }
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        --branch)
            [[ -n "${2:-}" ]] || { echo "ERROR: --branch requires a value" >&2; exit 3; }
            BASE_BRANCH="$2"
            shift 2
            ;;
        --agent)
            [[ -n "${2:-}" ]] || { echo "ERROR: --agent requires a value" >&2; exit 3; }
            AGENT="$2"
            shift 2
            ;;
        --status-file)
            [[ -n "${2:-}" ]] || { echo "ERROR: --status-file requires a value" >&2; exit 3; }
            STATUS_FILE="$2"
            shift 2
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        --resume)
            RESUME_MODE="status"
            shift
            ;;
        --resume-from)
            [[ -n "${2:-}" ]] || { echo "ERROR: --resume-from requires a log directory path" >&2; exit 3; }
            RESUME_MODE="logdir"
            RESUME_LOG_DIR="$2"
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

# Validate arguments based on mode
if [[ -n "$RESUME_MODE" ]]; then
    # Resume mode - issue and branch will be read from status.json
    :
elif [[ -z "$ISSUE_NUMBER" || -z "$BASE_BRANCH" ]]; then
    echo "ERROR: --issue and --branch are required (or use --resume/--resume-from)"
    usage
fi

# Sanitize BASE_BRANCH: reject characters that could enable prompt injection or shell injection
# Valid git branch chars: alphanumeric, hyphen, underscore, dot, forward slash
if [[ -n "$BASE_BRANCH" ]] && ! [[ "$BASE_BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
    echo "ERROR: BASE_BRANCH contains invalid characters: $BASE_BRANCH" >&2
    echo "Branch names must match [a-zA-Z0-9._/-]+" >&2
    exit 3
fi

# =============================================================================
# LOGGING FUNCTIONS (defined early so other functions can use log/log_error)
# Note: LOG_FILE and mkdir happen later after LOG_BASE is set
# =============================================================================

LOG_FILE=""
STAGE_COUNTER=0
_CONSECUTIVE_TIMEOUTS=0
_TIMED_OUT_STAGE_NAMES=""

log() {
    local msg="[$(date -Iseconds)] $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$msg" >> "$LOG_FILE"
    fi
    printf '%s\n' "$msg" >&2
}

log_error() {
    local msg="[$(date -Iseconds)] ERROR: $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$msg" >> "$LOG_FILE"
    fi
    printf '%s\n' "$msg" >&2
}

log_warn() {
    local msg="[$(date -Iseconds)] WARN: $*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$msg" >> "$LOG_FILE"
    fi
    printf '%s\n' "$msg" >&2
}

next_stage_log() {
    local stage_name="$1"
    STAGE_COUNTER=$((STAGE_COUNTER + 1))
    printf "%02d-%s.log" "$STAGE_COUNTER" "$stage_name"
}

# =============================================================================
# STATUS FILE MANAGEMENT
# =============================================================================

init_status() {
    jq -n \
        --arg state "initializing" \
        --arg issue "$ISSUE_NUMBER" \
        --arg base_branch "$BASE_BRANCH" \
        --arg branch "" \
        --arg current_stage "parse_issue" \
        --argjson current_task "null" \
        --arg log_dir "$LOG_BASE" \
        '{
            state: $state,
            issue: $issue,
            base_branch: $base_branch,
            branch: $branch,
            current_stage: $current_stage,
            current_task: $current_task,
            stages: {
                parse_issue: {status: "pending", started_at: null, completed_at: null},
                validate_plan: {status: "pending", started_at: null, completed_at: null},
                implement: {status: "pending", task_progress: "0/0"},
                quality_loop: {status: "pending", iteration: 0},
                test_loop: {status: "pending", iteration: 0},
                e2e_verify: {status: "pending"},
                acceptance_test: {status: "pending"},
                deploy_verify: {status: "pending"},
                docs: {status: "pending"},
                pr: {status: "pending"},
                pr_review: {status: "pending", iteration: 0},
                complete: {status: "pending"}
            },
            tasks: [],
            quality_iterations: 0,
            test_iterations: 0,
            pr_review_iterations: 0,
            last_update: (now | todate),
            log_dir: $log_dir
        }' > "$STATUS_FILE"

    log "Initialized status file: $STATUS_FILE"
    sync_status_to_log
}

update_stage() {
    local stage="$1"
    local status="$2"
    local extra_field="${3:-}"
    local extra_value="${4:-}"

    if [[ -n "$extra_field" ]]; then
        jq --arg stage "$stage" \
           --arg status "$status" \
           --arg field "$extra_field" \
           --arg value "$extra_value" \
           '.stages[$stage].status = $status |
            .stages[$stage][$field] = $value |
            .current_stage = $stage |
            .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    else
        jq --arg stage "$stage" \
           --arg status "$status" \
           '.stages[$stage].status = $status |
            .current_stage = $stage |
            .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    fi
    sync_status_to_log
}

set_stage_started() {
    local stage="$1"
    jq --arg stage "$stage" \
       '.stages[$stage].started_at = (now | todate) |
        .stages[$stage].status = "in_progress" |
        .current_stage = $stage |
        .state = "running" |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_stage_completed() {
    local stage="$1"
    jq --arg stage "$stage" \
       '.stages[$stage].completed_at = (now | todate) |
        .stages[$stage].status = "completed" |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

update_task() {
    local task_id="$1"
    local status="$2"
    local review_attempts="${3:-0}"

    jq --argjson id "$task_id" \
       --arg status "$status" \
       --argjson attempts "$review_attempts" \
       '(.tasks[] | select(.id == $id)).status = $status |
        (.tasks[] | select(.id == $id)).review_attempts = $attempts |
        .current_task = $id |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_tasks() {
    local tasks_json="$1"
    jq --argjson tasks "$tasks_json" \
       '.tasks = $tasks |
        .stages.implement.task_progress = "0/\($tasks | length)" |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_branch_info() {
    local branch="$1"
    jq --arg branch "$branch" \
       '.branch = $branch | .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

set_final_state() {
    local state="$1"
    jq --arg state "$state" \
       '.state = $state | .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

increment_quality_iteration() {
    jq '.quality_iterations += 1 |
        .stages.quality_loop.iteration = .quality_iterations |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

increment_test_iteration() {
    jq '.test_iterations += 1 |
        .stages.test_loop.iteration = .test_iterations |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

increment_pr_review_iteration() {
    jq '.pr_review_iterations += 1 |
        .stages.pr_review.iteration = .pr_review_iterations |
        .last_update = (now | todate)' \
       "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    sync_status_to_log
}

# =============================================================================
# RESUME FUNCTIONALITY
# =============================================================================

# Validate that a status file has required fields for resumption
# Returns 0 if valid, 1 if invalid
validate_resume_status() {
    local status_path="$1"

    if [[ ! -f "$status_path" ]]; then
        echo "ERROR: Status file not found: $status_path" >&2
        return 1
    fi

    # Check required fields exist
    local required_fields=("issue" "branch" "current_stage" "log_dir")
    local field
    for field in "${required_fields[@]}"; do
        local value
        value=$(jq -r ".$field // empty" "$status_path" 2>/dev/null)
        if [[ -z "$value" || "$value" == "null" ]]; then
            echo "ERROR: Status file missing required field: $field" >&2
            return 1
        fi
    done

    # Check state is resumable (not already completed or in error)
    local state
    state=$(jq -r '.state' "$status_path" 2>/dev/null)
    if [[ "$state" == "completed" ]]; then
        echo "ERROR: Cannot resume - workflow already completed" >&2
        return 1
    fi

    return 0
}

# Load resume state from status file
# Sets global variables: ISSUE_NUMBER, BASE_BRANCH, LOG_BASE, BRANCH
# Also sets: RESUME_STAGE, RESUME_TASK, RESUME_TASKS_JSON
load_resume_state() {
    local status_path="$1"

    ISSUE_NUMBER=$(jq -r '.issue' "$status_path")
    # Restore BASE_BRANCH from status file (fall back to command-line value if not stored)
    local stored_base_branch
    stored_base_branch=$(jq -r '.base_branch // empty' "$status_path")
    if [[ -n "$stored_base_branch" ]]; then
        if ! [[ "$stored_base_branch" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
            echo "ERROR: Stored base_branch contains invalid characters: $stored_base_branch" >&2
            exit 3
        fi
        BASE_BRANCH="$stored_base_branch"
    elif [[ -z "$BASE_BRANCH" ]]; then
        echo "WARNING: No base_branch in status file and none provided via --branch" >&2
    fi
    BRANCH=$(jq -r '.branch' "$status_path")
    LOG_BASE=$(jq -r '.log_dir' "$status_path")

    RESUME_STAGE=$(jq -r '.current_stage' "$status_path")
    RESUME_TASK=$(jq -r '.current_task // 0' "$status_path")
    RESUME_TASKS_JSON=$(jq -c '.tasks // []' "$status_path")

    # Restore iteration counters
    RESUME_QUALITY_ITERATIONS=$(jq -r '.quality_iterations // 0' "$status_path")
    RESUME_TEST_ITERATIONS=$(jq -r '.test_iterations // 0' "$status_path")
    RESUME_PR_ITERATIONS=$(jq -r '.pr_review_iterations // 0' "$status_path")

    # Get PR number if it exists
    RESUME_PR_NUMBER=$(jq -r '.stages.pr.pr_number // empty' "$status_path")
}

# Check if a stage is completed in status file
# Returns 0 if completed, 1 if not
is_stage_completed() {
    local stage="$1"
    local status
    status=$(jq -r ".stages.$stage.status" "$STATUS_FILE" 2>/dev/null)
    [[ "$status" == "completed" ]]
}

# Check if a stage result is a timeout error
# Arguments:
#   $1 - JSON string from run_stage output
# Returns 0 if timeout, 1 if not
is_stage_timeout() {
    local result="${1:-}"
    [[ -z "$result" ]] && return 1
    local err_status err_type
    err_status=$(printf '%s' "$result" | jq -r '.status // empty' 2>/dev/null)
    err_type=$(printf '%s' "$result" | jq -r '.error // empty' 2>/dev/null)
    [[ "$err_status" == "error" && "$err_type" == "timeout" ]]
}

# Get count of completed tasks
get_completed_task_count() {
    jq '[.tasks[] | select(.status == "completed")] | length' "$STATUS_FILE" 2>/dev/null || echo "0"
}

# =============================================================================
# RESUME MODE INITIALIZATION
# =============================================================================

# These will be populated in resume mode
BRANCH=""
RESUME_STAGE=""
RESUME_TASK=""
RESUME_TASKS_JSON=""
RESUME_QUALITY_ITERATIONS=0
RESUME_TEST_ITERATIONS=0
RESUME_PR_ITERATIONS=0
RESUME_PR_NUMBER=""

if [[ "$RESUME_MODE" == "logdir" ]]; then
    # Resume from specific log directory
    if [[ ! -d "$RESUME_LOG_DIR" ]]; then
        echo "ERROR: Log directory not found: $RESUME_LOG_DIR" >&2
        exit 1
    fi

    local_status_file="$RESUME_LOG_DIR/status.json"
    if [[ ! -f "$local_status_file" ]]; then
        # Try parent directory's status.json (log_dir may be relative)
        local_status_file="status.json"
    fi

    if ! validate_resume_status "$local_status_file"; then
        exit 1
    fi

    load_resume_state "$local_status_file"
    STATUS_FILE="$local_status_file"
    # LOG_BASE was set by load_resume_state

elif [[ "$RESUME_MODE" == "status" ]]; then
    # Resume from current status file
    if ! validate_resume_status "$STATUS_FILE"; then
        exit 1
    fi

    load_resume_state "$STATUS_FILE"

else
    # Normal mode - set LOG_BASE
    LOG_BASE="logs/implement-issue/issue-${ISSUE_NUMBER}-$(date +%Y%m%d-%H%M%S)"
fi

# Display mode info
if [[ -n "$RESUME_MODE" ]]; then
    echo "Implement Issue Orchestrator (RESUME MODE)"
    echo "Resuming from: $STATUS_FILE"
    echo "Issue: #$ISSUE_NUMBER"
    echo "Branch: $BRANCH"
    echo "Resume stage: $RESUME_STAGE"
    [[ -n "$RESUME_TASK" && "$RESUME_TASK" != "null" ]] && echo "Resume task: $RESUME_TASK"
    echo "Log dir: $LOG_BASE"
else
    echo "Implement Issue Orchestrator"
    echo "Issue: #$ISSUE_NUMBER"
    echo "Branch: $BASE_BRANCH"
    echo "Agent: ${AGENT:-default}"
    echo "Status file: $STATUS_FILE"
    echo "Log dir: $LOG_BASE"
fi

# Create log directories
mkdir -p "$LOG_BASE/stages" "$LOG_BASE/context"
LOG_FILE="$LOG_BASE/orchestrator.log"
STAGE_COUNTER=0
_CONSECUTIVE_TIMEOUTS=0
_TIMED_OUT_STAGE_NAMES=""

# =============================================================================
# STATUS SYNC TO LOG DIRECTORY
# =============================================================================

# Sync status.json to log directory after every update
# This ensures status.json exists in LOG_BASE for resume-from functionality
sync_status_to_log() {
	if [[ -n "$LOG_BASE" && -d "$LOG_BASE" && -f "$STATUS_FILE" ]]; then
		local target="$LOG_BASE/status.json"
		# Avoid copying file to itself (happens with --resume-from)
		# Guard: realpath fails if target doesn't exist yet (first sync call)
		if [[ ! -f "$target" ]] || [[ "$(realpath "$STATUS_FILE")" != "$(realpath "$target")" ]]; then
			cp "$STATUS_FILE" "$target"
		fi
	fi
}

# =============================================================================
# ISSUE/PR COMMENT HELPERS
# =============================================================================

# comment_issue <title> <body> [agent]
# If agent is provided, shows "Written by `agent`", otherwise "Posted by orchestrator"
# When QUIET=true, this is a no-op — ALL issue comments are suppressed (use --quiet
# for automated runs where issue tracker noise should be eliminated entirely).
comment_issue() {
	[[ "${QUIET:-false}" == "true" ]] && return 0
	local title="$1"
	local body="$2"
	local agent="${3:-}"
	local attribution

	if [[ -n "$agent" ]]; then
		attribution="Written by \`$agent\`"
	else
		attribution="Posted by \`implement-issue-orchestrator\`"
	fi

	local comment
	comment=$(cat <<EOF
## $title
###### *$attribution*

$body
EOF
)

	log "Commenting on issue #$ISSUE_NUMBER: $title"
	if ! "$PLATFORM_DIR/comment-issue.sh" "$ISSUE_NUMBER" "$comment" 2>>"${LOG_FILE:-/dev/stderr}"; then
		log_error "Failed to comment on issue #$ISSUE_NUMBER"
	fi
}

# comment_pr <pr_num> <title> <body> [agent]
# If agent is provided, shows "Written by `agent`", otherwise "Posted by orchestrator"
comment_pr() {
	[[ "${QUIET:-false}" == "true" ]] && return 0
	local pr_num="$1"
	local title="$2"
	local body="$3"
	local agent="${4:-}"
	local attribution

	if [[ -n "$agent" ]]; then
		attribution="Written by \`$agent\`"
	else
		attribution="Posted by \`implement-issue-orchestrator\`"
	fi

	local comment
	comment=$(cat <<EOF
## $title
###### *$attribution*

$body
EOF
)

	log "Commenting on PR #$pr_num: $title"
	if ! "$PLATFORM_DIR/comment-mr.sh" "$pr_num" "$comment" 2>>"${LOG_FILE:-/dev/stderr}"; then
		log_error "Failed to comment on PR #$pr_num"
	fi
}

# =============================================================================
# TEST RUNNER
# =============================================================================

run_tests() {
    local exit_code=0

    if [[ -n "${TEST_UNIT_CMD:-}" ]]; then
        log "Running unit tests: $TEST_UNIT_CMD"
        eval "$TEST_UNIT_CMD" || exit_code=$?
    fi

    if [[ $exit_code -eq 0 ]] && [[ -n "${TEST_E2E_CMD:-}" ]]; then
        log "Running E2E tests: $TEST_E2E_CMD"
        eval "$TEST_E2E_CMD" || exit_code=$?
    fi

    return $exit_code
}

# =============================================================================
# RATE LIMIT DETECTION
# =============================================================================

detect_rate_limit() {
    local output="$1"

    # Check structured output first
    local status
    status=$(printf '%s' "$output" | jq -r '.structured_output.status // empty' 2>/dev/null)

    if [[ "$status" == "success" ]]; then
        return 1
    fi

    if [[ "$status" == "rate_limit" ]]; then
        return 0
    fi

    # Only check text patterns if there's an actual error
    # (prevents false positives when reviews mention "rate limiting" as a feature)
    local is_error
    is_error=$(printf '%s' "$output" | jq -r '.is_error // false' 2>/dev/null)

    if [[ "$is_error" != "true" ]]; then
        return 1
    fi

    # Fallback to text pattern matching (only for errors)
    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)
    if printf '%s' "$result" | grep -qiE 'rate.limit|429|too many requests|quota.exceeded'; then
        return 0
    fi

    return 1
}

extract_wait_time() {
    local output="$1"
    local result
    result=$(printf '%s' "$output" | jq -r '.result // empty' 2>/dev/null)
    local search_text="$result $output"

    # Try retry-after
    local retry_after
    retry_after=$(printf '%s' "$search_text" | grep -oiE 'retry.after[^0-9]*([0-9]+)' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$retry_after" ]] && (( retry_after > 0 )); then
        printf '%s\n' "$retry_after"
        return
    fi

    # Try wait X minutes
    local wait_mins
    wait_mins=$(printf '%s' "$search_text" | grep -oiE 'wait[^0-9]*([0-9]+)[^0-9]*min' | grep -oE '[0-9]+' | head -1)
    if [[ -n "$wait_mins" ]] && (( wait_mins > 0 )); then
        printf '%s\n' "$((wait_mins * 60))"
        return
    fi

    printf '%s\n' "$RATE_LIMIT_DEFAULT_WAIT"
}

handle_rate_limit() {
    local output="$1"
    local wait_time
    wait_time=$(extract_wait_time "$output")
    wait_time=$((wait_time + RATE_LIMIT_BUFFER))

    local resume_at
    resume_at=$(date -Iseconds -d "+${wait_time} seconds" 2>/dev/null || date -v+${wait_time}S -Iseconds 2>/dev/null)

    log "Rate limit hit. Waiting ${wait_time}s until $resume_at"
    sleep "$wait_time"
}

# =============================================================================
# STAGE RUNNERS
# =============================================================================

run_stage() {
    local stage_name="$1"
    local prompt="$2"
    local schema_file="$3"
    local agent="${4:-}"
    local complexity="${5:-}"
    local timeout_override="${6:-}"   # optional: override stage timeout (seconds)
    local model_override="${7:-}"    # optional: override model (haiku|sonnet|opus)

    local stage_log="$LOG_BASE/stages/$(next_stage_log "$stage_name")"

    # Validate schema file exists
    if [[ ! -f "$SCHEMA_DIR/$schema_file" ]]; then
        log_error "Schema file not found: $SCHEMA_DIR/$schema_file"
        _CONSECUTIVE_TIMEOUTS=0
        _TIMED_OUT_STAGE_NAMES=""
        echo '{"status":"error","error":"schema not found"}'
        return 1
    fi

    local schema
    schema=$(jq -c . "$SCHEMA_DIR/$schema_file")

    # Resolve model and fallback from stage name + complexity hint
    local model fallback_model
    if [[ -n "$model_override" ]]; then
        model="$model_override"
    else
        model=$(resolve_model "$stage_name" "$complexity")
    fi
    fallback_model=$(_next_model_up "$model")

    log "Running stage: $stage_name"
    log "  Schema: $schema_file"
    log "  Agent: ${agent:-default}"
    log "  Model: $model (fallback: $fallback_model)"
    if [[ -n "$complexity" ]]; then
        log "  Complexity: $complexity"
    fi
    log "  Log: $stage_log"

    local -a agent_args=()
    if [[ -n "$agent" ]]; then
        agent_args=(--agent "$agent")
    fi

    local stage_timeout
    if [[ -n "$timeout_override" ]]; then
        stage_timeout="$timeout_override"
    else
        stage_timeout=$(get_stage_timeout "$stage_name")
    fi
    log "  Timeout: ${stage_timeout}s"

    # Pass --fallback-model for resilience (skip if same as primary — CLI rejects duplicates)
    local -a fallback_args=()
    if [[ "$fallback_model" != "$model" ]]; then
        fallback_args=(--fallback-model "$fallback_model")
    fi

    # Cap exploration for inherently light-tier stages (parse, pr, complete, etc.)
    # These are mechanical and should complete in a few turns.
    # Do NOT cap implement/review/fix stages that use haiku via S-complexity override —
    # those still need enough turns to read files, make edits, and produce output.
    local -a turns_args=()
    local _matched_prefix _inherent_tier
    _matched_prefix=$(_match_stage_prefix "$stage_name") || true
    _inherent_tier=$(_stage_to_tier "${_matched_prefix:-}")
    if [[ "$model" == "haiku" && "$_inherent_tier" == "light" ]]; then
        turns_args=(--max-turns 10)
        log "  Max turns: 10 (inherently light stage)"
    elif [[ "$model" == "haiku" ]]; then
        turns_args=(--max-turns 15)
        log "  Max turns: 15 (haiku via complexity override)"
    elif [[ "$model" == "sonnet" ]]; then
        if [[ "$complexity" == "M" || "$complexity" == "L" ]]; then
            turns_args=(--max-turns 40)
            log "  Max turns: 40 (sonnet with M/L complexity)"
        else
            turns_args=(--max-turns 25)
            log "  Max turns: 25 (sonnet with S/empty complexity)"
        fi
    fi

    local output
    local exit_code=0

    output=$(timeout "$stage_timeout" env -u CLAUDECODE "$CLAUDE_CLI" -p "$prompt" \
        ${agent_args[@]+"${agent_args[@]}"} \
        --model "$model" \
        ${fallback_args[@]+"${fallback_args[@]}"} \
        ${turns_args[@]+"${turns_args[@]}"} \
        --dangerously-skip-permissions \
        --output-format json \
        --json-schema "$schema" \
        2>&1) || exit_code=$?

    printf '%s\n' "=== $stage_name output ===" >> "$stage_log"
    printf '%s\n' "$output" >> "$stage_log"
    printf '%s\n' "=== exit code: $exit_code ===" >> "$stage_log"

    # Check timeout — but still try to extract structured output first.
    # The agent may have produced valid output before the timeout killed the CLI.
    if (( exit_code == 124 )); then
        local timeout_structured
        timeout_structured=$(printf '%s' "$output" | jq -c '.structured_output // empty' 2>/dev/null)
        if [[ -n "$timeout_structured" ]]; then
            log "WARN: Stage $stage_name timed out after ${stage_timeout}s but produced structured output — using it"
            printf '%s\n' "$timeout_structured"
            return 0
        fi

        # Fallback: if no structured output, try .result text wrapping
        # (same pattern as lines 936-944)
        local timeout_fallback_result
        timeout_fallback_result=$(printf '%s' "$output" | jq -c '
            select(.is_error == false and .result != null) |
            {status: "success", summary: .result}
        ' 2>/dev/null)

        if [[ -n "$timeout_fallback_result" ]]; then
            log "WARN: Stage $stage_name timed out after ${stage_timeout}s but produced .result — using fallback"
            printf '%s\n' "$timeout_fallback_result"
            return 0
        fi

        # Retry with a 20% longer timeout before giving up
        local retry_timeout
        retry_timeout=$(( stage_timeout + stage_timeout / 5 ))
        log "WARN: Stage $stage_name timed out after ${stage_timeout}s — retrying with ${retry_timeout}s timeout"
        printf '%s\n' "=== $stage_name timeout retry (${retry_timeout}s) ===" >> "$stage_log"

        exit_code=0
        output=$(timeout "$retry_timeout" env -u CLAUDECODE "$CLAUDE_CLI" -p "$prompt" \
            ${agent_args[@]+"${agent_args[@]}"} \
            --model "$model" \
            ${fallback_args[@]+"${fallback_args[@]}"} \
            ${turns_args[@]+"${turns_args[@]}"} \
            --dangerously-skip-permissions \
            --output-format json \
            --json-schema "$schema" \
            2>&1) || exit_code=$?

        printf '%s\n' "$output" >> "$stage_log"
        printf '%s\n' "=== timeout retry exit code: $exit_code ===" >> "$stage_log"

        if (( exit_code == 124 )); then
            log_error "Stage $stage_name timed out again after ${retry_timeout}s"
            _TIMED_OUT_STAGE_NAMES="${_TIMED_OUT_STAGE_NAMES:+$_TIMED_OUT_STAGE_NAMES, }$stage_name"
            (( _CONSECUTIVE_TIMEOUTS++ )) || true
            if (( _CONSECUTIVE_TIMEOUTS >= 2 )); then
                log_warn "Cascade timeout detected: $_CONSECUTIVE_TIMEOUTS consecutive stage(s)" \
                    "timed out: $_TIMED_OUT_STAGE_NAMES. Consider increasing timeout or reducing complexity."
            fi
            echo '{"status":"error","error":"timeout"}'
            return 1
        fi
    fi

    # Check for max turns exhaustion — escalate to next model up and retry.
    # CLI returns subtype:"error_max_turns" with exit code 0 and is_error:false,
    # but no structured_output, so we detect it before the structured output check.
    local output_subtype
    output_subtype=$(printf '%s' "$output" | jq -r '.subtype // empty' 2>/dev/null)
    if [[ "$output_subtype" == "error_max_turns" ]]; then
        local escalated_model
        escalated_model=$(_next_model_up "$model")

        if [[ "$escalated_model" == "$model" ]]; then
            # Already at ceiling (opus) — can't escalate further
            log_error "Stage $stage_name hit max turns with $model (ceiling) — cannot escalate"
            echo '{"status":"error","error":"max_turns_exhausted_at_ceiling"}'
            return 1
        fi

        log "WARN: Stage $stage_name hit max turns with $model — escalating to $escalated_model (no turn cap)"
        printf '%s\n' "=== $stage_name escalating: $model → $escalated_model ===" >> "$stage_log"

        # Retry with escalated model and no --max-turns cap
        local escalated_fallback
        escalated_fallback=$(_next_model_up "$escalated_model")
        local -a escalated_fallback_args=()
        if [[ "$escalated_fallback" != "$escalated_model" ]]; then
            escalated_fallback_args=(--fallback-model "$escalated_fallback")
        fi

        output=$(timeout "$stage_timeout" env -u CLAUDECODE "$CLAUDE_CLI" -p "$prompt" \
            ${agent_args[@]+"${agent_args[@]}"} \
            --model "$escalated_model" \
            ${escalated_fallback_args[@]+"${escalated_fallback_args[@]}"} \
            --dangerously-skip-permissions \
            --output-format json \
            --json-schema "$schema" \
            2>&1) || exit_code=$?

        printf '%s\n' "=== $stage_name escalation output ===" >> "$stage_log"
        printf '%s\n' "$output" >> "$stage_log"
        printf '%s\n' "=== escalation exit code: $exit_code ===" >> "$stage_log"
    fi

    # Check rate limit
    if detect_rate_limit "$output"; then
        handle_rate_limit "$output"
        # Retry
        output=$(timeout "$stage_timeout" env -u CLAUDECODE "$CLAUDE_CLI" -p "$prompt" \
            ${agent_args[@]+"${agent_args[@]}"} \
            --model "$model" \
            ${fallback_args[@]+"${fallback_args[@]}"} \
            ${turns_args[@]+"${turns_args[@]}"} \
            --dangerously-skip-permissions \
            --output-format json \
            --json-schema "$schema" \
            2>&1) || exit_code=$?

        printf '%s\n' "=== $stage_name retry output ===" >> "$stage_log"
        printf '%s\n' "$output" >> "$stage_log"
    fi

    # Extract structured output — try .structured_output first, fall back to
    # wrapping .result text as a success payload (subagents sometimes return
    # plain .result without matching the JSON schema)
    local structured
    structured=$(printf '%s' "$output" | jq -c '.structured_output // empty' 2>/dev/null)

    if [[ -z "$structured" ]]; then
        # Fallback: if the CLI returned successfully (.is_error == false) and
        # has a .result string, wrap it as a synthetic structured output
        local fallback_result
        fallback_result=$(printf '%s' "$output" | jq -c '
            select(.is_error == false and .result != null) |
            {status: "success", summary: .result}
        ' 2>/dev/null)

        if [[ -n "$fallback_result" ]]; then
            log "WARNING: No .structured_output from $stage_name — using .result fallback"

            # Field-aware recovery: extract known fields from .result text
            local result_text
            result_text=$(printf '%s' "$output" \
                | jq -r '.result // empty' 2>/dev/null)

            if [[ -n "$result_text" ]]; then
                # Extract pr_number from "PR #N", "MR #N", or "!N"
                # Deliberately omits bare "#N" — too ambiguous (issue refs,
                # step counts, commit hashes) and would produce wrong PR nums.
                local pr_re='[PpMm][Rr] *#([0-9]+)'
                local bang_re='!([0-9]+)'
                if [[ "$result_text" =~ $pr_re ]] \
                    || [[ "$result_text" =~ $bang_re ]]; then
                    local pr_num="${BASH_REMATCH[1]}"
                    fallback_result=$(printf '%s' "$fallback_result" \
                        | jq -c --argjson n "$pr_num" \
                            '.pr_number = $n')
                fi

                # Extract branch from common patterns
                local branch_re='[Bb]ranch[: ]+([a-zA-Z0-9/_.-]+)'
                if [[ "$result_text" =~ $branch_re ]]; then
                    local br="${BASH_REMATCH[1]}"
                    fallback_result=$(printf '%s' "$fallback_result" \
                        | jq -c --arg b "$br" \
                            '.branch = $b')
                fi

                # Extract tasks JSON array embedded in text using a
                # balanced-bracket parser so nested arrays (e.g. a
                # "dependencies" field) are not truncated at their first ']'.
                local tasks_match
                tasks_match=$(python3 -c "
import sys, re
t = sys.stdin.read()
for m in re.finditer(r'\[\s*\{', t):
    s = m.start()
    d = 0
    for i, c in enumerate(t[s:], s):
        if c == '[': d += 1
        elif c == ']':
            d -= 1
            if d == 0:
                print(t[s:i+1])
                break
    break" <<< "$result_text" 2>/dev/null)
                if [[ -n "$tasks_match" ]]; then
                    local valid_tasks
                    valid_tasks=$(printf '%s' "$tasks_match" \
                        | jq -c 'if type == "array" then . else empty end' \
                            2>/dev/null)
                    if [[ -n "$valid_tasks" ]]; then
                        fallback_result=$(printf '%s' "$fallback_result" \
                            | jq -c --argjson t "$valid_tasks" \
                                '.tasks = $t')
                    fi
                fi
            fi

            printf '%s\n' "$fallback_result"
            return 0
        fi

        # Diagnostic: log raw output first 500 chars and byte count when both
        # .structured_output and .result extraction fail
        local output_byte_count
        output_byte_count=$(printf '%s' "$output" | wc -c)
        local output_preview="${output:0:500}"
        log "Diagnostic fallback failure — Output byte count: $output_byte_count"
        log "Diagnostic fallback failure — First 500 characters: $output_preview"

        log_error "No structured output from $stage_name"
        _CONSECUTIVE_TIMEOUTS=0
        _TIMED_OUT_STAGE_NAMES=""
        echo '{"status":"error","error":"no structured output"}'
        return 1
    fi

    _CONSECUTIVE_TIMEOUTS=0
    _TIMED_OUT_STAGE_NAMES=""
    printf '%s\n' "$structured"
}

# =============================================================================
# QUALITY LOOP HELPER
# =============================================================================

# Run the quality loop (simplify -> review -> fix, repeat)
# Note: Testing is handled separately by run_test_loop after all tasks complete
# Arguments:
#   $1 - working directory
#   $2 - branch name
#   $3 - stage prefix for logging (e.g., "task-1" or "pr-fix")
#   $4 - agent to use for fix stages (optional, falls back to global $AGENT)
#   $5 - max iterations override (optional, defaults to MAX_QUALITY_ITERATIONS)
#   $6 - complexity hint for model selection (S/M/L, optional)
# Returns:
#   0 on success (approved)
#   2 on max iterations exceeded (calls exit 2)
run_quality_loop() {
    local loop_dir="$1"
    local loop_branch="$2"
    local stage_prefix="${3:-main}"
    local loop_agent="${4:-$AGENT}"
    local max_iterations="${5:-$MAX_QUALITY_ITERATIONS}"
    local loop_complexity="${6:-}"

    local loop_approved=false
    local loop_iteration=0  # Per-loop counter (resets each call)
    local skip_simplify=false  # Set when prior simplify reported no changes; reset after any fix

    while [[ "$loop_approved" != "true" ]]; do
        loop_iteration=$((loop_iteration + 1))
        increment_quality_iteration  # Global counter for status tracking

        if (( loop_iteration > max_iterations )); then
            log_error "Quality loop for $stage_prefix exceeded max iterations ($max_iterations)"
            set_final_state "max_iterations_quality"
            exit 2
        fi

        log "Quality loop iteration $loop_iteration/$max_iterations (prefix: $stage_prefix)"

        # -------------------------------------------------------------------------
        # SIMPLIFY
        # -------------------------------------------------------------------------
        local simplify_summary="No changes"

        if [[ "$skip_simplify" == "true" ]]; then
            log "Skipping simplify for $stage_prefix iter $loop_iteration (prior iteration reported no changes)"
        else
            # Pre-compute modified TypeScript/React files (three-dot merge-base diff)
            # before simplify stage. Recomputed each iteration since fix stages may add commits.
            local simplify_changed_files_raw simplify_changed_files
            simplify_changed_files_raw=$(git -C "$loop_dir" diff "$BASE_BRANCH"...HEAD --name-only -- '*.ts' '*.tsx' 2>/dev/null || true)
            simplify_changed_files=$(printf '%s\n' "$simplify_changed_files_raw" | grep -v -E '^$' || true)

            local simplify_prompt="Simplify modified TypeScript/React files in the current branch in working directory $loop_dir on branch $loop_branch.

IMPORTANT SCOPE CONSTRAINT: This is for issue #$ISSUE_NUMBER. Only simplify code that is directly related to the issue's goals. Do NOT apply unrelated refactoring to files that were only incidentally touched or are outside the issue's focus area.

MODIFIED TYPESCRIPT/REACT FILES:
$simplify_changed_files

If no TypeScript/React files were modified as part of this issue's implementation, make no changes and report 'No changes to simplify'.

Simplify code for clarity and consistency without changing functionality.
Output a summary of changes made."

            local simplify_result
            simplify_result=$(run_stage "simplify-${stage_prefix}-iter-$loop_iteration" "$simplify_prompt" "implement-issue-simplify.json" "" "$loop_complexity")

            simplify_summary=$(printf '%s' "$simplify_result" | jq -r '.summary // "No changes"')

            # If simplify reported no changes, skip it on the next iteration until a
            # fix stage runs (which may introduce new simplification opportunities).
            if echo "$simplify_summary" | grep -qi "no changes"; then
                skip_simplify=true
                log "Simplify reported no changes — will skip simplify on next iteration"
            else
                skip_simplify=false
            fi
        fi

        # -------------------------------------------------------------------------
        # REVIEW
        # -------------------------------------------------------------------------

        # Build cumulative context from prior iterations
        local prior_context=""
        local review_history_file="$LOG_BASE/context/review-history-${stage_prefix}.json"
        if [[ -f "$review_history_file" ]] && (( loop_iteration > 1 )); then
            prior_context=$(jq -r '
                [.[] | "Iteration \(.iteration): \(.issues | length) issues - \(.issues | map(.description) | join("; "))"] | join("\n")
            ' "$review_history_file" 2>/dev/null || printf '')
        fi

        # Pre-compute modified files (three-dot merge-base diff) for review stage
        local review_changed_files_raw review_changed_files
        review_changed_files_raw=$(git -C "$loop_dir" diff "$BASE_BRANCH"...HEAD --name-only 2>/dev/null || true)
        review_changed_files=$(printf '%s\n' "$review_changed_files_raw" | grep -v -E '^$' || true)

        local review_prompt="Review the code changes for task scope '$stage_prefix' in working directory $loop_dir on branch $loop_branch.

IMPORTANT: This is a task-level quality check within the implementation workflow, NOT a full PR review.
Your job is to verify code quality for the changes made in this task only.

Check:
- Code patterns and standards
- Consistency with codebase conventions
- Potential bugs or issues
- Security concerns

FILES CHANGED:
$review_changed_files

$(if [[ -n "$prior_context" ]]; then
    printf '\n'
    printf 'PRIOR ITERATION FINDINGS (verify if these were fixed — do NOT re-report fixed issues):\n'
    printf '%s\n' "$prior_context"
    printf '\n'
    printf 'Focus on: (1) verifying prior issues were actually fixed, (2) finding NEW issues only.\n'
fi)

DO NOT recommend 'approve and merge' - this is not a PR review.
Simply output 'approved' if code quality is acceptable, or 'changes_requested' with specific issues to fix."

        local review_result
        review_result=$(run_stage "review-${stage_prefix}-iter-$loop_iteration" "$review_prompt" "implement-issue-review.json" "code-reviewer" "$loop_complexity")

        # Handle timeout: skip result inspection and retry on next iteration
        if is_stage_timeout "$review_result"; then
            log_warn "Review stage timed out on iteration $loop_iteration — retrying next iteration"
            continue
        fi

        local review_verdict review_summary verdict_source
        review_summary=$(printf '%s' "$review_result" | jq -r '.summary // "Review completed"')
        local has_result_field
        has_result_field=$(printf '%s' "$review_result" | jq 'has("result")' 2>/dev/null)

        if [[ "$has_result_field" == "true" ]]; then
            # Structured output available: extract verdict from .result field
            review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
            verdict_source="structured output"
            log "Verdict extracted from structured output: $review_verdict"
        else
            # Fallback: parse verdict from summary text
            verdict_source="fallback text"
            local summary_lower
            summary_lower=$(printf '%s' "$review_summary" | tr '[:upper:]' '[:lower:]')

            # Check for approval keywords
            if grep -qiE '(approved|lgtm|looks good|no issues)' <<< "$summary_lower"; then
                review_verdict="approved"
                log "Verdict parsed from fallback text: approved (matched approval keywords)"
            # Check for rejection keywords
            elif grep -qiE '(changes requested|request changes|must fix|blocking|critical)' <<< "$summary_lower"; then
                review_verdict="changes_requested"
                log "Verdict parsed from fallback text: changes_requested (matched rejection keywords)"
            else
                # Default to changes_requested if ambiguous
                review_verdict="changes_requested"
                log "Verdict parsed from fallback text: changes_requested (ambiguous/default)"
            fi
        fi

        # Append current iteration findings to review history
        local current_issues
        current_issues=$(printf '%s' "$review_result" | jq -c "{iteration: $loop_iteration, issues: (.issues // []), result: (.result // .status // \"unknown\")}" 2>/dev/null)
        if [[ -n "$current_issues" ]]; then
            if [[ -f "$review_history_file" ]]; then
                local existing
                existing=$(< "$review_history_file")
                printf '%s' "$existing" | jq --argjson new "$current_issues" '. + [$new]' > "$review_history_file"
            else
                printf '[%s]' "$current_issues" > "$review_history_file"
            fi
        fi

        # Convergence detection: check if >50% of issues are repeats from prior iterations
        if [[ -f "$review_history_file" ]] && (( loop_iteration > 1 )); then
            local repeat_ratio repeat_issues
            repeat_ratio=$(printf '%s' "$review_result" | jq -r --slurpfile history "$review_history_file" '
                . as $root |
                ($root.issues // []) | length as $current_count |
                if $current_count == 0 then 0
                else
                    [$root.issues[] | .description] as $current |
                    [$history[0][] | .issues[]? | .description] as $prior |
                    [$current[] | select(. as $c | $prior | any(. == $c))] as $repeats |
                    ($repeats | length * 100 / $current_count)
                end
            ' 2>/dev/null || echo 0)
            repeat_issues=$(printf '%s' "$review_result" | jq -r --slurpfile history "$review_history_file" '
                . as $root |
                ($root.issues // []) | length as $current_count |
                if $current_count == 0 then ""
                else
                    [$root.issues[] | .description] as $current |
                    [$history[0][] | .issues[]? | .description] as $prior |
                    [$current[] | select(. as $c | $prior | any(. == $c))] as $repeats |
                    ($repeats | join("\n- "))
                end
            ' 2>/dev/null || echo '')

            if (( repeat_ratio > 33 )); then
                log_warn "Quality loop convergence failure: ${repeat_ratio}% of issues are repeats from prior iterations. Exiting loop.${repeat_issues:+ Repeating: ${repeat_issues}}"

                local convergence_body="⚠️ Quality loop convergence failure: ${repeat_ratio}% of issues are repeats from prior iterations. Breaking loop to prevent waste."
                if [[ -n "$repeat_issues" ]]; then
                    convergence_body+="

**Repeating Issues:**
- $repeat_issues"
                fi

                comment_issue "Quality Loop: Convergence Failure ($stage_prefix)" "$convergence_body" "code-reviewer"
                loop_approved=true
                break
            fi
        fi

        # MAJOR-ISSUE OVERRIDE: same logic as PR review (claude-pipeline#25)
        local major_issue_override=false
        if [[ "$review_verdict" == "approved" ]]; then
            local major_issue_count
            major_issue_count=$(printf '%s' "$review_result" | jq '[.issues // [] | .[] | select(.severity == "major")] | length' 2>/dev/null || echo "0")
            if (( major_issue_count > 0 )); then
                log_warn "Quality review for $stage_prefix approved but $major_issue_count major issue(s) found — overriding to changes_requested"
                review_verdict="changes_requested"
                major_issue_override=true
            fi
        fi

        if [[ "$review_verdict" == "approved" ]]; then
            loop_approved=true
            log "Quality loop for $stage_prefix approved on iteration $loop_iteration"
        else
            local review_comments
            if $major_issue_override; then
                # Filter to include only major-severity issues
                review_comments=$(printf '%s' "$review_result" | jq -r '[.issues // [] | .[] | select(.severity == "major") | .description] | join("\n- ")')
            else
                review_comments=$(printf '%s' "$review_result" | jq -r '.comments // "No comments"')
            fi
            printf '%s\n' "$review_comments" >> "$LOG_BASE/context/review-comments.json"

            local cumulative_findings=""
            if [[ -f "$review_history_file" ]]; then
                if $major_issue_override; then
                    # Filter to include only major-severity issues
                    cumulative_findings=$(jq -r '
                        [.[-2:] | .[] | .issues[]? | select(.severity == "major") | .description] | unique | join("\n- ")
                    ' "$review_history_file" 2>/dev/null || printf '')
                else
                    cumulative_findings=$(jq -r '
                        [.[-2:] | .[] | .issues[]? | .description] | unique | join("\n- ")
                    ' "$review_history_file" 2>/dev/null || printf '')
                fi
            fi

            local fix_prompt="Address code review feedback in working directory $loop_dir on branch $loop_branch.

Current iteration findings:
$review_comments

$(if [[ -n "$cumulative_findings" ]]; then
    printf 'Cumulative findings across all iterations (ensure ALL are addressed):\n'
    printf -- '- %s\n' "$cumulative_findings"
fi)

Fix the issues and commit. Output a summary of fixes applied."

            verify_on_feature_branch "$loop_branch" || true

            # Pass loop_complexity so run_stage can route model selection by task
            # size: S→haiku, M→sonnet, L→opus (via resolve_model in run_stage).
            local fix_result
            fix_result=$(run_stage "fix-review-${stage_prefix}-iter-$loop_iteration" "$fix_prompt" "implement-issue-fix.json" "$loop_agent" "$loop_complexity")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Fix stage introduced new changes — simplify should run next iteration.
            skip_simplify=false
        fi
    done

    return 0
}

# Determines whether the docs stage should run for a given change scope.
# Arguments:
#   $1 - scope: typescript | bash | config | mixed
# Returns:
#   0 if docs stage should run (typescript or mixed scope)
#   1 if docs stage should be skipped (bash or config — no TS files changed)
should_run_docs_stage() {
    local scope="$1"
    case "$scope" in
        bash|config) return 1 ;;
        *)            return 0 ;;
    esac
}

# Determines whether the deploy_verify stage should run.
# Gate conditions (both must be true):
#   (a) DEPLOY_VERIFY_CMD is configured in platform.sh
#   (b) Issue has env:test/env:nas/env:staging label OR issue body
#       contains a "## Deploy Verification" section
# Arguments:
#   $1 - issue number
# Returns:
#   0 if deploy_verify stage should run
#   1 if it should be skipped
should_run_deploy_verify() {
    local issue_number="$1"

    # Gate (a): DEPLOY_VERIFY_CMD must be configured
    if [[ -z "${DEPLOY_VERIFY_CMD:-}" ]]; then
        return 1
    fi

    # Gate (b): check labels first, then fall back to issue body
    local labels
    case "${TRACKER:-github}" in
        github)
            labels=$(gh issue view "$issue_number" \
                --json labels -q '.labels[].name' 2>/dev/null || true)
            ;;
        jira)
            labels=$(acli jira workitem view "$issue_number" \
                --fields labels --json 2>/dev/null \
                | jq -r '.fields.labels[]?' 2>/dev/null || true)
            ;;
    esac

    # Check for env:test, env:nas, or env:staging labels
    if printf '%s\n' "$labels" | grep -qE '^env:(test|nas|staging)$'; then
        return 0
    fi

    # Check for ## Deploy Verification section in issue body
    local issue_body_file="$LOG_BASE/context/issue-body.md"
    if [[ -f "$issue_body_file" ]]; then
        if grep -q '^## Deploy Verification' "$issue_body_file"; then
            return 0
        fi
    fi

    return 1
}

# Poll a health URL until a 2xx response is received or max_retries are exhausted.
# Returns 0 on success (2xx received, or URL is empty — skip means healthy).
# Returns 1 when all retries are exhausted without a 2xx.
#
# Arguments:
#   $1 - health URL (empty string = skip poll, return 0 immediately)
#   $2 - max retries (default: 90)
#   $3 - poll interval in seconds (default: 10)
poll_health_url() {
    local url="$1"
    local max_retries="${2:-90}"
    local poll_interval="${3:-10}"

    # Empty URL means no health check configured — treat as healthy
    if [[ -z "$url" ]]; then
        return 0
    fi

    local attempt=0
    while ((attempt < max_retries)); do
        ((attempt++))
        local http_code
        http_code=$(curl -s -o /dev/null -w '%{http_code}' \
            --max-time 10 \
            "$url" 2>/dev/null || printf '%s' "000")

        if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
            log "Health check passed (HTTP $http_code) on attempt $attempt"
            return 0
        fi

        if ((attempt % 6 == 0)); then
            log "Health poll attempt $attempt/$max_retries — HTTP $http_code"
        fi

        sleep "$poll_interval"
    done

    return 1
}

# Check if all tasks in status.json are S-complexity.
# Returns:
#   0 if all tasks are S-complexity (docs can be skipped)
#   1 if any task is M, L, or unknown complexity
all_tasks_s_complexity() {
    local tasks_json
    tasks_json=$(jq -r '.tasks[]?.description // empty' "$STATUS_FILE" 2>/dev/null)
    [[ -z "$tasks_json" ]] && return 1
    while IFS= read -r desc; do
        local size
        size=$(extract_task_size "$desc")
        [[ "$size" != "S" ]] && return 1
    done <<< "$tasks_json"
    return 0
}

# Get PR review configuration based on diff size.
# Returns JSON: { "model": "...", "timeout": N, "max_iterations": N }
# Four tiers by diff line count:
#   <20  lines  → haiku,  300s timeout, 1 iteration  (tiny)
#   <50  lines  → haiku,  600s timeout, 1 iteration  (small)
#   <200 lines  → sonnet, 900s timeout, MAX_PR_REVIEW_ITERATIONS (medium)
#   200+ lines  → sonnet, 1800s timeout, MAX_PR_REVIEW_ITERATIONS (large)
get_pr_review_config() {
    local diff_lines
    diff_lines=$(get_diff_line_count "$BASE_BRANCH")

    if (( diff_lines < 20 )); then
        printf '{"model":"haiku","timeout":300,"max_iterations":1}'
    elif (( diff_lines < 50 )); then
        printf '{"model":"haiku","timeout":600,"max_iterations":1}'
    elif (( diff_lines < 200 )); then
        printf '{"model":"sonnet","timeout":900,"max_iterations":%d}' "$MAX_PR_REVIEW_ITERATIONS"
    else
        printf '{"model":"sonnet","timeout":1800,"max_iterations":%d}' "$MAX_PR_REVIEW_ITERATIONS"
    fi
}

# Determines whether the quality loop should run for a given task size.
# Arguments:
#   $1 - task_size: S | M | L (or other/empty)
# Returns:
#   0 if quality loop should run (M, L, or unknown size — safe default)
#   1 if quality loop should be skipped (S-size tasks only)
should_run_quality_loop() {
    local task_size="$1"
    # Derive from get_max_review_attempts so S/M/L policy lives in one place.
    # Skip the quality loop only when max_attempts == 1 (S-size tasks).
    local max
    max=$(get_max_review_attempts "$task_size")
    if [[ "$max" -eq 1 ]]; then
        return 1
    fi
    return 0
}

# Returns the maximum number of review-and-fix attempts for a given task size.
# Arguments:
#   $1 - task_size: S | M | L (or other/empty)
# Outputs:
#   1 for S-size tasks (simple — one shot)
#   2 for M-size tasks
#   3 for L-size tasks and unknown/empty (safe default matches legacy behaviour)
get_max_review_attempts() {
    local task_size="$1"
    case "$task_size" in
        S) echo 1 ;;
        M) echo 2 ;;
        L) echo 3 ;;
        *)
            log_warn "get_max_review_attempts: unexpected task_size '${task_size}'; defaulting to 3"
            echo 3
            ;;
    esac
}

# Extract size marker (S/M/L) from a task description string.
# Looks for the pattern **(S)**, **(M)**, or **(L)** in the description.
# Arguments:
#   $1 - task description string
# Outputs:
#   S, M, or L if found; empty string otherwise
extract_task_size() {
    local desc="${1:-}"
    if [[ "$desc" =~ \*\*\(([SML])\)\*\* ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

# Count lines changed (added + deleted) on the current branch vs a base branch.
# Uses three-dot diff for merge-base semantics (only branch changes, not base changes).
# Arguments:
#   $1 - base branch (default: main)
# Outputs:
#   Total number of lines changed (insertions + deletions)
get_diff_line_count() {
	local base_branch="${1:-main}"
	local lines
	lines=$(git diff --stat "${base_branch}...HEAD" 2>/dev/null \
		| tail -1 \
		| grep -oE '[0-9]+ insertion|[0-9]+ deletion' \
		| grep -oE '[0-9]+' \
		| paste -sd+ - \
		| bc 2>/dev/null || printf '0')
	printf '%s' "${lines:-0}"
}

# Scale quality loop iterations by diff size.
# Tiny diffs need fewer review passes regardless of task size label.
# Arguments:
#   $1 - number of lines changed
# Outputs:
#   Max iterations (1-5) based on diff size
get_diff_based_max_iterations() {
	local diff_lines="${1:-0}"
	if ((diff_lines < 20)); then
		echo 1
	elif ((diff_lines < 100)); then
		echo 2
	elif ((diff_lines < 300)); then
		echo 3
	else
		echo 5
	fi
}

# Get max quality loop iterations based on task size AND diff size.
# Combines two signals: the task size label (S/M/L) and the actual diff
# line count, taking the MINIMUM of both caps. This prevents unnecessary
# review passes when a large task produces a small diff, or when a small
# task label was applied to a large change.
# S-size tasks skip quality loop entirely (handled by should_run_quality_loop).
# Arguments:
#   $1 - task description (size extracted via extract_task_size)
#   $2 - base branch for diff comparison (default: main)
# Outputs:
#   Number of max iterations (1-5)
get_max_quality_iterations() {
	local task_desc="${1:-}"
	local base_branch="${2:-main}"
	local task_size
	task_size=$(extract_task_size "$task_desc")

	local size_based
	case "$task_size" in
		S) size_based=1 ;;
		M) size_based=2 ;;
		L) size_based=3 ;;
		*) size_based=3 ;;
	esac

	local diff_lines
	diff_lines=$(get_diff_line_count "$base_branch")
	local diff_based
	diff_based=$(get_diff_based_max_iterations "$diff_lines")

	# Take the minimum — small diffs don't need many passes even for L tasks
	if ((diff_based < size_based)); then
		echo "$diff_based"
	else
		echo "$size_based"
	fi
}

# =============================================================================
# PROMPT FILE-LIST BUILDER
# =============================================================================
#
# Formats a list of file paths into the "LIKELY AFFECTED FILES:" block that
# is injected into the implement-task prompt.  Keeping this in a named
# function makes it testable in isolation.
#
# Arguments:
#   $@ - zero or more file paths
# Outputs:
#   A leading newline when no files are provided (preserves blank-line
#   separator in prompt).  A "LIKELY AFFECTED FILES:" section listing
#   deduplicated, sorted file paths when one or more are provided.
#
build_files_block() {
    local block=$'\n'
    if [[ $# -gt 0 ]]; then
        local deduped
        deduped=$(printf '%s\n' "$@" | sort -u)
        block=$'\nLIKELY AFFECTED FILES:\n'
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] && block+="- $f"$'\n'
        done <<< "$deduped"
    fi
    printf '%s' "$block"
}

# =============================================================================
# TEST LOOP HELPER
# =============================================================================

# Check whether a file path matches any pattern in FRONTEND_PATH_PATTERNS.
# Each pattern is a simple glob matched via bash case (supports * and ?).
# Arguments:
#   $1 - file path to check
# Returns:
#   0 if the file matches a frontend pattern
#   1 if no match or FRONTEND_PATH_PATTERNS is empty
_matches_frontend_pattern() {
    local file="$1"

    if [[ -z "${FRONTEND_PATH_PATTERNS:-}" ]]; then
        return 1
    fi

    local pattern
    local IFS='|'
    for pattern in $FRONTEND_PATH_PATTERNS; do
        # shellcheck disable=SC2254
        case "$file" in
            $pattern) return 0 ;;
        esac
    done

    return 1
}

# Filter a newline-delimited file list to only implementation-relevant files.
# Excludes .claude/ pipeline files, docs/, and non-code config files from the
# list passed to the test validation prompt.
# Arguments:
#   stdin - newline-delimited file list
# Outputs:
#   Filtered file list (newline-delimited)
filter_implementation_files() {
    grep -v -E '^\.claude/' \
    | grep -v -E '^docs/' \
    | grep -v -E '\.(md|json|yaml|yml|toml|lock|gitignore)$' \
    || true
}

# Check if a file is a Playwright spec (lives in tests/e2e/ or similar E2E directories).
# Arguments:
#   $1 - file path
# Returns:
#   0 if Playwright spec, 1 otherwise
_is_playwright_spec() {
    local file="$1"
    case "$file" in
        tests/e2e/*.spec.*|test/e2e/*.spec.*|e2e/*.spec.*|**/e2e/*.spec.*) return 0 ;;
    esac
    return 1
}

# Detect the scope of changes on the current branch vs the base branch.
# Classifies changed files by extension to determine which test suite to run.
# Arguments:
#   $1 - working directory
#   $2 - base branch to diff against
# Outputs:
#   One of: typescript | bash | config | mixed | frontend | ts-frontend
detect_change_scope() {
    local work_dir="$1"
    local base="$2"

    local changed_files
    # Three-dot diff ($base...HEAD) uses merge-base semantics: compares HEAD against
    # the common ancestor of $base and HEAD, so we only see files changed on this branch
    # (not files changed on $base since the branch point).
    changed_files=$(git -C "$work_dir" diff "$base"...HEAD --name-only 2>/dev/null || true)

    if [[ -z "$changed_files" ]]; then
        log_warn "detect_change_scope: no changed files found vs '$base' — check BASE_BRANCH configuration"
        echo "config"
        return 0
    fi

    local has_ts=false
    local has_bash=false
    local has_other_code=false
    local has_frontend=false

    while IFS= read -r file; do
        # Check frontend pattern match (before extension classification)
        if _matches_frontend_pattern "$file"; then
            has_frontend=true
        fi

        case "$file" in
            *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) has_ts=true ;;
            # Pipeline files (.claude/) are not application bash — skip them
            .claude/*.sh|.claude/*.bats) ;;
            *.sh|*.bats) has_bash=true ;;
            # Config/docs: no tests needed
            *.md|*.json|*.yaml|*.yml|*.toml|*.env|*.lock|*.gitignore) ;;
            # Any other extension (css, sql, py, etc.): treat as testable code
            *.*) has_other_code=true ;;
            # Extensionless files (Makefile, Dockerfile, etc.): treat as testable code
            *) has_other_code=true ;;
        esac
    done <<< "$changed_files"

    if [[ "$has_ts" == "true" && "$has_bash" == "true" ]]; then
        echo "mixed"
    elif [[ "$has_ts" == "true" && "$has_frontend" == "true" ]]; then
        echo "ts-frontend"
    elif [[ "$has_ts" == "true" ]]; then
        echo "typescript"
    elif [[ "$has_frontend" == "true" ]]; then
        # Only frontend files (CSS, etc.) without TS — still need E2E
        echo "frontend"
    elif [[ "$has_bash" == "true" ]]; then
        echo "bash"
    elif [[ "$has_other_code" == "true" ]]; then
        # Unknown code files — run full test suite to be safe
        echo "typescript"
    else
        echo "config"
    fi

    return 0
}

# Checks whether every failure in a JSON failures array is caused by an
# environment infrastructure error (Redis, database connection, HTTP 500,
# network timeouts, etc.) rather than a code-level defect.
#
# When ALL failures are environment-related, dispatching a fix agent is
# pointless — no code change can resolve infrastructure unavailability.
#
# Arguments:
#   $1 - JSON array of failure objects with "test" and "message" fields
# Returns:
#   0 if every failure matches an environment pattern (skip fix dispatch)
#   1 if any failure is code-level (fix dispatch should proceed)
all_failures_environment_related() {
	local failures_json="$1"
	local count
	count=$(printf '%s' "$failures_json" \
		| jq 'length // 0' 2>/dev/null || echo 0)
	if (( count == 0 )); then
		return 1
	fi
	# Count failures whose message does NOT match any known environment-error
	# pattern.  If that count is zero every failure is an infrastructure issue
	# and we should skip the fix agent.  Only the message field is checked —
	# matching the test name would cause false positives for tests whose names
	# happen to contain infrastructure keywords (e.g. "redis-retry-logic").
	local non_env_count
	local env_pattern
	env_pattern='redis|ECONNREFUSED|connection refused|HTTP 500'
	env_pattern+='|database connection|socket hang up'
	env_pattern+='|ETIMEDOUT|ENOTFOUND|connect timeout|ECONNRESET'
	non_env_count=$(printf '%s' "$failures_json" \
		| jq --arg pat "$env_pattern" '
			[.[] | select(
				((.message // ""))
				| test($pat; "i")
				| not
			)] | length
		' 2>/dev/null || echo 1)
	(( non_env_count == 0 ))
}

# Run the test loop (test+validate -> fix, repeat until pass)
# Called once after all tasks complete
# Flow:
#   1. Run tests AND validate comprehensiveness in a single stage (default agent)
#   2. If tests fail: fix with task agent, loop
#   3. If tests pass but validation fails: fix with task agent, loop
#   4. If tests pass and validation passes: done
# Arguments:
#   $1 - working directory
#   $2 - branch name
#   $3 - agent to use for fix stages (optional, falls back to global $AGENT)
#   $4 - pre-computed change scope (optional; computed via detect_change_scope if omitted)
#   $5 - complexity hint for model selection (S/M/L, optional)
# Returns:
#   0 on success (tests pass and validated)
#   0 on convergence soft exit (loop_complete=true, pipeline continues)
#   2 on max iterations exceeded (calls exit 2)
run_test_loop() {
    local loop_dir="$1"
    local loop_branch="$2"
    local loop_agent="${3:-$AGENT}"
    local loop_complexity="${5:-}"

    local loop_complete=false
    local test_iteration=0
    local validation_fix_iteration=0

    log "Starting test loop after all tasks complete"

    # -------------------------------------------------------------------------
    # SMART TEST TARGETING: detect what changed and route accordingly
    # Use pre-computed scope if provided (avoids duplicate detect_change_scope call).
    # -------------------------------------------------------------------------
    local change_scope
    if [[ -n "${4:-}" ]]; then
        case "${4}" in
            typescript|bash|config|mixed|frontend|ts-frontend) change_scope="$4" ;;
            *) log_warn "Invalid pre-computed scope '${4}'; recomputing"
               change_scope=$(detect_change_scope "$loop_dir" "$BASE_BRANCH") ;;
        esac
        log "Using pre-computed change scope: $change_scope"
    else
        change_scope=$(detect_change_scope "$loop_dir" "$BASE_BRANCH")
        log "Detected change scope: $change_scope"
    fi

    if [[ "$change_scope" == "config" ]]; then
        log "Config/markdown-only changes detected — skipping test loop"
        comment_issue "Test Loop: Skipped" "⏭️ No testable code changes detected (config/markdown only). Skipping test loop." "default"
        return 0
    fi

    # Build the test command based on scope
    local test_command bash_test_command
    # Determine bash test command: prefer run-tests.sh if it exists, else bats directly
    if [[ -f "$loop_dir/.claude/scripts/implement-issue-test/run-tests.sh" ]]; then
        bash_test_command="bash .claude/scripts/implement-issue-test/run-tests.sh"
    else
        bash_test_command="bats .claude/scripts/implement-issue-test/*.bats"
    fi

    local safe_dir safe_branch
    safe_dir=$(printf '%q' "$loop_dir")
    safe_branch=$(printf '%q' "$BASE_BRANCH")

    # Compute explicit changed test files (three-dot merge-base diff).
    # Pass them directly to Jest instead of relying on --changedSince's
    # dependency graph, which can miss or over-include files.
    # Exclude .integration.test.ts files (run separately).
    # Split into Jest unit tests vs Playwright E2E specs.
    local changed_test_files=""
    local jest_test_files=""
    local playwright_test_files=""
    if [[ "$change_scope" == "typescript" || "$change_scope" == "mixed" || "$change_scope" == "ts-frontend" ]]; then
        changed_test_files=$(git -C "$loop_dir" diff "$BASE_BRANCH"...HEAD --name-only 2>/dev/null \
            | grep -E '\.test\.[jt]sx?$|\.spec\.[jt]sx?$' \
            | grep -v '\.integration\.test\.' \
            || true)

        # Split: Playwright specs (in e2e/ directories) vs Jest unit tests
        local file
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            if _is_playwright_spec "$file"; then
                playwright_test_files="${playwright_test_files:+$playwright_test_files
}$file"
            else
                jest_test_files="${jest_test_files:+$jest_test_files
}$file"
            fi
        done <<< "$changed_test_files"

        if [[ -n "$playwright_test_files" ]]; then
            log "Playwright specs detected (excluded from Jest): $(echo "$playwright_test_files" | tr '\n' ' ')"
        fi
    fi

    local jest_command
    if [[ -n "$jest_test_files" ]]; then
        jest_command="npx jest --passWithNoTests $(echo "$jest_test_files" | tr '\n' ' ')"
        log "Explicit Jest test files: $(echo "$jest_test_files" | tr '\n' ' ')"
    else
        jest_command="npx jest --passWithNoTests --changedSince=$safe_branch"
        if [[ -n "$changed_test_files" ]]; then
            log "All changed test files are Playwright specs — falling back to --changedSince=$safe_branch for Jest"
        else
            log "No changed test files found — falling back to --changedSince=$safe_branch"
        fi
    fi

    case "$change_scope" in
        bash)
            test_command="cd $safe_dir && $bash_test_command"
            ;;
        *)
            # typescript, ts-frontend, frontend, mixed: run Jest.
            # Mixed BATS pipeline tests run separately as non-blocking (see bats_section below).
            test_command="cd $safe_dir && $jest_command"
            ;;
    esac

    # Build E2E command when configured and scope includes frontend,
    # OR when Playwright specs were found in the changed files
    local e2e_command=""
    if [[ -n "${TEST_E2E_CMD:-}" ]] && { [[ "$change_scope" == "frontend" || "$change_scope" == "ts-frontend" ]] || [[ -n "$playwright_test_files" ]]; }; then
        e2e_command="$TEST_E2E_CMD"
        log "E2E testing enabled for $change_scope scope: $e2e_command"
    elif [[ -n "$playwright_test_files" && -z "${TEST_E2E_CMD:-}" ]]; then
        log "WARNING: Playwright specs found but TEST_E2E_CMD not configured — Playwright specs will be skipped"
    fi

    local prior_failure_sigs=""
    while [[ "$loop_complete" != "true" ]]; do
        test_iteration=$((test_iteration + 1))
        increment_test_iteration  # Track iteration in status file

        if (( test_iteration > MAX_TEST_ITERATIONS )); then
            log_error "Test loop exceeded max iterations ($MAX_TEST_ITERATIONS)"
            set_final_state "max_iterations_test"
            exit 2
        fi

        log "Test loop iteration $test_iteration/$MAX_TEST_ITERATIONS (scope: $change_scope)"

        # =========================================================================
        # COMBINED TEST EXECUTION + VALIDATION → single stage
        # =========================================================================

        # Compute explicit changed-file list (three-dot merge-base diff) for
        # validation scope. Recomputed each iteration since fix stages may
        # add commits. Filter to implementation-relevant files only —
        # exclude .claude/ pipeline files, docs, and non-code configs.
        local changed_files_raw changed_files
        changed_files_raw=$(git -C "$loop_dir" diff "$BASE_BRANCH"...HEAD --name-only 2>/dev/null || true)
        changed_files=$(printf '%s\n' "$changed_files_raw" | filter_implementation_files)

        # Build BATS section for mixed scope (informational only, non-blocking)
        local bats_section=""
        if [[ "$change_scope" == "mixed" || "$change_scope" == "bash" ]]; then
            bats_section="STEP 1c — PIPELINE BATS TESTS (informational only, non-blocking)
Run the pipeline BATS tests:
cd $safe_dir && $bash_test_command

Report pass/fail. BATS failures are INFORMATIONAL ONLY — they do NOT count as overall test failure.
Include bats_result ('passed', 'failed', or 'skipped') and bats_summary in output.
Do NOT set result to 'failed' based on BATS test failures alone.

"
        fi

        # Build validation section for the combined prompt
        local validation_section=""
        if [[ -n "$changed_files" ]]; then
            validation_section="STEP 2 — TEST VALIDATION (only if all tests passed in Step 1)
If tests failed in Step 1, set validation_result to 'skipped' and skip this step.

Validate test comprehensiveness for issue #$ISSUE_NUMBER.

CHANGED FILES (implementation-relevant only, .claude/ and docs excluded):
$changed_files

ONLY validate tests for these specific files. Do NOT expand scope beyond this list.

IMPORTANT SCOPE CONSTRAINTS:
- If NONE of the changed files contain testable code (e.g., config-only, style-only, docs-only changes), set validation_result to 'passed' immediately. Do NOT request new tests for non-logic changes.
- Only validate tests for modified code files (services, routes, components, hooks, scripts)
- Do NOT request tests for config files, static assets, or type-only changes

PRE-EXISTING ISSUES POLICY:
- If a test file has pre-existing quality issues NOT introduced by this PR, set validation_result to 'passed' and note them under 'pre_existing_issues'.
- Only set validation_result to 'failed' for quality issues directly related to changed files in this PR.

For each modified implementation file that warrants testing, identify the corresponding test file and audit:
1. Check for TODO/FIXME/incomplete tests
2. Check for hollow assertions (expect(true).toBe(true), no assertions)
3. Verify edge cases and error conditions are tested
4. Check for mock abuse patterns

INTEGRATION TEST REQUIREMENT FOR API ROUTES (claude-pipeline#25):
- If ANY changed file is an API route file (matches */routes/*.ts or */routes/*.js), there MUST be
  an integration test that verifies the actual HTTP response shape (not just unit tests of service methods).
- Unit tests that mock the service layer are NOT sufficient for route changes — the Fastify response schema
  can silently strip fields via fast-json-stringify, which unit tests cannot catch.
- If route files were changed but no integration test exists for the changed endpoint(s), set
  validation_result to 'failed' and describe which endpoint(s) lack integration test coverage.
- This is a HARD REQUIREMENT, not a suggestion. Do NOT pass with a note about missing integration tests."
        else
            validation_section="STEP 2 — TEST VALIDATION: SKIPPED
No changed files detected vs $BASE_BRANCH. Set validation_result to 'skipped'."
        fi

        # Build E2E section if applicable
        local e2e_section=""
        if [[ -n "$e2e_command" ]]; then
            e2e_section="STEP 1b — E2E TEST EXECUTION (only if unit tests passed in Step 1)
If tests failed in Step 1, skip this step entirely.

Run the E2E test suite:
$e2e_command

Report pass/fail. E2E failures count as overall test failure (set result to 'failed').
Include e2e_result ('passed', 'failed', or 'skipped') and e2e_summary in output.

"
        fi

        # Build Playwright skip notice if specs were found but no E2E runner configured
        local playwright_notice=""
        if [[ -n "$playwright_test_files" && -z "${TEST_E2E_CMD:-}" ]]; then
            playwright_notice="
NOTE: The following Playwright E2E specs were found in changed files but TEST_E2E_CMD is not configured.
These files are NOT run by Jest — they require a Playwright runner. Skipping them.
Files: $(echo "$playwright_test_files" | tr '\n' ', ')
"
        fi

        local test_prompt="Run the test suite and validate test comprehensiveness in working directory $safe_dir.

STEP 1 — TEST EXECUTION (Jest unit tests)
Run the following command:
$test_command

Report pass/fail with test counts and failure details.
If tests fail, set validation_result to 'skipped' (no point validating failing tests).
${playwright_notice}
${e2e_section}${bats_section}$validation_section

Output both test results and validation findings in one structured response.
- result: 'passed' or 'failed' (from Jest test execution — BATS failures do NOT affect this)
- summary: overall summary suitable for an issue comment
- validation_result: 'passed', 'failed', or 'skipped'
- validation_issues: array of issues found (if any)
- pre_existing_issues: array of pre-existing quality issues (informational only)
- validation_summary: summary of validation findings
- e2e_result: 'passed', 'failed', or 'skipped' (from E2E execution, if applicable)
- e2e_summary: summary of E2E test findings (if applicable)
- bats_result: 'passed', 'failed', or 'skipped' (from BATS pipeline tests, informational only)
- bats_summary: summary of BATS test findings (informational only)"

        local test_result
        test_result=$(run_stage "test-iter-$test_iteration" "$test_prompt" "implement-issue-test-validate.json" "default" "$loop_complexity")

        # Handle timeout: skip result inspection and retry on next iteration
        if is_stage_timeout "$test_result"; then
            log_warn "Test stage timed out on iteration $test_iteration — retrying next iteration"
            comment_issue "Test Loop: Timeout ($test_iteration/$MAX_TEST_ITERATIONS)" "⏱️ Test stage timed out. Retrying on next iteration." "default"
            continue
        fi

        local test_status test_summary
        test_status=$(printf '%s' "$test_result" | jq -r '.result')
        test_summary=$(printf '%s' "$test_result" | jq -r '.summary // "Tests completed"')

        local validate_status validate_summary
        validate_status=$(printf '%s' "$test_result" | jq -r '.validation_result // "skipped"')
        validate_summary=$(printf '%s' "$test_result" | jq -r '.validation_summary // ""')

        # -----------------------------------------------------------------
        # HANDLE TEST FAILURES
        # -----------------------------------------------------------------
        if [[ "$test_status" == "failed" ]]; then
            comment_issue "Test Loop: Tests ($test_iteration/$MAX_TEST_ITERATIONS)" "❌ **Result:** $test_status

$test_summary" "default"
            log "Tests failed. Getting failures and fixing..."
            local failures
            failures=$(printf '%s' "$test_result" | jq -c '.failures')

            # Filter failures: only include failures from PR-changed test files.
            # Explicit mode (changed_test_files non-empty): all failures are from
            # PR-changed files since Jest ran only those files explicitly.
            # Fallback mode (changed_test_files empty, --changedSince used): failures
            # may be from dependency-pulled test files (pre-existing relative to this PR).
            local pr_failures skipped_count
            pr_failures="$failures"
            skipped_count=0
            if [[ -z "$changed_test_files" ]]; then
                skipped_count=$(printf '%s' "$failures" | jq 'length // 0' 2>/dev/null || echo 0)
                if (( skipped_count > 0 )); then
                    log "INFO: Skipping $skipped_count pre-existing failure(s) — failures from --changedSince fallback are not from PR-changed test files"
                    pr_failures="[]"
                fi
            fi

            # If no PR-introduced failures remain, exit test loop gracefully.
            # Pre-existing failures do not block the pipeline (consistent with validation policy).
            local pr_failure_count
            pr_failure_count=$(printf '%s' "$pr_failures" | jq 'length // 0' 2>/dev/null || echo 0)
            if (( pr_failure_count == 0 )); then
                log "INFO: All test failures are pre-existing. Skipping fix-agent dispatch."
                if (( skipped_count > 0 )); then
                    comment_issue "Test Loop: Pre-existing Failures ($test_iteration/$MAX_TEST_ITERATIONS)" \
                        "ℹ️ $skipped_count pre-existing failure(s) detected (not from PR-changed test files). Skipping fix-agent." "default"
                fi
                loop_complete=true
                break
            fi

            # Skip fix agent when every remaining failure is an environment
            # infrastructure error (Redis, DB, HTTP 500, network timeouts).
            # Code changes cannot resolve infrastructure unavailability, so
            # dispatching a fix agent would waste iterations and tokens.
            if all_failures_environment_related "$pr_failures"; then
                log "INFO: All failures are environment-related." \
                    "Skipping fix-agent dispatch."
                local env_title="Test Loop: Environment Errors"
                env_title+=" ($test_iteration/$MAX_TEST_ITERATIONS)"
                local env_body
                env_body="ℹ️ All test failures appear to be"
                env_body+=" environment-related (Redis/DB connection"
                env_body+=" errors, HTTP 500, network timeouts)."
                env_body+=" These require infrastructure fixes, not code"
                env_body+=" changes. Skipping fix-agent."
                comment_issue "$env_title" "$env_body" "default"
                loop_complete=true
                break
            fi

            # Convergence detection: exit early if same PR-scoped failures repeat 2 times
            local failure_sig
            failure_sig=$(printf '%s' "$pr_failures" | md5sum | cut -d' ' -f1)
            prior_failure_sigs="${prior_failure_sigs} ${failure_sig}"
            local sig_count
            sig_count=$(printf '%s' "$prior_failure_sigs" | tr ' ' '\n' | grep -c "^${failure_sig}$" || true)
            if (( sig_count >= 2 )); then
                # Extract failure descriptions for both log and comment message
                local failure_summaries
                failure_summaries=$(printf '%s' "$pr_failures" | jq -r '.[] | "- \(.title): \(.description)"' 2>/dev/null || printf '')
                log_warn "Test-fix convergence failure: same failures repeated $sig_count times. Breaking loop (soft exit).${failure_summaries:+ Failures: ${failure_summaries}}"

                comment_issue "Test Loop: Convergence Failure (soft exit)" "⚠️ Same test failures repeated $sig_count times. Breaking test-fix loop to prevent waste. Pipeline will continue to docs/PR/complete stages.

**Repeated Failures:**
${failure_summaries}

$test_summary" "default"
                set_final_state "test_convergence_soft_exit"
                loop_complete=true
                break
            fi

            local fix_prompt="ENVIRONMENT NOTE: If failures mention Redis/database connection errors, HTTP 500 from route handlers, or similar infrastructure issues, these are environment issues not code bugs. Do NOT attempt to fix these — note them as environment-dependent and focus only on code-level failures.

Fix ONLY the specific test failures listed below. Do NOT rewrite test files, introduce new dependencies, or modify pre-existing test code. Only fix the failing assertions.

Working directory: $safe_dir
Branch: $loop_branch

Failures:
$pr_failures

Fix the issues and commit. Output a summary of fixes applied."

            verify_on_feature_branch "$loop_branch" || true

            local fix_result
            fix_result=$(run_stage "fix-tests-iter-$test_iteration" "$fix_prompt" "implement-issue-fix.json" "$loop_agent" "$loop_complexity")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment: Fix results
            comment_issue "Test Loop: Test Fix ($test_iteration/$MAX_TEST_ITERATIONS)" "$fix_summary" "$loop_agent"
            continue
        fi

        # -----------------------------------------------------------------
        # TESTS PASSED — check validation result
        # -----------------------------------------------------------------
        if [[ "$validate_status" == "passed" || "$validate_status" == "skipped" ]]; then
            comment_issue "Test Loop: Results ($test_iteration/$MAX_TEST_ITERATIONS)" "✅ **Tests:** passed
✅ **Validation:** $validate_status

$test_summary" "default"

            loop_complete=true
            log "Test loop complete on iteration $test_iteration (tests passed, validation: $validate_status)"
        else
            # Validation failed — fix quality issues
            validation_fix_iteration=$((validation_fix_iteration + 1))

            if (( validation_fix_iteration > MAX_VALIDATION_FIX_ITERATIONS )); then
                log_error "Validation fix loop exceeded max iterations ($MAX_VALIDATION_FIX_ITERATIONS)"
                set_final_state "max_iterations_validation_fix"
                exit 2
            fi

            comment_issue "Test Loop: Results ($test_iteration/$MAX_TEST_ITERATIONS)" "✅ **Tests:** passed
🔄 **Validation:** $validate_status

$test_summary

$validate_summary" "default"

            log "Test validation found issues. Fixing... (validation fix iteration $validation_fix_iteration/$MAX_VALIDATION_FIX_ITERATIONS)"
            local validate_issues
            validate_issues=$(printf '%s' "$test_result" | jq -r '
                if .validation_issues then (.validation_issues | tostring)
                elif .validation_summary then .validation_summary
                else "Fix test quality issues"
                end
            ')

            local fix_prompt="Address test quality issues in working directory $safe_dir on branch $loop_branch:

$validate_issues

SCOPE CONSTRAINT: Only fix quality issues in test files that correspond to PR-changed implementation files. Do not modify tests for unrelated implementation files.

Fix the test quality issues (add missing assertions, remove TODOs, add edge case tests, etc.) and commit.
Output a summary of fixes applied."

            verify_on_feature_branch "$loop_branch" || true

            # Pass loop_complexity so run_stage can route model selection by
            # task size: S→haiku, M→sonnet, L→opus (via resolve_model).
            local fix_result
            fix_result=$(run_stage "fix-test-quality-iter-$test_iteration" "$fix_prompt" "implement-issue-fix.json" "$loop_agent" "$loop_complexity")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment: Fix results
            comment_issue "Test Loop: Validation Fix ($test_iteration/$MAX_TEST_ITERATIONS)" "$fix_summary" "$loop_agent"
        fi
    done

    return 0
}

# =============================================================================
# MAIN FLOW
# =============================================================================

main() {
    # Declare local variables used throughout main
    local branch tasks_json task_count completed_tasks max_task_size=""

    # -------------------------------------------------------------------------
    # RESUME VS FRESH START INITIALIZATION
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]]; then
        log "=========================================="
        log "Implement Issue Orchestrator RESUMING"
        log "=========================================="
        log "Issue: #$ISSUE_NUMBER"
        log "Branch: $BRANCH"
        log "Resume stage: $RESUME_STAGE"
        log "Resume task: ${RESUME_TASK:-none}"
        log "Log dir: $LOG_BASE"

        # Use values from resume state
        branch="$BRANCH"
        tasks_json="$RESUME_TASKS_JSON"

        # Update status to indicate resumption
        jq --arg state "running" \
           '.state = $state | .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        sync_status_to_log

        # Comment on issue about resumption
        comment_issue "Resuming Automated Processing" "Resuming processing of issue #$ISSUE_NUMBER.

**Resuming from stage:** \`$RESUME_STAGE\`
**Branch:** \`$branch\`

Log directory: \`$LOG_BASE\`"

    else
        log "=========================================="
        log "Implement Issue Orchestrator Starting"
        log "=========================================="
        log "Issue: #$ISSUE_NUMBER"
        log "Branch: $BASE_BRANCH"
        log "Agent: ${AGENT:-default}"
        log "Log dir: $LOG_BASE"

        init_status

        # -------------------------------------------------------------------------
        # COMMENT #1: Starting automated processing
        # -------------------------------------------------------------------------
        comment_issue "Starting Automated Processing" "Processing issue #$ISSUE_NUMBER against branch \`$BASE_BRANCH\`.

**Stages:**
1. Parse issue (extract tasks from issue body)
2. Validate plan (verify references exist)
3. Implement tasks with self-review (per-task quality loop: simplify, review)
4. Test loop (run tests, fix failures)
5. Documentation
6. Create/update PR
7. PR review loop (combined spec + code review)

Log directory: \`$LOG_BASE\`"
    fi

    # -------------------------------------------------------------------------
    # STAGE: PARSE ISSUE (extract tasks from issue body)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "parse_issue"; then
        log "Skipping parse_issue stage (already completed)"
    else
        set_stage_started "parse_issue"

        log "Fetching issue #$ISSUE_NUMBER..."
        local issue_body
        issue_body=$("$PLATFORM_DIR/read-issue.sh" "$ISSUE_NUMBER" 2>>"${LOG_FILE:-/dev/stderr}" | jq -r '.body')

        if [[ -z "$issue_body" ]]; then
            log_error "Failed to fetch issue #$ISSUE_NUMBER body"
            set_final_state "error"
            exit 1
        fi

        # Save issue body for reference
        printf '%s\n' "$issue_body" > "$LOG_BASE/context/issue-body.md"

        # Extract tasks from ## Implementation Tasks section
        # Format: - [ ] `[agent-name]` Task description
        log "Parsing implementation tasks from issue body..."
        local tasks_section
        tasks_section=$(printf '%s' "$issue_body" | awk '/^## Implementation Tasks/{found=1; next} found && /^## /{exit} found{print}')

        if [[ -z "$tasks_section" ]]; then
            log_error "No '## Implementation Tasks' section found in issue #$ISSUE_NUMBER"
            set_final_state "error"
            exit 1
        fi

        # Parse tasks into JSON array
        # Matches two formats:
        #   GitHub:  - [ ] `[agent]` description  (checkbox syntax)
        #   Jira:    - `[agent]` description       (plain bullet from ADF)
        # Checked boxes [x] are considered already complete and skipped.
        local task_id=0
        tasks_json="[]"
        while IFS= read -r line; do
            if [[ "$line" =~ ^-\ (\[\ \]\ )?\`\[([^\]]+)\]\`\ (.+)$ ]]; then
                task_id=$((task_id + 1))
                local agent="${BASH_REMATCH[2]}"
                local desc="${BASH_REMATCH[3]}"
                tasks_json=$(printf '%s' "$tasks_json" | jq \
                    --argjson id "$task_id" \
                    --arg desc "$desc" \
                    --arg agent "$agent" \
                    '. + [{id: $id, description: $desc, agent: $agent, status: "pending", review_attempts: 0}]')
            fi
        done <<< "$tasks_section"

        local task_count
        task_count=$(printf '%s' "$tasks_json" | jq length)

        if (( task_count == 0 )); then
            log_error "No parseable tasks found in issue #$ISSUE_NUMBER"
            set_final_state "error"
            exit 1
        fi

        log "Extracted $task_count tasks from issue body"
        set_tasks "$tasks_json"
        printf '%s\n' "$tasks_json" > "$LOG_BASE/context/tasks.json"

        # Create or checkout feature branch
        branch="feature/issue-${ISSUE_NUMBER}"
        log "Setting up feature branch: $branch"

        if git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
            log "Branch $branch already exists, checking out"
            git checkout "$branch" 2>/dev/null
        else
            log "Creating branch $branch from $BASE_BRANCH"
            git checkout -b "$branch" "$BASE_BRANCH" 2>/dev/null
        fi

        set_branch_info "$branch"

        set_stage_completed "parse_issue"
        log "Parse issue complete. Branch: $branch, Tasks: $task_count"
    fi

    # -------------------------------------------------------------------------
    # EARLY SCOPE CHECK: config-only bypass
    # If all branch changes are config/doc files only, skip implement/test stages
    # and jump directly to PR creation.
    # Only applies when the branch already has commits (e.g., resuming a branch
    # with config-only changes). A fresh branch with zero commits must proceed
    # to implementation regardless of scope.
    # -------------------------------------------------------------------------
    local early_scope="code"
    local early_commit_count
    early_commit_count=$(git rev-list --count "${BASE_BRANCH}..${branch}" 2>/dev/null || echo "0")

    if (( early_commit_count > 0 )); then
        early_scope=$(detect_change_scope "." "$BASE_BRANCH")
        log "Early scope check: $early_scope (${early_commit_count} commits on branch)"
    else
        log "Early scope check: skipped (fresh branch, 0 commits)"
    fi

    if [[ "$early_scope" == "config" ]]; then
        log "Config-only scope detected — skipping implement/quality/test stages"
        if [[ -z "$RESUME_MODE" ]]; then
            comment_issue "Config-Only Changes Detected" "Config-only changes detected — skipping to PR creation."
        fi
    fi

    # -------------------------------------------------------------------------
    # STAGE: VALIDATE PLAN (lightweight check)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "validate_plan"; then
        log "Skipping validate_plan stage (already completed)"
        # Load tasks from status file for implement stage
        tasks_json=$(jq -c '.tasks' "$STATUS_FILE")
    elif [[ "$early_scope" == "config" ]]; then
        log "Skipping validate_plan stage (config-only scope)"
        set_stage_started "validate_plan"
        set_stage_completed "validate_plan"
    else
        set_stage_started "validate_plan"

        # (c) Validate ## Implementation Tasks section exists in saved issue body
        local issue_body_file="$LOG_BASE/context/issue-body.md"
        if [[ -f "$issue_body_file" ]]; then
            if ! grep -q '^## Implementation Tasks' "$issue_body_file"; then
                log_error "Issue body missing '## Implementation Tasks' section"
                set_final_state "error"
                exit 1
            fi
        else
            log "WARNING: Issue body file not found at $issue_body_file — skipping section check"
        fi

        local task_count
        task_count=$(printf '%s' "$tasks_json" | jq length)

        if (( task_count == 0 )); then
            log_error "No tasks to implement"
            set_final_state "error"
            exit 1
        fi

        # (a) Verify agent names have definitions in .claude/agents/
        local agents_dir="$SCRIPT_DIR/../agents"
        for ((i=0; i<task_count; i++)); do
            local check_agent
            check_agent=$(printf '%s' "$tasks_json" | jq -r ".[$i].agent")
            if [[ ! -f "$agents_dir/${check_agent}.md" ]]; then
                log "WARNING: Task $((i+1)) uses agent '$check_agent' which has no definition in .claude/agents/"
            fi
        done

        # (b) Warn about large task descriptions (>200 chars)
        for ((i=0; i<task_count; i++)); do
            local check_desc
            check_desc=$(printf '%s' "$tasks_json" | jq -r ".[$i].description")
            local desc_len=${#check_desc}
            if (( desc_len > 200 )); then
                log "WARNING: Task $((i+1)) description is $desc_len chars — consider splitting into smaller tasks"
            fi
        done

        # (d) Extract backtick-quoted file paths from issue body and check existence
        if [[ -f "$issue_body_file" ]]; then
            local -a found_paths=()
            local path_match
            while IFS= read -r path_match; do
                [[ -n "$path_match" ]] || continue
                found_paths+=("$path_match")
                if (( ${#found_paths[@]} >= 10 )); then
                    break
                fi
            done < <(grep -oE '`[a-zA-Z0-9_./-]+\.[a-zA-Z]{1,5}`' "$issue_body_file" \
                | sed 's/`//g' \
                | sort -u \
                | head -10)

            for path_match in "${found_paths[@]}"; do
                if [[ ! -e "$path_match" ]]; then
                    log "WARNING: Referenced file path '$path_match' does not exist in the repo"
                fi
            done
        fi

        log "Plan validated: $task_count tasks ready for implementation"

        # Comment: Confirm plan
        local task_list_md=""
        for ((i=0; i<task_count; i++)); do
            local desc agent
            desc=$(printf '%s' "$tasks_json" | jq -r ".[$i].description")
            agent=$(printf '%s' "$tasks_json" | jq -r ".[$i].agent")
            task_list_md="${task_list_md}
$((i+1)). \`[$agent]\` $desc"
        done

        comment_issue "Implementation Plan Confirmed" "Extracted **$task_count tasks** from issue body. Starting implementation.

**Tasks:**
$task_list_md

**Branch:** \`$branch\`"

        set_stage_completed "validate_plan"
        log "Plan validation complete."
    fi

    # -------------------------------------------------------------------------
    # STAGE: IMPLEMENT (per-task loop)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "implement"; then
        log "Skipping implement stage (already completed)"
    elif [[ "$early_scope" == "config" ]]; then
        log "Skipping implement stage (config-only scope)"
        set_stage_started "implement"
        set_stage_completed "implement"
        set_stage_completed "quality_loop"
    else
        set_stage_started "implement"

        task_count=$(printf '%s' "$tasks_json" | jq length)

        # In resume mode, count already completed tasks
        if [[ -n "$RESUME_MODE" ]]; then
            completed_tasks=$(get_completed_task_count)
            log "Resuming implementation: $completed_tasks/$task_count tasks already completed"
        else
            completed_tasks=0
        fi

        for ((i=0; i<task_count; i++)); do
            local task
            task=$(printf '%s' "$tasks_json" | jq ".[$i]")
            local task_id task_desc task_agent task_status task_size
            task_id=$(printf '%s' "$task" | jq -r '.id')
            task_desc=$(printf '%s' "$task" | jq -r '.description')
            task_agent=$(printf '%s' "$task" | jq -r '.agent')
            # Extract size marker from description: **(S)**, **(M)**, **(L)**
            task_size=$(extract_task_size "$task_desc")
            if [[ -z "$task_size" ]]; then
                log_warn "Task $task_id: no size marker found in description — defaulting to max_attempts=3"
            fi

            # Accumulate max-priority complexity: L > M > S.
            # The test loop runs once after all tasks, so it needs the
            # heaviest size to select an appropriately capable model.
            case "$task_size" in
                L) max_task_size="L" ;;
                M) [[ "$max_task_size" != "L" ]] && max_task_size="M" ;;
                S) [[ -z "$max_task_size" ]] && max_task_size="S" ;;
            esac

            # In resume mode, check if this task is already completed
            if [[ -n "$RESUME_MODE" ]]; then
                task_status=$(jq -r ".tasks[] | select(.id == $task_id) | .status" "$STATUS_FILE" 2>/dev/null)
                if [[ "$task_status" == "completed" ]]; then
                    log "Skipping task $task_id (already completed)"
                    continue
                fi
            fi

            log "Implementing task $task_id: $task_desc (agent: $task_agent)"
            update_task "$task_id" "in_progress"

            local max_attempts
            max_attempts=$(get_max_review_attempts "$task_size")
            local review_attempts=0
            local task_succeeded=false

            # Get base timeout and model for graduated retry
            local base_timeout
            base_timeout=$(get_stage_timeout "implement-task-$task_id")
            local base_model
            base_model=$(resolve_model "implement-task-$task_id" "$task_size")

            # Build list of likely affected files for the implement prompt.
            # Sources: (1) paths extracted from task description via regex,
            #          (2) files already modified in this branch.
            local -a affected_files=()
            local f
            while IFS= read -r f; do
                [[ -n "$f" ]] && affected_files+=("$f")
            done < <(
                printf '%s' "$task_desc" \
                    | grep -oE \
                        '[a-zA-Z0-9_.][a-zA-Z0-9_./-]*(/[a-zA-Z0-9_./-]+)+' \
                    2>/dev/null || true
            )
            while IFS= read -r f; do
                [[ -n "$f" ]] && affected_files+=("$f")
            done < <(
                git diff "$BASE_BRANCH"...HEAD --name-only 2>/dev/null || true
            )
            local files_block
            files_block=$(build_files_block "${affected_files[@]+"${affected_files[@]}"}")

            while (( review_attempts < max_attempts )); do
                review_attempts=$((review_attempts + 1))

                # Implement with self-review (eliminates separate task-review invocation)
                local impl_prompt="Implement task $task_id on branch $branch in the current working directory:

$task_desc${files_block}
SELF-REVIEW BEFORE COMMITTING:
After implementing, verify your changes against the task description above:
1. Does your implementation fully achieve the task's goal?
2. Are there any obvious issues, missing edge cases, or incomplete parts?
3. If you find problems, fix them before committing.

Only commit when you are confident the task goal is achieved.
Commit your changes with a descriptive message."

                # On retry after first failure: escalate model and increase timeout by 20%
                local current_timeout="$base_timeout"
                local current_model=""
                if (( review_attempts > 1 )); then
                    # Graduated retry: use next model up and 20% increased timeout
                    current_model=$(_next_model_up "$base_model")
                    current_timeout=$((base_timeout * 120 / 100))
                    log "Task $task_id retry: escalating to $current_model with timeout ${current_timeout}s"
                fi

                local impl_result
                if [[ -n "$current_model" ]]; then
                    # Pass escalated model and increased timeout
                    impl_result=$(run_stage "implement-task-$task_id" "$impl_prompt" "implement-issue-implement.json" "$task_agent" "$task_size" "$current_timeout" "$current_model")
                else
                    # First attempt: use defaults
                    impl_result=$(run_stage "implement-task-$task_id" "$impl_prompt" "implement-issue-implement.json" "$task_agent" "$task_size")
                fi

                local impl_status
                impl_status=$(printf '%s' "$impl_result" | jq -r '.status')

                if [[ "$impl_status" == "success" ]]; then
                    task_succeeded=true
                    break
                fi

                log_warn "Task $task_id attempt $review_attempts/$max_attempts failed"
            done

            if [[ "$task_succeeded" == "true" ]]; then
                update_task "$task_id" "completed" "$review_attempts"
                completed_tasks=$((completed_tasks+1))

                local commit_sha
                commit_sha=$(printf '%s' "$impl_result" | jq -r '.commit')

                local impl_summary
                impl_summary=$(printf '%s' "$impl_result" | jq -r '.summary // "Implementation completed"')
                comment_issue "Task $task_id Complete" "**$task_desc**

**Commit:** \`$commit_sha\`

$impl_summary" "$task_agent"

                # Run quality loop for this task (skipped for S-size tasks)
                if should_run_quality_loop "$task_size"; then
                    local quality_max
                    quality_max=$(get_max_quality_iterations "$task_desc" "$BASE_BRANCH")
                    log "Running quality loop for task $task_id (size: ${task_size:-unknown}, max_iterations: $quality_max)"
                    run_quality_loop "." "$branch" "task-$task_id" "$task_agent" "$quality_max" "$task_size"
                else
                    log "Skipping quality loop for task $task_id (S-size task)"
                fi
            else
                log_error "Task $task_id failed after $review_attempts attempts"
                update_task "$task_id" "failed" "$review_attempts"
            fi

            # Update progress
            jq --arg progress "$completed_tasks/$task_count" \
               '.stages.implement.task_progress = $progress | .last_update = (now | todate)' \
               "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
            sync_status_to_log
        done

        set_stage_completed "implement"
        set_stage_completed "quality_loop"  # Quality loop ran per-task
        log "Implementation complete. $completed_tasks/$task_count tasks completed (with per-task quality loops)."
    fi

    # -------------------------------------------------------------------------
    # CHANGE SCOPE (computed once; shared by test loop and docs stage)
    # -------------------------------------------------------------------------
    local branch_scope
    branch_scope=$(detect_change_scope "." "$BASE_BRANCH")
    log "Branch change scope: $branch_scope"

    # -------------------------------------------------------------------------
    # STAGE: TEST LOOP (after all tasks complete)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "test_loop"; then
        log "Skipping test_loop stage (already completed)"
    elif [[ "$early_scope" == "config" ]]; then
        log "Skipping test_loop stage (config-only scope)"
        set_stage_started "test_loop"
        set_stage_completed "test_loop"
    else
        set_stage_started "test_loop"
        log "Running test loop after all tasks complete..."

        run_test_loop "." "$branch" "$AGENT" "$branch_scope" "$max_task_size"

        # ---------------------------------------------------------------------
        # NON-BLOCKING FULL-SCOPE CHECK (informational only)
        # After PR tests pass, run jest --changedSince once to surface any
        # pre-existing failures pulled in by the dependency graph.  This does
        # NOT block the pipeline — failures are posted as an informational
        # issue comment so maintainers are aware.
        # ---------------------------------------------------------------------
        if [[ "$branch_scope" == "typescript" || "$branch_scope" == "mixed" || "$branch_scope" == "ts-frontend" ]]; then
            log "Running informational full-scope check (non-blocking)..."
            local full_scope_output full_scope_rc
            full_scope_output=$(cd "." && npx jest --passWithNoTests --changedSince="$BASE_BRANCH" 2>&1) || true
            full_scope_rc=$?

            if (( full_scope_rc != 0 )); then
                local full_scope_failures
                full_scope_failures=$(printf '%s' "$full_scope_output" | tail -40)
                comment_issue "Full-Scope Check: Pre-existing Failures (informational)" \
                    "ℹ️ A full \`jest --changedSince=$BASE_BRANCH\` run found additional failures outside the PR-changed test files. These are **pre-existing** and do **not** block this pipeline.

<details>
<summary>Failure details (last 40 lines)</summary>

\`\`\`
$full_scope_failures
\`\`\`
</details>" "default"
                log "INFO: Full-scope check found pre-existing failures (non-blocking)"
            else
                log "Full-scope check passed — no additional failures"
            fi
        fi

        set_stage_completed "test_loop"
        log "Test loop complete."
    fi

    # -------------------------------------------------------------------------
    # STAGE: E2E VERIFY (Playwright visual/behavioral verification)
    # Runs after unit tests pass. For issues that change frontend UI, dispatches
    # playwright-test-developer to run E2E tests and verify visual/behavioral
    # correctness. Skips when TEST_E2E_CMD is not configured or scope is not
    # frontend/ts-frontend.
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "e2e_verify"; then
        log "Skipping e2e_verify stage (already completed)"
    elif [[ -z "${TEST_E2E_CMD:-}" ]]; then
        log "Skipping e2e_verify stage (TEST_E2E_CMD not configured)"
        set_stage_started "e2e_verify"
        set_stage_completed "e2e_verify"
    elif [[ "$branch_scope" != "frontend" && "$branch_scope" != "ts-frontend" ]]; then
        log "Skipping e2e_verify stage (scope '$branch_scope' is not frontend)"
        set_stage_started "e2e_verify"
        set_stage_completed "e2e_verify"
    else
        set_stage_started "e2e_verify"
        log "Running E2E verification for frontend changes..."

        local e2e_verify_prompt="Run E2E tests to verify the frontend changes for issue #$ISSUE_NUMBER.

TEST COMMAND:
$TEST_E2E_CMD

BASE URL: ${TEST_E2E_BASE_URL:-http://localhost:5173}

INSTRUCTIONS:
1. Run the E2E test suite using the command above
2. If tests fail, report the failures with details about what visual/behavioral issues were found
3. Focus on verifying user-visible behavior: layout, interactions, navigation, visual regressions

Report result as 'passed' or 'failed' with a detailed summary."

        local e2e_verify_result
        e2e_verify_result=$(run_stage "e2e-verify" "$e2e_verify_prompt" "implement-issue-test.json" "playwright-test-developer")

        local e2e_verify_status e2e_verify_summary
        e2e_verify_status=$(printf '%s' "$e2e_verify_result" | jq -r '.result')
        e2e_verify_summary=$(printf '%s' "$e2e_verify_result" | jq -r '.summary // "E2E verification completed"')

        local e2e_icon="✅"
        [[ "$e2e_verify_status" == "failed" ]] && e2e_icon="❌"
        comment_issue "E2E Verification" "$e2e_icon **Result:** $e2e_verify_status

$e2e_verify_summary" "playwright-test-developer"

        if [[ "$e2e_verify_status" == "failed" ]]; then
            log_error "E2E verification failed — dispatching implementation agent to fix"

            local e2e_fix_prompt="E2E tests for issue #$ISSUE_NUMBER FAILED. The unit tests passed but E2E tests found visual/behavioral issues.

Failure details:
$e2e_verify_summary

Fix the frontend code to resolve these E2E failures. Do NOT modify the test files — fix the implementation code.
Commit your changes."

            verify_on_feature_branch "$branch" || true

            local e2e_fix_result
            e2e_fix_result=$(run_stage "fix-e2e" "$e2e_fix_prompt" "implement-issue-fix.json" "$AGENT" "$max_task_size")

            local e2e_fix_summary
            e2e_fix_summary=$(printf '%s' "$e2e_fix_result" | jq -r '.summary // "Fix applied"')
            comment_issue "E2E Fix" "$e2e_fix_summary" "$AGENT"
        fi

        set_stage_completed "e2e_verify"
    fi

    # -------------------------------------------------------------------------
    # STAGE: ACCEPTANCE TEST (verify fix works against running services)
    # Runs after unit tests pass.  For issues that change API routes, hits the
    # actual endpoint in Docker and verifies the response shape matches the
    # issue's acceptance criteria.  Skips gracefully if Docker is unavailable.
    # Added in claude-pipeline#25 to prevent "unit tests pass but fix is broken".
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "acceptance_test"; then
        log "Skipping acceptance_test stage (already completed)"
    else
        set_stage_started "acceptance_test"

        # Check if any changed files are API route files
        local changed_route_files
        changed_route_files=$(git diff "$BASE_BRANCH"...HEAD --name-only -- '*/routes/*.ts' '*/routes/*.js' 2>/dev/null || true)

        if [[ -z "$changed_route_files" ]]; then
            log "No API route files changed — skipping acceptance test"
            comment_issue "Acceptance Test: Skipped" "⏭️ No API route files changed. Skipping endpoint verification." "default"
        elif ! command -v docker &>/dev/null && ! command -v docker-compose &>/dev/null; then
            log_warn "Docker not available — skipping acceptance test"
            comment_issue "Acceptance Test: Skipped" "⚠️ Docker not available. Endpoint verification skipped. Manual verification recommended before merge." "default"
        else
            log "API route files changed — running acceptance test"
            log "Changed routes: $changed_route_files"

            local acceptance_prompt="Verify the fix for issue #$ISSUE_NUMBER works against running services.

CHANGED API ROUTE FILES:
$changed_route_files

ACCEPTANCE CRITERIA (from issue):
$("$PLATFORM_DIR/read-issue.sh" "$ISSUE_NUMBER" 2>/dev/null | jq -r '.body' | awk '/^## Acceptance Criteria/{found=1; next} found && /^## /{exit} found{print}')

STEPS:
1. Check if Docker containers are running (docker compose ps or docker-compose ps)
2. If containers are not running, try to start them (docker compose up -d) — if this fails, skip with a warning
3. For each changed route file, identify the endpoint(s) that were modified
4. Hit each modified endpoint with a real HTTP request (use curl or node http module from inside the container)
5. Verify the response shape matches what the acceptance criteria expect
6. If the response is wrong, report 'failed' with details about what was expected vs actual

Output result as 'passed' or 'failed' with a detailed summary."

            local acceptance_result
            acceptance_result=$(run_stage "acceptance-test" "$acceptance_prompt" "implement-issue-test.json" "default")

            local acceptance_status acceptance_summary
            acceptance_status=$(printf '%s' "$acceptance_result" | jq -r '.result')
            acceptance_summary=$(printf '%s' "$acceptance_result" | jq -r '.summary // "Acceptance test completed"')

            local acceptance_icon="✅"
            [[ "$acceptance_status" == "failed" ]] && acceptance_icon="❌"
            comment_issue "Acceptance Test" "$acceptance_icon **Result:** $acceptance_status

$acceptance_summary" "default"

            if [[ "$acceptance_status" == "failed" ]]; then
                log_error "Acceptance test failed — fix does not work against running services"

                # Give the implementation agent a chance to fix
                local acceptance_fix_prompt="The acceptance test for issue #$ISSUE_NUMBER FAILED. The unit tests passed but the fix does not work when tested against the actual running endpoint.

Failure details:
$acceptance_summary

Common causes:
- Response field names don't match what the frontend/consumer expects
- Fastify response schema strips fields via fast-json-stringify
- Docker container running stale code (may need rebuild)
- Database migration not applied

Investigate the root cause and fix the issue. Commit your changes."

                verify_on_feature_branch "$branch" || true

                local acceptance_fix_result
                acceptance_fix_result=$(run_stage "fix-acceptance-test" "$acceptance_fix_prompt" "implement-issue-fix.json" "$AGENT")

                local acceptance_fix_summary
                acceptance_fix_summary=$(printf '%s' "$acceptance_fix_result" | jq -r '.summary // "Fix applied"')
                comment_issue "Acceptance Test Fix" "$acceptance_fix_summary" "$AGENT"
            fi
        fi

        set_stage_completed "acceptance_test"
    fi

    # -------------------------------------------------------------------------
    # STAGE: DEPLOY VERIFY
    # Deploys to a configured target environment (test/nas/staging) and polls
    # the health URL until the service is live, then runs a verification prompt
    # against the deployed environment.
    # Gated on: (a) DEPLOY_VERIFY_CMD set in platform.sh, AND
    #           (b) issue has env:test/env:nas/env:staging label OR body
    #               contains a "## Deploy Verification" section.
    # Added in claude-pipeline#64.
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "deploy_verify"; then
        log "Skipping deploy_verify stage (already completed)"
    else
        if ! should_run_deploy_verify "$ISSUE_NUMBER"; then
            log "Skipping deploy_verify stage: gate conditions not met"
            set_stage_started "deploy_verify"
            if [[ -n "${DEPLOY_VERIFY_CMD:-}" ]]; then
                comment_issue "Deploy Verify: Skipped" \
                    "⏭️ Deploy verification skipped (no \`env:*\` label or \`## Deploy Verification\` section found)." \
                    "default"
            fi
            set_stage_completed "deploy_verify"
        else
            set_stage_started "deploy_verify"
            log "Triggering deploy via: $DEPLOY_VERIFY_CMD"
            comment_issue "Deploy Verify: Deploying" \
                "🚀 Triggering deployment via \`$DEPLOY_VERIFY_CMD\`..." \
                "default"

            # Run the deploy command
            local deploy_exit=0
            if ! bash -c "$DEPLOY_VERIFY_CMD" >>"${LOG_FILE:-/dev/null}" 2>&1; then
                deploy_exit=1
            fi

            if ((deploy_exit != 0)); then
                log_error "Deploy command failed (exit $deploy_exit)"
                comment_issue "Deploy Verify: Failed" \
                    "❌ Deploy command \`$DEPLOY_VERIFY_CMD\` exited with code $deploy_exit. Skipping health poll and verification." \
                    "default"
                # Deploy failure is intentionally non-blocking: the pipeline continues
                # to the PR stage so the work is not lost. The failure surfaces via
                # the issue comment above; no retry loop is triggered.
                set_stage_completed "deploy_verify"
            else
                log "Deploy command succeeded"

                # Poll health URL if configured; poll_health_url returns 0 if the
                # URL is empty (skip = healthy) or a 2xx response is received.
                local poll_interval=10
                local max_retries=$(( ${DEPLOY_VERIFY_TIMEOUT_SECS:-900} / poll_interval ))
                local health_ok=false
                if [[ -n "${DEPLOY_VERIFY_HEALTH_URL:-}" ]]; then
                    log "Polling health URL: $DEPLOY_VERIFY_HEALTH_URL (${poll_interval}s intervals, $max_retries retries max)"
                else
                    log "No DEPLOY_VERIFY_HEALTH_URL configured — skipping health poll"
                fi
                if poll_health_url "${DEPLOY_VERIFY_HEALTH_URL:-}" "$max_retries" "$poll_interval"; then
                    health_ok=true
                else
                    log_error "Health check failed after $max_retries attempts ($(( max_retries * poll_interval / 60 )) min)"
                    comment_issue "Deploy Verify: Health Timeout" \
                        "❌ Health endpoint \`$DEPLOY_VERIFY_HEALTH_URL\` did not return 2xx after $max_retries attempts ($(( max_retries * poll_interval / 60 )) min). Deployment may have failed." \
                        "default"
                    set_stage_completed "deploy_verify"
                fi

                # Run verification prompt if health is OK
                if $health_ok; then
                    log "Running deploy verification prompt"

                    # Extract Deploy Verification section from issue body
                    local deploy_verify_section=""
                    local issue_body_file="$LOG_BASE/context/issue-body.md"
                    if [[ -f "$issue_body_file" ]]; then
                        deploy_verify_section=$(awk '/^## Deploy Verification/{found=1; next} found && /^## /{exit} found{print}' "$issue_body_file")
                    fi

                    local deploy_verify_prompt="Verify the deployment for issue #$ISSUE_NUMBER against the live environment.

DEPLOYED ENVIRONMENT:
- Deploy command: $DEPLOY_VERIFY_CMD
- Health URL: ${DEPLOY_VERIFY_HEALTH_URL:-N/A}
- Health status: passed

ISSUE ACCEPTANCE CRITERIA:
$(awk '/^## Acceptance Criteria/{found=1; next} found && /^## /{exit} found{print}' "$issue_body_file" 2>/dev/null || printf '%s' '(not found)')

DEPLOY VERIFICATION INSTRUCTIONS:
${deploy_verify_section:-No specific deploy verification instructions in the issue. Verify the deployment is functional by checking health endpoints and basic functionality.}

STEPS:
1. Confirm the health endpoint returns a 2xx response
2. Test the key functionality described in the acceptance criteria against the live URL
3. Check for any error logs or degraded behavior
4. Report status as 'success', 'error', or 'partial' with a detailed summary"

                    local deploy_verify_result
                    deploy_verify_result=$(run_stage "deploy-verify" "$deploy_verify_prompt" "implement-issue-deploy-verify.json" "default")

                    local dv_status dv_health dv_summary
                    dv_status=$(printf '%s' "$deploy_verify_result" | jq -r '.status // "unknown"')
                    dv_health=$(printf '%s' "$deploy_verify_result" | jq -r '.health_status // "unknown"')
                    dv_summary=$(printf '%s' "$deploy_verify_result" | jq -r '.summary // "Deploy verification completed"')

                    local dv_icon="✅"
                    [[ "$dv_status" == "error" ]] && dv_icon="❌"
                    [[ "$dv_status" == "partial" ]] && dv_icon="⚠️"

                    comment_issue "Deploy Verify" "$dv_icon **Status:** $dv_status | **Health:** $dv_health

$dv_summary" "default"

                    if [[ "$dv_status" == "error" ]]; then
                        log_error "Deploy verification failed"
                    else
                        log "Deploy verification: $dv_status"
                    fi

                    set_stage_completed "deploy_verify"
                fi
            fi
        fi
    fi

    # -------------------------------------------------------------------------
    # Pre-compute modified TypeScript files before docs stage
    # -------------------------------------------------------------------------
    local modified_ts_files
    modified_ts_files=$(git diff "$BASE_BRANCH"...HEAD --name-only -- '*.ts' '*.tsx' 2>/dev/null | grep -E '^(apps|packages)/' | sort)

    # Format the file list for the prompt
    local files_for_prompt
    if [[ -n "$modified_ts_files" ]]; then
        files_for_prompt=$(printf '%s' "$modified_ts_files" | sed 's/^/- /')
    else
        files_for_prompt="(no TypeScript files modified)"
    fi

    # -------------------------------------------------------------------------
    # STAGE: DOCS
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "docs"; then
        log "Skipping docs stage (already completed)"
    else
        if ! should_run_docs_stage "$branch_scope"; then
            log "Skipping docs stage: no TypeScript/React files changed (scope: $branch_scope)"
            set_stage_started "docs"
            comment_issue "Docs Stage: Skipped" "⏭️ No TypeScript/React files changed (scope: \`$branch_scope\`). Skipping docs stage."
            set_stage_completed "docs"
        elif all_tasks_s_complexity; then
            log "Skipping docs stage: all tasks are S-complexity"
            set_stage_started "docs"
            comment_issue "Docs Stage: Skipped" "⏭️ All tasks are S-complexity. Skipping docs stage."
            set_stage_completed "docs"
        else
            set_stage_started "docs"

            local docs_prompt="Write JSDoc/TSDoc comments for all modified TypeScript files on branch $branch in the current working directory.

Modified TypeScript files:
$files_for_prompt

Add comprehensive JSDoc/TSDoc comments and commit with message: docs(issue-$ISSUE_NUMBER): add JSDoc comments"
            run_stage "docs" "$docs_prompt" "implement-issue-implement.json" "default"

            set_stage_completed "docs"
        fi
    fi

    # -------------------------------------------------------------------------
    # STAGE: PR
    # -------------------------------------------------------------------------
    local pr_number

    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "pr"; then
        log "Skipping PR creation stage (already completed)"
        # Load PR number from status
        pr_number=$(jq -r '.stages.pr.pr_number // empty' "$STATUS_FILE")
        if [[ -z "$pr_number" || "$pr_number" == "null" ]]; then
            log_error "PR stage marked complete but no PR number found in status"
            set_final_state "error"
            exit 1
        fi
        log "Using existing PR #$pr_number"
    else
        set_stage_started "pr"

        local pr_prompt="Create a merge request for issue #$ISSUE_NUMBER.

Run this exact command (substitute a short description for <description>):

git push -u origin $branch 2>/dev/null; $PLATFORM_DIR/create-mr.sh --source '$branch' --target '$BASE_BRANCH' --title 'feat(issue-$ISSUE_NUMBER): <description>' --body 'Closes #$ISSUE_NUMBER'

The command will output the MR number. Use that as pr_number in your response."

        local pr_result
        pr_result=$(run_stage "pr" "$pr_prompt" "implement-issue-pr.json")

        local pr_status
        pr_status=$(printf '%s' "$pr_result" | jq -r '.status')
        pr_number=$(printf '%s' "$pr_result" | jq -r '.pr_number')

        if [[ "$pr_status" != "success" ]]; then
            log_error "PR creation failed"
            set_final_state "error"
            exit 1
        fi

        # Validate pr_number is present; recover via find-mr.sh if missing
        if [[ -z "$pr_number" || "$pr_number" == "null" || ! "$pr_number" =~ ^[0-9]+$ ]]; then
            log_warn "PR number missing or invalid from structured output (got: '$pr_number') — recovering via find-mr.sh"
            pr_number=$("$PLATFORM_DIR/find-mr.sh" --branch "$branch" 2>/dev/null || true)
            if [[ -z "$pr_number" || "$pr_number" == "null" ]]; then
                log_warn "find-mr.sh recovery failed — trying gh pr list fallback"
                pr_number=$(gh pr list --head "$branch" --json number -q '.[0].number' 2>/dev/null || true)
                if [[ -z "$pr_number" || "$pr_number" == "null" ]]; then
                    log_error "Could not recover PR/MR number from find-mr.sh or gh pr list for branch '$branch'"
                    set_final_state "error"
                    exit 1
                fi
                log "Recovered PR/MR #$pr_number from gh pr list"
            else
                log "Recovered PR/MR #$pr_number from find-mr.sh"
            fi
        fi

        log "PR #$pr_number created/updated"

        # Store PR info in status
        jq --argjson pr "$pr_number" \
           '.stages.pr.pr_number = $pr | .last_update = (now | todate)' \
           "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
        sync_status_to_log
        set_stage_completed "pr"
    fi

    # -------------------------------------------------------------------------
    # STAGE: PR REVIEW LOOP
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "pr_review"; then
        log "Skipping pr_review stage (already completed)"
    else
        set_stage_started "pr_review"

        local pr_approved=false

        # Scale PR review by diff size
        local pr_review_config
        pr_review_config=$(get_pr_review_config)
        local pr_review_model pr_review_timeout pr_review_max_iter
        pr_review_model=$(printf '%s' "$pr_review_config" | jq -r '.model')
        pr_review_timeout=$(printf '%s' "$pr_review_config" | jq -r '.timeout')
        pr_review_max_iter=$(printf '%s' "$pr_review_config" | jq -r '.max_iterations')
        local diff_lines
        diff_lines=$(get_diff_line_count "$BASE_BRANCH")
        log "PR review config: model=$pr_review_model, timeout=${pr_review_timeout}s, max_iter=$pr_review_max_iter (diff: ${diff_lines} lines)"

    while [[ "$pr_approved" != "true" ]]; do
        increment_pr_review_iteration
        local pr_iteration
        pr_iteration=$(jq -r '.pr_review_iterations' "$STATUS_FILE")

        if (( pr_iteration > pr_review_max_iter )); then
            log_error "PR review loop exceeded max iterations ($pr_review_max_iter)"
            set_final_state "max_iterations_pr_review"
            exit 2
        fi

        log "PR review iteration $pr_iteration"

        # -------------------------------------------------------------------------
        # COMBINED SPEC + CODE REVIEW → PR comment #11 (single pass)
        # -------------------------------------------------------------------------
        local review_prompt="Review PR #$pr_number for issue #$ISSUE_NUMBER against base $BASE_BRANCH.

Part 1 — Spec Review: Verify the PR achieves the goals of the issue. Check goal achievement, not code quality. Flag scope creep.
Part 2 — Code Review: Review code quality, patterns, standards, and security.

Approve or request changes. Output a summary suitable for an issue comment."

        local review_result
        review_result=$(run_stage "pr-review-iter-$pr_iteration" "$review_prompt" "implement-issue-review.json" "code-reviewer" "" "$pr_review_timeout" "$pr_review_model")

        # Handle timeout: skip result inspection and retry on next iteration
        if is_stage_timeout "$review_result"; then
            log_warn "PR review timed out on iteration $pr_iteration — retrying next iteration"
            comment_pr "$pr_number" "PR Review: Timeout (Iteration $pr_iteration)" "⏱️ Review stage timed out. Retrying on next iteration." "code-reviewer"
            continue
        fi

        local review_verdict review_summary verdict_source
        review_summary=$(printf '%s' "$review_result" | jq -r '.summary // "Review completed"')
        local has_result_field
        has_result_field=$(printf '%s' "$review_result" | jq 'has("result")' 2>/dev/null)

        if [[ "$has_result_field" == "true" ]]; then
            # Structured output available: extract verdict from .result field
            review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
            verdict_source="structured output"
            log "Verdict extracted from structured output: $review_verdict"
        else
            # Fallback: parse verdict from summary text
            verdict_source="fallback text"
            local summary_lower
            summary_lower=$(printf '%s' "$review_summary" | tr '[:upper:]' '[:lower:]')

            # Check for approval keywords
            if grep -qiE '(approved|lgtm|looks good|no issues)' <<< "$summary_lower"; then
                review_verdict="approved"
                log "Verdict parsed from fallback text: approved (matched approval keywords)"
            # Check for rejection keywords
            elif grep -qiE '(changes requested|request changes|must fix|blocking|critical)' <<< "$summary_lower"; then
                review_verdict="changes_requested"
                log "Verdict parsed from fallback text: changes_requested (matched rejection keywords)"
            else
                # Default to changes_requested if ambiguous
                review_verdict="changes_requested"
                log "Verdict parsed from fallback text: changes_requested (ambiguous/default)"
            fi
        fi

        # -------------------------------------------------------------------------
        # MAJOR-ISSUE OVERRIDE: If reviewer said "approved" but flagged major
        # issues, override to changes_requested.  This prevents the pipeline from
        # closing issues that are not actually fixed (see claude-pipeline#25).
        # -------------------------------------------------------------------------
        if [[ "$review_verdict" == "approved" ]]; then
            local major_issue_count
            major_issue_count=$(printf '%s' "$review_result" | jq '[.issues // [] | .[] | select(.severity == "major")] | length' 2>/dev/null || echo "0")
            if (( major_issue_count > 0 )); then
                log_warn "Review verdict was 'approved' but $major_issue_count major issue(s) found — overriding to changes_requested"
                review_verdict="changes_requested"
                local major_descriptions
                major_descriptions=$(printf '%s' "$review_result" | jq -r '[.issues[] | select(.severity == "major") | .description] | join("; ")' 2>/dev/null || echo "")
                review_summary="${review_summary}

⚠️ **Override:** Reviewer approved but $major_issue_count major issue(s) must be resolved first:
${major_descriptions}"
            fi
        fi

        # Comment #11: PR Combined Review Result
        local review_icon="✅"
        [[ "$review_verdict" == "changes_requested" ]] && review_icon="🔄"
        comment_pr "$pr_number" "PR Review (Iteration $pr_iteration)" "$review_icon **Result:** $review_verdict

$review_summary" "code-reviewer"

        if [[ "$review_verdict" == "approved" ]]; then
            pr_approved=true
            log "PR approved on iteration $pr_iteration"
        else
            log "PR review requested changes. Fixing..."

            # Collect feedback
            local review_comments
            review_comments=$(printf '%s' "$review_result" | jq -r '.comments // ""')

            local fix_prompt="Address PR review feedback on branch $branch in the current working directory:

Review feedback:
$review_comments

Fix the issues and commit. Output a summary of fixes applied."

            verify_on_feature_branch "$branch" || true

            local fix_result
            fix_result=$(run_stage "fix-pr-review-iter-$pr_iteration" "$fix_prompt" "implement-issue-fix.json" "$AGENT")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment #12: PR Fix Result
            comment_pr "$pr_number" "PR Review Fix (Iteration $pr_iteration)" "$fix_summary" "$AGENT"

            # Push updates (quality loop skipped — re-review will catch remaining issues)
            log "Pushing updates to PR..."
            git push origin "$branch" 2>/dev/null || log "Warning: Could not push to origin"
        fi
        done

        set_stage_completed "pr_review"
    fi

    # -------------------------------------------------------------------------
    # STAGE: COMPLETE → PR comment #14
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "complete"; then
        log "Workflow already completed"
    else
        set_stage_started "complete"

        local complete_prompt="Generate a completion summary for PR #$pr_number implementing issue #$ISSUE_NUMBER.

Include:
- Issue and branch info
- Decisions made during implementation
- Reviews passed
- Final status

Output a summary suitable for a PR/MR comment."

        local complete_result
        complete_result=$(run_stage "complete" "$complete_prompt" "implement-issue-complete.json")

        local complete_summary
        complete_summary=$(printf '%s' "$complete_result" | jq -r '.summary // "Implementation completed successfully"')

        # Comment #14: Implementation complete
        comment_pr "$pr_number" "Implementation Complete" "Issue #$ISSUE_NUMBER has been implemented!

**Branch:** \`$branch\`
**PR:** #$pr_number

$complete_summary

---
*This PR is ready for human review and merge.*"

        set_stage_completed "complete"
        set_final_state "completed"
    fi

    # Copy final status to log dir
    cp "$STATUS_FILE" "$LOG_BASE/status.json"

    log "=========================================="
    log "Implement Issue Complete"
    log "=========================================="
    log "Issue: #$ISSUE_NUMBER"
    log "PR: #$pr_number"
    log "Branch: $branch"
    log "Status: completed"

    exit 0
}

# Run main
main "$@"
