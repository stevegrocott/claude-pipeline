#!/usr/bin/env bash
#
# implement-issue-orchestrator.sh
# Orchestrates implement-issue workflow via Claude CLI calls per stage
#
# Usage:
#   ./implement-issue-orchestrator.sh --issue 123 --branch test
#   ./implement-issue-orchestrator.sh --issue 123 --branch test --agent my-agent
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

# Timeouts and limits
readonly STAGE_TIMEOUT=3600  # 1 hour per stage
readonly MAX_TASK_REVIEW_ATTEMPTS=3
readonly MAX_QUALITY_ITERATIONS=5
readonly MAX_TEST_ITERATIONS=10
readonly MAX_PR_REVIEW_ITERATIONS=3
readonly RATE_LIMIT_BUFFER=60
readonly RATE_LIMIT_DEFAULT_WAIT=3600

# =============================================================================
# PROJECT PIPELINE CONFIG (.claude-pipeline.json)
# =============================================================================

PIPELINE_CONFIG_FILE=".claude-pipeline.json"
CFG_BUILD_COMMAND=""
CFG_HEALTH_CHECK_URL=""
CFG_HEALTH_CHECK_TIMEOUT=120
CFG_HEALTH_CHECK_INTERVAL=5
CFG_UNIT_TEST_COMMAND=""
CFG_E2E_TEST_COMMAND=""
CFG_PLAYWRIGHT_USE_CLI=false
CFG_PLAYWRIGHT_FORBID_MCP=false

load_pipeline_config() {
    if [[ ! -f "$PIPELINE_CONFIG_FILE" ]]; then
        log "No $PIPELINE_CONFIG_FILE found — using defaults"
        return 0
    fi

    log "Loading pipeline config from $PIPELINE_CONFIG_FILE"

    CFG_BUILD_COMMAND=$(jq -r '.build.command // empty' "$PIPELINE_CONFIG_FILE")
    CFG_HEALTH_CHECK_URL=$(jq -r '.build.health_check_url // empty' "$PIPELINE_CONFIG_FILE")
    CFG_HEALTH_CHECK_TIMEOUT=$(jq -r '.build.health_check_timeout // 120' "$PIPELINE_CONFIG_FILE")
    CFG_HEALTH_CHECK_INTERVAL=$(jq -r '.build.health_check_interval // 5' "$PIPELINE_CONFIG_FILE")
    CFG_UNIT_TEST_COMMAND=$(jq -r '.test.unit_command // empty' "$PIPELINE_CONFIG_FILE")
    CFG_E2E_TEST_COMMAND=$(jq -r '.test.e2e_command // empty' "$PIPELINE_CONFIG_FILE")
    CFG_PLAYWRIGHT_USE_CLI=$(jq -r '.playwright.use_cli // false' "$PIPELINE_CONFIG_FILE")
    CFG_PLAYWRIGHT_FORBID_MCP=$(jq -r '.playwright.forbid_mcp // false' "$PIPELINE_CONFIG_FILE")

    [[ -n "$CFG_BUILD_COMMAND" ]] && log "  Build: $CFG_BUILD_COMMAND"
    [[ -n "$CFG_HEALTH_CHECK_URL" ]] && log "  Health: $CFG_HEALTH_CHECK_URL (timeout: ${CFG_HEALTH_CHECK_TIMEOUT}s)"
    [[ -n "$CFG_UNIT_TEST_COMMAND" ]] && log "  Unit tests: $CFG_UNIT_TEST_COMMAND"
    [[ -n "$CFG_E2E_TEST_COMMAND" ]] && log "  E2E tests: $CFG_E2E_TEST_COMMAND"
    [[ "$CFG_PLAYWRIGHT_USE_CLI" == "true" ]] && log "  Playwright: CLI mode (MCP forbidden: $CFG_PLAYWRIGHT_FORBID_MCP)"
}

# =============================================================================
# PRE-TEST BUILD HOOK
# =============================================================================

# Runs build command and waits for health check if configured
# Returns 0 on success, 1 on failure
run_pre_test_build() {
    if [[ -z "$CFG_BUILD_COMMAND" ]]; then
        log "No build command configured — skipping pre-test build"
        return 0
    fi

    log "Running pre-test build: $CFG_BUILD_COMMAND"
    local build_log="$LOG_BASE/stages/$(next_stage_log "pre-test-build")"

    local build_exit=0
    eval "$CFG_BUILD_COMMAND" >> "$build_log" 2>&1 || build_exit=$?

    if (( build_exit != 0 )); then
        log_error "Pre-test build failed (exit code: $build_exit)"
        log_error "See: $build_log"
        return 1
    fi

    log "Build completed successfully"

    # Health check polling
    if [[ -n "$CFG_HEALTH_CHECK_URL" ]]; then
        log "Waiting for health check: $CFG_HEALTH_CHECK_URL (timeout: ${CFG_HEALTH_CHECK_TIMEOUT}s)"
        local elapsed=0

        while (( elapsed < CFG_HEALTH_CHECK_TIMEOUT )); do
            local http_code
            http_code=$(curl -s -o /dev/null -w '%{http_code}' "$CFG_HEALTH_CHECK_URL" 2>/dev/null || echo "000")

            if [[ "$http_code" == "200" ]]; then
                log "Health check passed (${elapsed}s)"
                return 0
            fi

            sleep "$CFG_HEALTH_CHECK_INTERVAL"
            elapsed=$((elapsed + CFG_HEALTH_CHECK_INTERVAL))
        done

        log_error "Health check timed out after ${CFG_HEALTH_CHECK_TIMEOUT}s"
        return 1
    fi

    return 0
}

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
# ARGUMENT PARSING
# =============================================================================

ISSUE_NUMBER=""
BASE_BRANCH=""
AGENT=""
STATUS_FILE="status.json"
RESUME_MODE=""
RESUME_LOG_DIR=""

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
comment_issue() {
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

    local stage_log="$LOG_BASE/stages/$(next_stage_log "$stage_name")"

    # Validate schema file exists
    if [[ ! -f "$SCHEMA_DIR/$schema_file" ]]; then
        log_error "Schema file not found: $SCHEMA_DIR/$schema_file"
        echo '{"status":"error","error":"schema not found"}'
        return 1
    fi

    local schema
    schema=$(jq -c . "$SCHEMA_DIR/$schema_file")

    log "Running stage: $stage_name"
    log "  Schema: $schema_file"
    log "  Agent: ${agent:-default}"
    log "  Log: $stage_log"

    local -a agent_args=()
    if [[ -n "$agent" ]]; then
        agent_args=(--agent "$agent")
    fi

    local output
    local exit_code=0

    output=$(timeout "$STAGE_TIMEOUT" env -u CLAUDECODE claude -p "$prompt" \
        "${agent_args[@]}" \
        --dangerously-skip-permissions \
        --output-format json \
        --json-schema "$schema" \
        2>&1) || exit_code=$?

    printf '%s\n' "=== $stage_name output ===" >> "$stage_log"
    printf '%s\n' "$output" >> "$stage_log"
    printf '%s\n' "=== exit code: $exit_code ===" >> "$stage_log"

    # Check timeout
    if (( exit_code == 124 )); then
        log_error "Stage $stage_name timed out after ${STAGE_TIMEOUT}s"
        echo '{"status":"error","error":"timeout"}'
        return 1
    fi

    # Check rate limit
    if detect_rate_limit "$output"; then
        handle_rate_limit "$output"
        # Retry
        output=$(timeout "$STAGE_TIMEOUT" env -u CLAUDECODE claude -p "$prompt" \
            "${agent_args[@]}" \
            --dangerously-skip-permissions \
            --output-format json \
            --json-schema "$schema" \
            2>&1) || exit_code=$?

        printf '%s\n' "=== $stage_name retry output ===" >> "$stage_log"
        printf '%s\n' "$output" >> "$stage_log"
    fi

    # Extract structured output
    local structured
    structured=$(printf '%s' "$output" | jq -c '.structured_output // empty' 2>/dev/null)

    if [[ -z "$structured" ]]; then
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
# Returns:
#   0 on success (approved)
#   2 on max iterations exceeded (calls exit 2)
run_quality_loop() {
    local loop_dir="$1"
    local loop_branch="$2"
    local stage_prefix="${3:-main}"
    local loop_agent="${4:-$AGENT}"

    local loop_approved=false
    local loop_iteration=0  # Per-loop counter (resets each call)

    while [[ "$loop_approved" != "true" ]]; do
        loop_iteration=$((loop_iteration + 1))
        increment_quality_iteration  # Global counter for status tracking

        if (( loop_iteration > MAX_QUALITY_ITERATIONS )); then
            log_error "Quality loop for $stage_prefix exceeded max iterations ($MAX_QUALITY_ITERATIONS)"
            set_final_state "max_iterations_quality"
            exit 2
        fi

        log "Quality loop iteration $loop_iteration/$MAX_QUALITY_ITERATIONS (prefix: $stage_prefix)"

        # -------------------------------------------------------------------------
        # SIMPLIFY → Issue comment #7
        # -------------------------------------------------------------------------
        local simplify_prompt="Simplify modified TypeScript/React files in the current branch in working directory $loop_dir on branch $loop_branch.

IMPORTANT SCOPE CONSTRAINT: This is for issue #$ISSUE_NUMBER. Only simplify code that is directly related to the issue's goals. Do NOT apply unrelated refactoring to files that were only incidentally touched or are outside the issue's focus area.

Get modified files with: git -C $loop_dir diff $BASE_BRANCH...HEAD --name-only -- '*.ts' '*.tsx'

If no TypeScript/React files were modified as part of this issue's implementation, make no changes and report 'No changes to simplify'.

Simplify code for clarity and consistency without changing functionality.
Output a summary of changes made."

        local simplify_result
        simplify_result=$(run_stage "simplify-${stage_prefix}-iter-$loop_iteration" "$simplify_prompt" "implement-issue-simplify.json")

        local simplify_summary
        simplify_summary=$(printf '%s' "$simplify_result" | jq -r '.summary // "No changes"')

        # Comment #7: Simplify summary
        comment_issue "Quality Loop [$stage_prefix]: Simplify ($loop_iteration/$MAX_QUALITY_ITERATIONS)" "$simplify_summary"

        # -------------------------------------------------------------------------
        # REVIEW → Issue comment #9
        # -------------------------------------------------------------------------
        local review_prompt="Review the code changes for task scope '$stage_prefix' in working directory $loop_dir on branch $loop_branch.

IMPORTANT: This is a task-level quality check within the implementation workflow, NOT a full PR review.
Your job is to verify code quality for the changes made in this task only.

Check:
- Code patterns and standards
- Consistency with codebase conventions
- Potential bugs or issues
- Security concerns

DO NOT recommend 'approve and merge' - this is not a PR review.
Simply output 'approved' if code quality is acceptable, or 'changes_requested' with specific issues to fix."

        local review_result
        review_result=$(run_stage "review-${stage_prefix}-iter-$loop_iteration" "$review_prompt" "implement-issue-review.json" "code-reviewer")

        local review_verdict review_summary
        review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
        review_summary=$(printf '%s' "$review_result" | jq -r '.summary // "Review completed"')

        # Comment #9: Code review results
        local review_icon="✅"
        [[ "$review_verdict" == "changes_requested" ]] && review_icon="🔄"
        comment_issue "Quality Loop [$stage_prefix]: Code Review ($loop_iteration/$MAX_QUALITY_ITERATIONS)" "$review_icon **Result:** $review_verdict

$review_summary" "code-reviewer"

        if [[ "$review_verdict" == "approved" ]]; then
            loop_approved=true
            log "Quality loop for $stage_prefix approved on iteration $loop_iteration"
        else
            local review_comments
            review_comments=$(printf '%s' "$review_result" | jq -r '.comments // "No comments"')
            printf '%s\n' "$review_comments" >> "$LOG_BASE/context/review-comments.json"

            local fix_prompt="Address code review feedback in working directory $loop_dir on branch $loop_branch:

$review_comments

Fix the issues and commit. Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-review-${stage_prefix}-iter-$loop_iteration" "$fix_prompt" "implement-issue-fix.json" "$loop_agent")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment #10: Fix results (review fix)
            comment_issue "Quality Loop [$stage_prefix]: Review Fix ($loop_iteration/$MAX_QUALITY_ITERATIONS)" "$fix_summary" "$loop_agent"
        fi
    done

    return 0
}

# =============================================================================
# TEST LOOP HELPER
# =============================================================================

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
# Returns:
#   0 on success (tests pass and validated)
#   2 on max iterations exceeded (calls exit 2)
run_test_loop() {
    local loop_dir="$1"
    local loop_branch="$2"
    local loop_agent="${3:-$AGENT}"

    local loop_complete=false
    local test_iteration=0

    log "Starting test loop after all tasks complete"

    while [[ "$loop_complete" != "true" ]]; do
        test_iteration=$((test_iteration + 1))
        increment_test_iteration  # Track iteration in status file

        if (( test_iteration > MAX_TEST_ITERATIONS )); then
            log_error "Test loop exceeded max iterations ($MAX_TEST_ITERATIONS)"
            set_final_state "max_iterations_test"
            exit 2
        fi

        log "Test loop iteration $test_iteration/$MAX_TEST_ITERATIONS"

        # -------------------------------------------------------------------------
        # TEST EXECUTION → Issue comment
        # -------------------------------------------------------------------------
        local unit_cmd="${CFG_UNIT_TEST_COMMAND:-npm test}"
        local e2e_cmd="${CFG_E2E_TEST_COMMAND:-}"
        local mcp_warning=""
        if [[ "$CFG_PLAYWRIGHT_FORBID_MCP" == "true" ]]; then
            mcp_warning="

CRITICAL: Do NOT use Playwright MCP tools (browser_snapshot, browser_click, etc.) for testing.
MCP browser tools burn 5-10x more context tokens than CLI runners.
Always use CLI test commands as specified below."
        fi

        local test_prompt="Run tests in working directory $loop_dir:
$mcp_warning

STEP 1 - UNIT TESTS:
Run: cd $loop_dir && $unit_cmd
Report pass/fail counts."

        if [[ -n "$e2e_cmd" ]]; then
            test_prompt="$test_prompt

STEP 2 - E2E TESTS:
Run: cd $loop_dir && $e2e_cmd
Parse the JSON reporter output for pass/fail/count.
Do NOT use MCP Playwright browser tools. Use the CLI command above."
        fi

        test_prompt="$test_prompt

Output a combined summary suitable for a GitHub comment."

        local test_result
        test_result=$(run_stage "test-loop-iter-$test_iteration" "$test_prompt" "implement-issue-test.json" "default")

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

            local fix_prompt="Fix test failures in working directory $loop_dir on branch $loop_branch:

Failures:
$failures

Fix the issues and commit. Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-tests-iter-$test_iteration" "$fix_prompt" "implement-issue-fix.json" "$loop_agent")

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

        local validate_prompt="Validate test comprehensiveness and integrity for issue #$ISSUE_NUMBER in working directory $loop_dir.
$mcp_warning

SCOPE: Only validate tests related to this issue's implementation. Get modified TypeScript files with:
git -C $loop_dir diff $BASE_BRANCH...HEAD --name-only -- '*.ts' '*.tsx' | grep -E '^(apps|packages)/'

IMPORTANT SCOPE CONSTRAINTS:
- If NO testable TypeScript code was modified (e.g., config-only, style-only changes), output 'passed' immediately. Do NOT request new tests for non-logic changes.
- Only validate tests for modified TypeScript files in apps/ or packages/ (services, routes, components, hooks)
- Do NOT request tests for config files, static assets, or type-only changes

For each modified implementation file that warrants testing, identify the corresponding test file and audit:
1. Run the test suite: cd $loop_dir && $unit_cmd
2. Check for TODO/FIXME/incomplete tests
3. Check for hollow assertions (expect(true).toBe(true), no assertions)
4. Verify edge cases and error conditions are tested
5. Check for mock abuse patterns

Output:
- result: 'passed' if tests are comprehensive OR if no testable TypeScript was modified, 'failed' if issues found
- issues: array of issues found (if any)
- summary: suitable for a GitHub comment (note if validation was skipped due to no testable changes)"

        local validate_result
        validate_result=$(run_stage "test-validate-iter-$test_iteration" "$validate_prompt" "implement-issue-review.json" "default")

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

            local fix_prompt="Address test quality issues in working directory $loop_dir on branch $loop_branch:

$validate_comments

Fix the test quality issues (add missing assertions, remove TODOs, add edge case tests, etc.) and commit.
Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-test-quality-iter-$test_iteration" "$fix_prompt" "implement-issue-fix.json" "$loop_agent")

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
    local branch tasks_json task_count completed_tasks

    # Load project pipeline config (build commands, test commands, etc.)
    load_pipeline_config

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
3. Implement tasks (with per-task quality loop: simplify, review)
4. Test loop (run tests, fix failures)
5. Documentation
6. Create/update PR
7. PR review loop

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
            local task_id task_desc task_agent task_status
            task_id=$(printf '%s' "$task" | jq -r '.id')
            task_desc=$(printf '%s' "$task" | jq -r '.description')
            task_agent=$(printf '%s' "$task" | jq -r '.agent')

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

            local review_attempts=0
            local task_approved=false

            while [[ "$task_approved" != "true" ]] && (( review_attempts < MAX_TASK_REVIEW_ATTEMPTS )); do
                # Implement
                local impl_prompt="Implement task $task_id on branch $branch in the current working directory:

$task_desc

Commit your changes with a descriptive message."

                local impl_result
                impl_result=$(run_stage "implement-task-$task_id" "$impl_prompt" "implement-issue-implement.json" "$task_agent")

                local impl_status
                impl_status=$(printf '%s' "$impl_result" | jq -r '.status')

                if [[ "$impl_status" != "success" ]]; then
                    log_error "Task $task_id implementation failed"
                    update_task "$task_id" "failed" "$review_attempts"
                    break
                fi

                local commit_sha
                commit_sha=$(printf '%s' "$impl_result" | jq -r '.commit')

                # Review task
                local review_prompt="Review task $task_id implementation (commit $commit_sha):

Task description: $task_desc

Did the implementation achieve the task's goal? Are there suggested improvements?"

                local review_result
                review_result=$(run_stage "task-review-$task_id-attempt-$((review_attempts+1))" "$review_prompt" "implement-issue-task-review.json" "spec-reviewer")

                local review_verdict suggested_improvements
                review_verdict=$(printf '%s' "$review_result" | jq -r '.result')
                suggested_improvements=$(printf '%s' "$review_result" | jq -r '.suggested_improvements')

                if [[ "$review_verdict" == "passed" && "$suggested_improvements" != "yes" ]]; then
                    task_approved=true
                    update_task "$task_id" "completed" "$((review_attempts+1))"
                    completed_tasks=$((completed_tasks+1))

                    # Comment #6: Task complete (with summary from implementing agent)
                    local impl_summary
                    impl_summary=$(printf '%s' "$impl_result" | jq -r '.summary // "Implementation completed"')
                    comment_issue "Task $task_id Complete" "**$task_desc**

**Commit:** \`$commit_sha\`

$impl_summary" "$task_agent"

                    # Run quality loop for this task
                    log "Running quality loop for task $task_id"
                    run_quality_loop "." "$branch" "task-$task_id" "$task_agent"

                else
                    review_attempts=$((review_attempts+1))
                    local review_comments
                    review_comments=$(printf '%s' "$review_result" | jq -r '.comments // "No comments"')

                    log "Task $task_id needs fixes (attempt $review_attempts/$MAX_TASK_REVIEW_ATTEMPTS)"

                    # Fix
                    local fix_prompt="Fix issues in task $task_id (commit $commit_sha) on branch $branch in the current working directory:

Review feedback:
$review_comments

Address the issues and commit."

                    run_stage "fix-task-$task_id-attempt-$review_attempts" "$fix_prompt" "implement-issue-fix.json" "$task_agent"
                fi
            done

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
    # STAGE: PRE-TEST BUILD (rebuild containers if configured)
    # -------------------------------------------------------------------------
    log "Running pre-test build hook (if configured)..."
    if ! run_pre_test_build; then
        log_error "Pre-test build failed — test results would verify stale code"
        comment_issue "Pre-Test Build Failed" "Build command failed before test loop. Fix build issues before tests can run.

**Command:** \`$CFG_BUILD_COMMAND\`
**Health check:** \`$CFG_HEALTH_CHECK_URL\`"
        set_final_state "error"
        exit 1
    fi

    # -------------------------------------------------------------------------
    # STAGE: TEST LOOP (after all tasks complete)
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "test_loop"; then
        log "Skipping test_loop stage (already completed)"
    else
        set_stage_started "test_loop"
        log "Running test loop after all tasks complete..."

        run_test_loop "." "$branch" "$AGENT"

        set_stage_completed "test_loop"
        log "Test loop complete."
    fi

    # -------------------------------------------------------------------------
    # STAGE: DOCS
    # -------------------------------------------------------------------------
    if [[ -n "$RESUME_MODE" ]] && is_stage_completed "docs"; then
        log "Skipping docs stage (already completed)"
    else
        set_stage_started "docs"

        local docs_prompt="Write JSDoc/TSDoc comments for all modified TypeScript files on branch $branch in the current working directory.

Get modified files with: git diff $BASE_BRANCH...HEAD --name-only -- '*.ts' '*.tsx' | grep -E '^(apps|packages)/' 

Add comprehensive JSDoc/TSDoc comments and commit with message: docs(issue-$ISSUE_NUMBER): add JSDoc comments"
        run_stage "docs" "$docs_prompt" "implement-issue-implement.json" "default"

        set_stage_completed "docs"
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
        # SPEC REVIEW → PR comment #11
        # -------------------------------------------------------------------------
        local spec_prompt="Verify PR #$pr_number achieves the goals of issue #$ISSUE_NUMBER.

Check goal achievement, not code quality. Flag scope creep.
Output a summary suitable for a GitHub comment."

        local spec_result
        spec_result=$(run_stage "spec-review-iter-$pr_iteration" "$spec_prompt" "implement-issue-review.json" "spec-reviewer")

        local spec_verdict spec_summary
        spec_verdict=$(printf '%s' "$spec_result" | jq -r '.result')
        spec_summary=$(printf '%s' "$spec_result" | jq -r '.summary // "Review completed"')

        # Comment #11: PR Spec Review Result
        local spec_icon="✅"
        [[ "$spec_verdict" == "changes_requested" ]] && spec_icon="🔄"
        comment_pr "$pr_number" "Spec Review (Iteration $pr_iteration)" "$spec_icon **Result:** $spec_verdict

$spec_summary" "spec-reviewer"

        # -------------------------------------------------------------------------
        # CODE REVIEW → PR comment #12
        # -------------------------------------------------------------------------
        local code_prompt="Review code quality of PR #$pr_number against base $BASE_BRANCH.

Check patterns, standards, security. Approve or request changes.
Output a summary suitable for a GitHub comment."

        local code_result
        code_result=$(run_stage "code-review-iter-$pr_iteration" "$code_prompt" "implement-issue-review.json" "code-reviewer")

        local code_verdict code_summary
        code_verdict=$(printf '%s' "$code_result" | jq -r '.result')
        code_summary=$(printf '%s' "$code_result" | jq -r '.summary // "Review completed"')

        # Comment #12: PR Code Review Result
        local code_icon="✅"
        [[ "$code_verdict" == "changes_requested" ]] && code_icon="🔄"
        comment_pr "$pr_number" "Code Review (Iteration $pr_iteration)" "$code_icon **Result:** $code_verdict

$code_summary" "code-reviewer"

        if [[ "$spec_verdict" == "approved" && "$code_verdict" == "approved" ]]; then
            pr_approved=true
            log "PR approved on iteration $pr_iteration"
        else
            log "PR review requested changes. Fixing and re-running quality loop."

            # Collect feedback
            local spec_comments code_comments
            spec_comments=$(printf '%s' "$spec_result" | jq -r '.comments // ""')
            code_comments=$(printf '%s' "$code_result" | jq -r '.comments // ""')

            local fix_prompt="Address PR review feedback on branch $branch in the current working directory:

Spec review:
$spec_comments

Code review:
$code_comments

Fix the issues and commit. Output a summary of fixes applied."

            local fix_result
            fix_result=$(run_stage "fix-pr-review-iter-$pr_iteration" "$fix_prompt" "implement-issue-fix.json" "$AGENT")

            local fix_summary
            fix_summary=$(printf '%s' "$fix_result" | jq -r '.summary // "Fixes applied"')

            # Comment #13: PR Fix Result
            comment_pr "$pr_number" "PR Review Fix (Iteration $pr_iteration)" "$fix_summary" "$AGENT"

            # Re-run quality loop after PR review fixes
            log "Re-running quality loop after PR review fixes..."
            run_quality_loop "." "$branch" "pr-fix" "$AGENT"

            # Push updates
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
