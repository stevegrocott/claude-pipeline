#!/usr/bin/env bash
#
# explore-orchestrator.sh — Lightweight orchestrator for the explore research phase.
# Runs a single research subagent to investigate an idea against a project.
#
# Usage:
#   ./explore-orchestrator.sh --idea "description of what to explore"
#   ./explore-orchestrator.sh --idea "description" --project-dir /path/to/project
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$SCRIPT_DIR/schemas"
source "$SCRIPT_DIR/model-config.sh"

# Claude CLI — allow override via env, else resolve path
if [[ -z "${CLAUDE_CLI:-}" ]]; then
    if [[ -x "$HOME/.claude/local/claude" ]]; then
        CLAUDE_CLI="$HOME/.claude/local/claude"
    else
        CLAUDE_CLI="claude"
    fi
fi

STAGE_TIMEOUT="${EXPLORE_TIMEOUT:-600}"

# Portable timeout (macOS does not ship GNU timeout)
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

# --- Argument parsing ---
IDEA=""
PROJECT_DIR=""

usage() {
    cat <<EOF
Usage: $0 --idea "description" [--project-dir /path/to/project]
Options:
  --idea <text>           Description of what to explore (required)
  --project-dir <path>    Project directory (defaults to \$PWD)
  --help, -h              Show this help
EOF
    exit 3
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --idea)
            [[ -n "${2:-}" ]] || { echo "ERROR: --idea requires a value" >&2; exit 3; }
            IDEA="$2"; shift 2 ;;
        --project-dir)
            [[ -n "${2:-}" ]] || { echo "ERROR: --project-dir requires a value" >&2; exit 3; }
            PROJECT_DIR="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

[[ -n "$IDEA" ]] || { echo "ERROR: --idea is required" >&2; usage; }

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
[[ "$PROJECT_DIR" == /* ]] || PROJECT_DIR="$PWD/$PROJECT_DIR"
[[ -d "$PROJECT_DIR" ]] || { echo "ERROR: project directory does not exist: $PROJECT_DIR" >&2; exit 1; }

# --- Log directory ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="$PROJECT_DIR/logs/explore/explore-${TIMESTAMP}"
mkdir -p "$LOG_DIR/stages"
LOG_FILE="$LOG_DIR/orchestrator.log"
STATUS_FILE="$LOG_DIR/status.json"
STAGE_LOG="$LOG_DIR/stages/01-research.log"

# --- Logging ---
log()       { local m="[$(date -Iseconds)] $*"; printf '%s\n' "$m" >> "$LOG_FILE"; printf '%s\n' "$m" >&2; }
log_error() { local m="[$(date -Iseconds)] ERROR: $*"; printf '%s\n' "$m" >> "$LOG_FILE"; printf '%s\n' "$m" >&2; }

# --- Status file ---
init_status() {
    local now; now=$(date -Iseconds)
    jq -n --argjson issue "null" --arg log_dir "$LOG_DIR" --arg now "$now" \
        '{
            state: "running", issue: $issue,
            tasks: [{description: "**(S)** Research codebase for explore", agent: "research-agent", status: "in_progress"}],
            stages: { research: {status: "in_progress", started_at: $now} },
            quality_iterations: 0, test_iterations: 0,
            last_update: $now, log_dir: $log_dir
        }' > "$STATUS_FILE"
}

update_status() {
    local state="$1" stage_status="$2" task_status="$3" now
    now=$(date -Iseconds)
    jq --arg state "$state" --arg ss "$stage_status" --arg ts "$task_status" --arg now "$now" \
        '.state=$state | .stages.research.status=$ss | .stages.research.completed_at=$now
         | .tasks[0].status=$ts | .last_update=$now' \
        "$STATUS_FILE" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
}

# Load a skill's SKILL.md content for injection into stage prompts.
# Usage: local content; content=$(load_skill "test-discovery")
# Returns empty string if skill file not found (non-fatal).
load_skill() {
    local skill_name="$1"
    # CLAUDE_PROJECT_DIR is set by Claude Code but absent when run from batch/shell directly.
    # Fall back to the script's own repo root so skills load correctly in both contexts.
    local _project_dir="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    local skill_file="$_project_dir/.claude/skills/$skill_name/SKILL.md"
    if [[ -f "$skill_file" ]]; then
        cat "$skill_file"
    else
        log "Skill file not found: $skill_file"
        printf ''
    fi
}

# --- Metrics ---
START_EPOCH=$(date +%s)
ESCALATIONS=0
MODEL_USED=""

write_metrics() {
    local end_epoch; end_epoch=$(date +%s)
    jq -n --argjson duration "$(( end_epoch - START_EPOCH ))" \
        --arg model "$MODEL_USED" --argjson escalations "$ESCALATIONS" \
        '{ duration_seconds: $duration, model_used: $model, escalations: $escalations }' \
        > "$LOG_DIR/metrics.json"
}

# --- Main ---
log "Explore orchestrator started"
log "  Idea: $IDEA"
log "  Project: $PROJECT_DIR"
log "  Log dir: $LOG_DIR"
init_status

# Resolve model — research stage, S complexity
MODEL=$(resolve_model research S)
FALLBACK=$(_next_model_up "$MODEL")
MODEL_USED="$MODEL"
log "  Model: $MODEL (fallback: $FALLBACK)"

test_discovery_skill=$(load_skill "test-discovery")

PROMPT="You are a research agent investigating a project codebase.

## Your task
Investigate the following idea against this project:

$IDEA

## Project directory
$PROJECT_DIR

${test_discovery_skill:+## Skill Instructions — READ AND FOLLOW THESE

$test_discovery_skill

## End Skill Instructions

}## Instructions
1. Explore the project structure, key files, and relevant code
2. Understand the current behavior related to the idea
3. Identify files that would need to change
4. Note existing patterns the implementation should follow
5. Summarize your findings clearly

Be thorough but focused. Read relevant files, understand the architecture, and provide actionable findings."

SCHEMA=$(jq -c . "$SCHEMA_DIR/explore-research.json")

FALLBACK_ARGS=()
[[ "$FALLBACK" != "$MODEL" ]] && FALLBACK_ARGS=(--fallback-model "$FALLBACK")

log "Running research stage..."
OUTPUT=""
EXIT_CODE=0

OUTPUT=$(timeout "$STAGE_TIMEOUT" env -u CLAUDECODE "$CLAUDE_CLI" -p "$PROMPT" \
    --model "$MODEL" \
    ${FALLBACK_ARGS[@]+"${FALLBACK_ARGS[@]}"} \
    --max-turns 15 \
    --dangerously-skip-permissions \
    --output-format json \
    --json-schema "$SCHEMA" \
    2>&1) || EXIT_CODE=$?

printf '%s\n' "=== research output ===" >> "$STAGE_LOG"
printf '%s\n' "$OUTPUT" >> "$STAGE_LOG"
printf '%s\n' "=== exit code: $EXIT_CODE ===" >> "$STAGE_LOG"

# Handle max_turns exhaustion — escalate to sonnet, retry without turn cap
if (( EXIT_CODE != 0 )); then
    SUBTYPE=$(printf '%s' "$OUTPUT" | jq -r '.subtype // empty' 2>/dev/null || true)
    if [[ "$SUBTYPE" == "error_max_turns" ]]; then
        log "Max turns exhausted — escalating to sonnet and retrying without turn cap"
        ESCALATIONS=$((ESCALATIONS + 1))
        MODEL="sonnet"; MODEL_USED="sonnet"
        FALLBACK=$(_next_model_up "$MODEL")
        FALLBACK_ARGS=()
        [[ "$FALLBACK" != "$MODEL" ]] && FALLBACK_ARGS=(--fallback-model "$FALLBACK")

        EXIT_CODE=0
        OUTPUT=$(timeout "$STAGE_TIMEOUT" env -u CLAUDECODE "$CLAUDE_CLI" -p "$PROMPT" \
            --model "$MODEL" ${FALLBACK_ARGS[@]+"${FALLBACK_ARGS[@]}"} \
            --dangerously-skip-permissions --output-format json --json-schema "$SCHEMA" \
            2>&1) || EXIT_CODE=$?

        printf '%s\n' "=== escalated output ===" >> "$STAGE_LOG"
        printf '%s\n' "$OUTPUT" >> "$STAGE_LOG"
        printf '%s\n' "=== exit code: $EXIT_CODE ===" >> "$STAGE_LOG"
    fi
fi

# Handle timeout — retry once with 20% longer timeout
if (( EXIT_CODE == 124 )); then
    TIMEOUT_STRUCTURED=$(printf '%s' "$OUTPUT" | jq -c '.structured_output // empty' 2>/dev/null || true)
    if [[ -n "$TIMEOUT_STRUCTURED" ]]; then
        log "WARN: Timed out but produced structured output — using it"
        EXIT_CODE=0
    else
        RETRY_TIMEOUT=$(( STAGE_TIMEOUT * 120 / 100 ))
        log "Timed out after ${STAGE_TIMEOUT}s — retrying with ${RETRY_TIMEOUT}s"
        ESCALATIONS=$((ESCALATIONS + 1))
        EXIT_CODE=0
        OUTPUT=$(timeout "$RETRY_TIMEOUT" env -u CLAUDECODE "$CLAUDE_CLI" -p "$PROMPT" \
            --model "$MODEL" ${FALLBACK_ARGS[@]+"${FALLBACK_ARGS[@]}"} \
            --max-turns 15 --dangerously-skip-permissions --output-format json --json-schema "$SCHEMA" \
            2>&1) || EXIT_CODE=$?

        printf '%s\n' "=== timeout retry output ===" >> "$STAGE_LOG"
        printf '%s\n' "$OUTPUT" >> "$STAGE_LOG"
        printf '%s\n' "=== exit code: $EXIT_CODE ===" >> "$STAGE_LOG"
    fi
fi

# Extract structured output
STRUCTURED=""
if (( EXIT_CODE == 0 )); then
    STRUCTURED=$(printf '%s' "$OUTPUT" | jq -c '.structured_output // empty' 2>/dev/null || true)
    if [[ -z "$STRUCTURED" ]]; then
        STRUCTURED=$(printf '%s' "$OUTPUT" | jq -c '.result // empty' 2>/dev/null || true)
        [[ -n "$STRUCTURED" ]] && log "WARN: No .structured_output — using .result fallback"
    fi
fi

# Write results or handle failure
if [[ -n "$STRUCTURED" ]]; then
    log "Research completed successfully"
    printf '%s\n' "$STRUCTURED" | jq . > "$LOG_DIR/research-summary.json"
    update_status "completed" "completed" "completed"
    write_metrics
    printf '%s\n' "$LOG_DIR/research-summary.json"
else
    log_error "Research stage failed (exit code: $EXIT_CODE)"
    update_status "failed" "failed" "failed"
    write_metrics
    printf '%s\n' "$LOG_DIR"
    exit 1
fi
