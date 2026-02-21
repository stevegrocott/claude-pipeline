#!/usr/bin/env bash
#
# implement-issue-orchestrator.sh
# Orchestrates implement-issue workflow via Claude CLI calls per stage
#
# Usage:
#   ./implement-issue-orchestrator.sh --issue 123 --branch test
#   ./implement-issue-orchestrator.sh --issue 123 --branch test --agent fastify-backend-developer
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

# Timeouts and limits
readonly MAX_QUALITY_ITERATIONS=5
readonly MAX_TEST_ITERATIONS=10
# Cap at 2: merged spec+code review per iteration makes each pass thorough
# enough that a 3rd iteration rarely finds new issues, while saving ~15 min.
readonly MAX_PR_REVIEW_ITERATIONS=2
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
# Compound prefixes (test-validate, pr-review) are matched first to avoid
# being swallowed by their shorter generic siblings (test, pr).
#

get_stage_timeout() {
    local stage_name="${1:-}"

    case "$stage_name" in
        test-validate*) printf '%s' 900 ;;
        pr-review*)     printf '%s' 1800 ;;
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
  --issue <number>       GitHub issue number (required for new runs)
  --branch <name>        Base branch for PR (required for new runs)
  --agent <name>         Default agent for setup stage (optional)
  --status-file <path>   Custom status file path (optional)
  --quiet                Suppress all issue comments (no GitHub issue noise)
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
        --argjson issue "$ISSUE_NUMBER" \
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
# GITHUB COMMENT HELPERS
# =============================================================================

# Auto-detect repository: env var > gh CLI > git remote
if [[ -n "${GITHUB_REPO:-}" ]]; then
	REPO="$GITHUB_REPO"
elif REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) && [[ -n "$REPO" ]]; then
	: # REPO already set by command substitution
else
	# Parse from git remote (handles both HTTPS and SSH URLs)
	REPO=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||')
fi

if [[ -z "$REPO" ]]; then
	echo "ERROR: Could not determine GitHub repository." >&2
	echo "Set GITHUB_REPO=owner/repo or run from a repo with a GitHub remote." >&2
	exit 3
fi
log "Using GitHub repository: $REPO"

# comment_issue <title> <body> [agent]
# If agent is provided, shows "Written by `agent`", otherwise "Posted by orchestrator"
# When QUIET=true, this is a no-op — ALL issue comments are suppressed (use --quiet
# for automated runs where GitHub issue noise should be eliminated entirely).
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
	if ! gh issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$comment" 2>>"${LOG_FILE:-/dev/stderr}"; then
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
	if ! gh pr comment "$pr_num" --repo "$REPO" --body "$comment" 2>>"${LOG_FILE:-/dev/stderr}"; then
		log_error "Failed to comment on PR #$pr_num"
	fi
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

    local stage_log="$LOG_BASE/stages/$(next_stage_log "$stage_name")"

    # Validate schema file exists
    if [[ ! -f "$SCHEMA_DIR/$schema_file" ]]; then
        log_error "Schema file not found: $SCHEMA_DIR/$schema_file"
        echo '{"status":"error","error":"schema not found"}'
        return 1
    fi

    local schema
    schema=$(jq -c . "$SCHEMA_DIR/$schema_file")

    # Resolve model and fallback from stage name + complexity hint
    local model fallback_model
    model=$(resolve_model "$stage_name" "$complexity")
    fallback_model=$(_next_model_up "$model")

    log "Running stage: $stage_name"
    log "  Schema: $schema_file"
    log "  Agent: ${agent:-default}"
    log "  Model: $model (fallback: $fallback_model)"
    if [[ -n "$complexity" ]]; then
        log "  Complexity: $complexity"
    fi
    log "  Log: $stage_log"

    local model
    model=$(resolve_model "$stage_name" "$complexity")
    log "  Model: $model"
    if [[ -n "$complexity" ]]; then
        log "  complexity: $complexity"
    fi

    local -a agent_args=()
    if [[ -n "$agent" ]]; then
        agent_args=(--agent "$agent")
    fi

    local stage_timeout
    stage_timeout=$(get_stage_timeout "$stage_name")
    log "  Timeout: ${stage_timeout}s"

    # Pass --fallback-model for resilience (skip if same as primary — CLI rejects duplicates)
    local -a fallback_args=()
    if [[ "$fallback_model" != "$model" ]]; then
        fallback_args=(--fallback-model "$fallback_model")
    fi

    local output
    local exit_code=0

    output=$(timeout "$stage_timeout" env -u CLAUDECODE claude -p "$prompt" \
        ${agent_args[@]+"${agent_args[@]}"} \
        --model "$model" \
        ${fallback_args[@]+"${fallback_args[@]}"} \
        --dangerously-skip-permissions \
        --output-format json \
        --json-schema "$schema" \
        2>&1) || exit_code=$?

    printf '%s\n' "=== $stage_name output ===" >> "$stage_log"
    printf '%s\n' "$output" >> "$stage_log"
    printf '%s\n' "=== exit code: $exit_code ===" >> "$stage_log"

    # Check timeout
    if (( exit_code == 124 )); then
        log_error "Stage $stage_name timed out after ${stage_timeout}s"
        echo '{"status":"error","error":"timeout"}'
        return 1
    fi

    # Check rate limit
    if detect_rate_limit "$output"; then
        handle_rate_limit "$output"
        # Retry
        output=$(timeout "$stage_timeout" env -u CLAUDECODE claude -p "$prompt" \
            ${agent_args[@]+"${agent_args[@]}"} \
            --model "$model" \
            ${fallback_args[@]+"${fallback_args[@]}"} \
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
            printf '%s\n' "$fallback_result"
            return 0
        fi

        log_error "No structured output from $stage_name"
        echo '{"status":"error","error":"no structured output"}'
        return 1
    fi

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
        local simplify_prompt="Simplify modified TypeScript/React files in the current branch in working directory $loop_dir on branch $loop_branch.

IMPORTANT SCOPE CONSTRAINT: This is for issue #$ISSUE_NUMBER. Only simplify code that is directly related to the issue's goals. Do NOT apply unrelated refactoring to files that were only incidentally touched or are outside the issue's focus area.

Get modified files with: git -C $loop_dir diff $BASE_BRANCH...HEAD --name-only -- '*.ts' '*.tsx'

If no TypeScript/React files were modified as part of this issue's implementation, make no changes and report 'No changes to simplify'.

Simplify code for clarity and consistency without changing functionality.
Output a summary of changes made."

        local simplify_result
        simplify_result=$(run_stage "simplify-${stage_prefix}-iter-$loop_iteration" "$simplify_prompt" "implement-issue-simplify.json" "" "$loop_complexity")

        local simplify_summary
        simplify_summary=$(printf '%s' "$simplify_result" | jq -r '.summary // "No changes"')

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

        local review_prompt="Review the code changes for task scope '$stage_prefix' in working directory $loop_dir on branch $loop_branch.

IMPORTANT: This is a task-level quality check within the implementation workflow, NOT a full PR review.
Your job is to verify code quality for the changes made in this task only.

Check:
- Code patterns and standards
- Consistency with codebase conventions
- Potential bugs or issues
- Security concerns

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

        local review_verdict review_summary
        review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
        review_summary=$(printf '%s' "$review_result" | jq -r '.summary // "Review completed"')

        # Append current iteration findings to review history
        local current_issues
        current_issues=$(printf '%s' "$review_result" | jq -c "{iteration: $loop_iteration, issues: (.issues // []), result: .result}" 2>/dev/null)
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
            local repeat_ratio
            repeat_ratio=$(printf '%s' "$review_result" | jq --slurpfile history "$review_history_file" '
                . as $root |
                ($root.issues // []) | length as $current_count |
                if $current_count == 0 then 0
                else
                    [$root.issues[] | .description] as $current |
                    [$history[0][] | .issues[]? | .description] as $prior |
                    [$current[] | select(. as $c | $prior | any(. == $c))] | length as $repeats |
                    ($repeats * 100 / $current_count)
                end
            ' 2>/dev/null || printf '0')

            if (( repeat_ratio > 50 )); then
                log_warn "Quality loop convergence failure: ${repeat_ratio}% of issues are repeats from prior iterations. Exiting loop."
                loop_approved=true
                break
            fi
        fi

        if [[ "$review_verdict" == "approved" ]]; then
            loop_approved=true
            log "Quality loop for $stage_prefix approved on iteration $loop_iteration"
        else
            local review_comments
            review_comments=$(printf '%s' "$review_result" | jq -r '.comments // "No comments"')
            printf '%s\n' "$review_comments" >> "$LOG_BASE/context/review-comments.json"

            local cumulative_findings=""
            if [[ -f "$review_history_file" ]]; then
                cumulative_findings=$(jq -r '
                    [.[] | .issues[]? | .description] | unique | join("\n- ")
                ' "$review_history_file" 2>/dev/null || printf '')
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

            local fix_result
            fix_result=$(run_stage "fix-review-${stage_prefix}-iter-$loop_iteration" "$fix_prompt" "implement-issue-fix.json" "$loop_agent" "$loop_complexity")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')
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
# TEST LOOP HELPER
# =============================================================================

# Detect the scope of changes on the current branch vs the base branch.
# Classifies changed files by extension to determine which test suite to run.
# Arguments:
#   $1 - working directory
#   $2 - base branch to diff against
# Outputs:
#   One of: typescript | bash | config | mixed
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

    while IFS= read -r file; do
        case "$file" in
            *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs) has_ts=true ;;
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
    elif [[ "$has_ts" == "true" ]]; then
        echo "typescript"
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

# Run the test loop (test -> validate -> fix, repeat until pass)
# Called once after all tasks complete
# Flow:
#   1. Run tests (default agent)
#   2. If tests fail: fix with task agent, loop
#   3. If tests pass: validate test quality (default, scoped to issue)
#   4. If validation fails: fix with task agent, loop
#   5. If validation passes: done
# Arguments:
#   $1 - working directory
#   $2 - branch name
#   $3 - agent to use for fix stages (optional, falls back to global $AGENT)
#   $4 - pre-computed change scope (optional; computed via detect_change_scope if omitted)
#   $5 - complexity hint for model selection (S/M/L, optional)
# Returns:
#   0 on success (tests pass and validated)
#   2 on max iterations exceeded (calls exit 2)
run_test_loop() {
    local loop_dir="$1"
    local loop_branch="$2"
    local loop_agent="${3:-$AGENT}"
    local loop_complexity="${5:-}"

    local loop_complete=false
    local test_iteration=0

    log "Starting test loop after all tasks complete"

    # -------------------------------------------------------------------------
    # SMART TEST TARGETING: detect what changed and route accordingly
    # Use pre-computed scope if provided (avoids duplicate detect_change_scope call).
    # -------------------------------------------------------------------------
    local change_scope
    if [[ -n "${4:-}" ]]; then
        case "${4}" in
            typescript|bash|config|mixed) change_scope="$4" ;;
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
    local changed_test_files=""
    if [[ "$change_scope" == "typescript" || "$change_scope" == "mixed" ]]; then
        changed_test_files=$(git -C "$loop_dir" diff "$BASE_BRANCH"...HEAD --name-only 2>/dev/null \
            | grep -E '\.test\.[jt]sx?$|\.spec\.[jt]sx?$' \
            | grep -v '\.integration\.test\.' \
            || true)
    fi

    local jest_command
    if [[ -n "$changed_test_files" ]]; then
        jest_command="npx jest --passWithNoTests $(echo "$changed_test_files" | tr '\n' ' ')"
        log "Explicit changed test files: $(echo "$changed_test_files" | tr '\n' ' ')"
    else
        jest_command="npx jest --passWithNoTests --changedSince=$safe_branch"
        log "No changed test files found — falling back to --changedSince=$safe_branch"
    fi

    case "$change_scope" in
        typescript)
            test_command="cd $safe_dir && $jest_command"
            ;;
        bash)
            test_command="cd $safe_dir && $bash_test_command"
            ;;
        mixed)
            test_command="cd $safe_dir && $jest_command && $bash_test_command"
            ;;
    esac

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

        # -------------------------------------------------------------------------
        # TEST EXECUTION → Issue comment
        # -------------------------------------------------------------------------
        local test_prompt="Run the test suite in working directory $safe_dir:

$test_command

Report pass/fail, test counts, and any failures. Output a summary suitable for a GitHub comment."

        local test_result
        test_result=$(run_stage "test-loop-iter-$test_iteration" "$test_prompt" "implement-issue-test.json" "default" "$loop_complexity")

        # Handle timeout: skip result inspection and retry on next iteration
        if is_stage_timeout "$test_result"; then
            log_warn "Test stage timed out on iteration $test_iteration — retrying next iteration"
            comment_issue "Test Loop: Timeout ($test_iteration/$MAX_TEST_ITERATIONS)" "⏱️ Test stage timed out. Retrying on next iteration." "default"
            continue
        fi

        local test_status test_summary
        test_status=$(printf '%s' "$test_result" | jq -r '.result')
        test_summary=$(printf '%s' "$test_result" | jq -r '.summary // "Tests completed"')

        # Comment: Test results
        local test_icon="✅"
        [[ "$test_status" == "failed" ]] && test_icon="❌"
        comment_issue "Test Loop: Tests ($test_iteration/$MAX_TEST_ITERATIONS)" "$test_icon **Result:** $test_status

$test_summary" "default"

        if [[ "$test_status" == "failed" ]]; then
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

            # Convergence detection: exit early if same PR-scoped failures repeat 3 times
            local failure_sig
            failure_sig=$(printf '%s' "$pr_failures" | md5sum | cut -d' ' -f1)
            prior_failure_sigs="${prior_failure_sigs} ${failure_sig}"
            local sig_count
            sig_count=$(printf '%s' "$prior_failure_sigs" | tr ' ' '\n' | grep -c "^${failure_sig}$" || true)
            if (( sig_count >= 3 )); then
                log_warn "Test-fix convergence failure: same failures repeated $sig_count times. Exiting loop."
                comment_issue "Test Loop: Convergence Failure" "⚠️ Same test failures repeated $sig_count times. Aborting test-fix loop to prevent waste.

$test_summary" "default"
                set_final_state "test_convergence_failure"
                exit 2
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

        # -------------------------------------------------------------------------
        # TEST VALIDATION → Issue comment (only if tests passed)
        # -------------------------------------------------------------------------
        log "Tests passed. Running test validation for issue #$ISSUE_NUMBER..."

        # Compute explicit changed-file list (three-dot merge-base diff, not
        # Jest's --changedSince dependency graph) so the validate agent
        # operates on a deterministic, pre-computed scope.
        local changed_files
        changed_files=$(git -C "$loop_dir" diff "$BASE_BRANCH"...HEAD --name-only 2>/dev/null || true)

        if [[ -z "$changed_files" ]]; then
            log "No changed files detected for validation — skipping"
            comment_issue "Test Loop: Validation Skipped ($test_iteration/$MAX_TEST_ITERATIONS)" \
                "⏭️ No changed files detected vs $BASE_BRANCH. Skipping validation." "default"
            loop_complete=true
            break
        fi

        local validate_prompt="Validate test comprehensiveness and integrity for issue #$ISSUE_NUMBER in working directory $safe_dir.

CHANGED FILES (computed via git diff $safe_branch...HEAD --name-only):
$changed_files

ONLY validate tests for these specific files. Do NOT expand scope beyond this list.

IMPORTANT SCOPE CONSTRAINTS:
- If NONE of the changed files contain testable code (e.g., config-only, style-only, docs-only changes), output 'passed' immediately. Do NOT request new tests for non-logic changes.
- Only validate tests for modified code files (services, routes, components, hooks, scripts)
- Do NOT request tests for config files, static assets, or type-only changes

PRE-EXISTING ISSUES POLICY:
- If a test file has pre-existing quality issues NOT introduced by this PR, report 'passed' and note them separately under a 'pre_existing_issues' key.
- Only report 'failed' for quality issues that are directly related to the changed files in this PR.

For each modified implementation file that warrants testing, identify the corresponding test file and audit:
1. Run the test suite: $test_command
2. Check for TODO/FIXME/incomplete tests
3. Check for hollow assertions (expect(true).toBe(true), no assertions)
4. Verify edge cases and error conditions are tested
5. Check for mock abuse patterns

Output:
- result: 'passed' if tests are comprehensive OR if no testable code was modified, 'failed' if issues found in PR-related code
- issues: array of issues found (if any) — only for code changed in this PR
- pre_existing_issues: array of pre-existing quality issues found in test files not introduced by this PR (informational only)
- summary: suitable for a GitHub comment (note if validation was skipped due to no testable changes)"

        local validate_result
        validate_result=$(run_stage "test-validate-iter-$test_iteration" "$validate_prompt" "implement-issue-review.json" "default" "$loop_complexity")

        # Handle timeout: skip validation and retry on next iteration
        if is_stage_timeout "$validate_result"; then
            log_warn "Test validation timed out on iteration $test_iteration — retrying next iteration"
            comment_issue "Test Loop: Validation Timeout ($test_iteration/$MAX_TEST_ITERATIONS)" "⏱️ Validation stage timed out. Retrying on next iteration." "default"
            continue
        fi

        local validate_status validate_summary
        validate_status=$(printf '%s' "$validate_result" | jq -r '.result')
        validate_summary=$(printf '%s' "$validate_result" | jq -r '.summary // "Validation completed"')

        # Comment: Validation results
        local validate_icon="✅"
        [[ "$validate_status" == "changes_requested" || "$validate_status" == "failed" ]] && validate_icon="🔄"
        comment_issue "Test Loop: Validation ($test_iteration/$MAX_TEST_ITERATIONS)" "$validate_icon **Result:** $validate_status

$validate_summary" "default"

        if [[ "$validate_status" == "approved" || "$validate_status" == "passed" ]]; then
            loop_complete=true
            log "Test loop complete on iteration $test_iteration (tests passed and validated)"
        else
            log "Test validation found issues. Fixing..."
            local validate_comments
            validate_comments=$(printf '%s' "$validate_result" | jq -r '.comments // .summary // "Fix test quality issues"')

            local fix_prompt="Address test quality issues in working directory $safe_dir on branch $loop_branch:

$validate_comments

Fix the test quality issues (add missing assertions, remove TODOs, add edge case tests, etc.) and commit.
Output a summary of fixes applied."

            verify_on_feature_branch "$loop_branch" || true

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
1. Parse issue (extract tasks from GH issue body)
2. Validate plan (verify references exist)
3. Implement tasks with self-review (per-task quality loop: simplify, review)
4. Test loop (run tests, fix failures)
5. Documentation
6. Create/update PR
7. PR review loop (combined spec + code review)

Log directory: \`$LOG_BASE\`"
    fi

    # -------------------------------------------------------------------------
    # STAGE: PARSE ISSUE (extract tasks from GH issue body)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "parse_issue"; then
        log "Skipping parse_issue stage (already completed)"
    else
        set_stage_started "parse_issue"

        log "Fetching issue #$ISSUE_NUMBER from GitHub..."
        local issue_body
        issue_body=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json body -q '.body' 2>>"${LOG_FILE:-/dev/stderr}")

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
        tasks_section=$(printf '%s' "$issue_body" | sed -n '/^## Implementation Tasks/,/^## /p' | sed '$d')

        if [[ -z "$tasks_section" ]]; then
            log_error "No '## Implementation Tasks' section found in issue #$ISSUE_NUMBER"
            set_final_state "error"
            exit 1
        fi

        # Parse tasks into JSON array
        # Regex matches only unchecked boxes: - [ ] `[agent]` description
        # This is intentional — checked boxes [x] are considered already
        # complete and are skipped during parsing.
        local task_id=0
        tasks_json="[]"
        while IFS= read -r line; do
            if [[ "$line" =~ ^-\ \[\ \]\ \`\[([^\]]+)\]\`\ (.+)$ ]]; then
                task_id=$((task_id + 1))
                local agent="${BASH_REMATCH[1]}"
                local desc="${BASH_REMATCH[2]}"
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
    # STAGE: VALIDATE PLAN (lightweight check)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "validate_plan"; then
        log "Skipping validate_plan stage (already completed)"
        # Load tasks from status file for implement stage
        tasks_json=$(jq -c '.tasks' "$STATUS_FILE")
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

            while (( review_attempts < max_attempts )); do
                review_attempts=$((review_attempts + 1))

                # Implement with self-review (eliminates separate task-review invocation)
                local impl_prompt="Implement task $task_id on branch $branch in the current working directory:

$task_desc

SELF-REVIEW BEFORE COMMITTING:
After implementing, verify your changes against the task description above:
1. Does your implementation fully achieve the task's goal?
2. Are there any obvious issues, missing edge cases, or incomplete parts?
3. If you find problems, fix them before committing.

Only commit when you are confident the task goal is achieved.
Commit your changes with a descriptive message."

                local impl_result
                impl_result=$(run_stage "implement-task-$task_id" "$impl_prompt" "implement-issue-implement.json" "$task_agent" "$task_size")

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
    else
        set_stage_started "test_loop"
        log "Running test loop after all tasks complete..."

        run_test_loop "." "$branch" "$AGENT" "$branch_scope" "$max_task_size"

        set_stage_completed "test_loop"
        log "Test loop complete."
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
        else
            set_stage_started "docs"

            local docs_prompt="Write JSDoc/TSDoc comments for all modified TypeScript files on branch $branch in the current working directory.

Get modified files with: git diff $BASE_BRANCH...HEAD --name-only -- '*.ts' '*.tsx' | grep -E '^(apps|packages)/'

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

        local pr_prompt="Create or update PR for issue #$ISSUE_NUMBER.

If no PR exists, create one:
gh pr create --base $BASE_BRANCH --title 'feat(issue-$ISSUE_NUMBER): <description>'

If PR exists, push and comment.

Include 'Closes #$ISSUE_NUMBER' in the body."

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

    while [[ "$pr_approved" != "true" ]]; do
        increment_pr_review_iteration
        local pr_iteration
        pr_iteration=$(jq -r '.pr_review_iterations' "$STATUS_FILE")

        if (( pr_iteration > MAX_PR_REVIEW_ITERATIONS )); then
            log_error "PR review loop exceeded max iterations ($MAX_PR_REVIEW_ITERATIONS)"
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

Approve or request changes. Output a summary suitable for a GitHub comment."

        local review_result
        review_result=$(run_stage "pr-review-iter-$pr_iteration" "$review_prompt" "implement-issue-review.json" "code-reviewer")

        # Handle timeout: skip result inspection and retry on next iteration
        if is_stage_timeout "$review_result"; then
            log_warn "PR review timed out on iteration $pr_iteration — retrying next iteration"
            comment_pr "$pr_number" "PR Review: Timeout (Iteration $pr_iteration)" "⏱️ Review stage timed out. Retrying on next iteration." "code-reviewer"
            continue
        fi

        local review_verdict review_summary
        review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
        review_summary=$(printf '%s' "$review_result" | jq -r '.summary // "Review completed"')

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

Output a summary suitable for a GitHub PR comment."

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
