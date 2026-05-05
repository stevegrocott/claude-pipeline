#!/usr/bin/env bash
#
# surgical-fast-path.sh
#
# Executes the surgical fast-path: dirty-tree check -> branch setup ->
# implement -> commit -> push -> PR create -> mergeability check ->
# squash-merge. Skips test loop, code review, deploy verify, docs.
#
# Invoked by implement-issue-orchestrator.sh after the triage stage routes
# an issue to "fast-path". Inherits status file, log dir, and branch from
# the parent orchestrator via env.
#
# Bail-out policy: each step that fails sets state="failed" and a specific
# error reason in status.json. The script does NOT fall back to the full
# pipeline — operators get a clear failure surface for tuning the triage
# criteria. Pre-commit hook failures additionally capture stderr to
# triage.json.hook_failure_output for postmortem.
#
# Kill switch: DISABLE_SURGICAL_FAST_PATH=1 forces an immediate exit. The
# orchestrator already enforces this before invoking us, but we re-check so
# that direct invocation honors the same control.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="${SCHEMA_DIR:-$SCRIPT_DIR/schemas}"

if [[ -f "$SCRIPT_DIR/../config/platform.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/../config/platform.sh"
fi
if [[ -f "$SCRIPT_DIR/model-config.sh" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/model-config.sh"
fi

# Required env from parent orchestrator (or from tests setting these directly).
: "${STATUS_FILE:?STATUS_FILE required}"
: "${LOG_BASE:?LOG_BASE required}"
: "${ISSUE_NUMBER:?ISSUE_NUMBER required}"
: "${BASE_BRANCH:?BASE_BRANCH required}"

# BRANCH is normally exported by the orchestrator before exec'ing us. Fall
# back to the value persisted in status.json so direct invocation works.
BRANCH="${BRANCH:-$(jq -r '.branch // empty' "$STATUS_FILE" 2>/dev/null || true)}"
if [[ -z "${BRANCH:-}" ]]; then
    BRANCH="feature/issue-${ISSUE_NUMBER}"
fi

LOG_FILE="${LOG_FILE:-$LOG_BASE/surgical-fast-path.log}"
mkdir -p "$LOG_BASE/stages"

log() {
    local ts
    ts=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
    printf '[%s] %s\n' "$ts" "$*" | tee -a "$LOG_FILE"
}

# --- status helpers (subset; the orchestrator owns the full set) -----------

_jq_inplace() {
    local file="$1"; shift
    jq "$@" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

set_stage_in_progress() {
    local stage="$1"
    _jq_inplace "$STATUS_FILE" \
        --arg s "$stage" \
        '.stages[$s].status = "in_progress" |
         .stages[$s].started_at = (now | todate) |
         .current_stage = $s |
         .state = "running" |
         .last_update = (now | todate)'
}

set_stage_completed() {
    local stage="$1"
    _jq_inplace "$STATUS_FILE" \
        --arg s "$stage" \
        '.stages[$s].status = "completed" |
         .stages[$s].completed_at = (now | todate) |
         .last_update = (now | todate)'
}

# Each bail sets state=failed with a specific error reason. The orchestrator's
# batch-level circuit breaker treats state=failed as a real failure, so a
# false-positive triage surfaces as a counted incident, not a silent skip.
bail() {
    local reason="$1"
    log "Fast-path bail: $reason"
    _jq_inplace "$STATUS_FILE" \
        --arg err "$reason" \
        '.state = "failed" |
         .error = $err |
         .last_update = (now | todate)'
    exit 1
}

capture_hook_failure() {
    local stderr_file="$1"
    local triage_artifact="$LOG_BASE/triage.json"
    [[ -f "$triage_artifact" ]] || echo '{}' > "$triage_artifact"
    local hook_output
    hook_output=$(head -c 4096 "$stderr_file" 2>/dev/null || true)
    _jq_inplace "$triage_artifact" \
        --arg out "$hook_output" \
        '.hook_failure_output = $out'
}

# Resume support is at stage boundaries only. If status.json says a fast_path_*
# stage is already "completed", we skip it. Crashes within a stage (between
# commit and push, between push and pr-create, etc.) are NOT recovered — the
# operator will see a specific bail reason and can intervene. The common
# resume case (rate-limit between PR create and merge) IS handled.
is_stage_completed() {
    local stage="$1"
    local status
    status=$(jq -r --arg s "$stage" '.stages[$s].status // "pending"' "$STATUS_FILE" 2>/dev/null || echo "pending")
    [[ "$status" == "completed" ]]
}

read_pr_number_from_status() {
    jq -r '.stages.fast_path_pr.pr_number // empty' "$STATUS_FILE" 2>/dev/null
}

# --- kill switch -----------------------------------------------------------

if [[ "${DISABLE_SURGICAL_FAST_PATH:-0}" == "1" ]]; then
    echo "DISABLE_SURGICAL_FAST_PATH=1 — refusing to run surgical fast-path"
    exit 1
fi

log "Surgical fast-path starting for issue #$ISSUE_NUMBER on branch $BRANCH"

pr_number=""

# --- 1. Dirty tree check ---------------------------------------------------
#
# On resume, the implement stage already wrote files but they should have
# been committed before the crash. If the tree is dirty AND we have prior
# completed work, those uncommitted changes are leftover scratch and we
# should still bail — the operator needs to investigate.

if [[ -n "$(git status --porcelain 2>/dev/null || true)" ]]; then
    bail "dirty_tree"
fi

# --- 2. Branch setup -------------------------------------------------------

git checkout "$BRANCH" 2>>"$LOG_FILE" || bail "branch_checkout_failed"

# --- 3. Implement (skip if already completed) ------------------------------

if is_stage_completed fast_path_implement; then
    log "fast_path_implement already completed — skipping (resume)"
else
    set_stage_in_progress fast_path_implement

    issue_body_file="$LOG_BASE/context/issue-body.md"
    issue_body=""
    [[ -f "$issue_body_file" ]] && issue_body=$(cat "$issue_body_file")

    implement_prompt=$(cat <<PROMPT
Implement the issue described below. The triage stage classified this as a
surgical fast-path change — test-only scope, <30 lines diff, <=3 files,
established pattern, precise specification. Apply ONLY the changes described
in the Implementation Tasks section. Do not add tests, refactor, or expand
scope beyond the listed tasks.

Issue body:
${issue_body}

After making the edits, output JSON: {"status":"success","summary":"<one-line summary>"}.
PROMPT
)

    implement_model="${FAST_PATH_IMPLEMENT_MODEL:-sonnet}"
    implement_log="$LOG_BASE/stages/fast-path-implement.log"
    implement_schema="$SCHEMA_DIR/implement-issue-implement.json"

    if [[ -f "$implement_schema" ]]; then
        schema_arg=(--json-schema "$(jq -c . "$implement_schema")")
    else
        schema_arg=()
    fi

    implement_output=$(env -u CLAUDECODE "${CLAUDE_CLI:-claude}" -p "$implement_prompt" \
        --model "$implement_model" \
        --dangerously-skip-permissions \
        --output-format json \
        "${schema_arg[@]}" \
        2>&1) || bail "implement_failed"

    printf '%s\n' "$implement_output" > "$implement_log"

    # Process exit 0 is necessary but not sufficient — Claude CLI can return
    # success with status="error" in the structured output. Without this
    # check we'd commit a partial/empty change and the failure would surface
    # as pre_commit_hook_failed downstream, hiding the real cause.
    impl_status=$(printf '%s' "$implement_output" \
        | jq -r '.structured_output.status // ((.result | fromjson?) | .status?) // "error"' \
        2>/dev/null || echo "error")
    if [[ "$impl_status" != "success" ]]; then
        bail "implement_returned_${impl_status}"
    fi

    set_stage_completed fast_path_implement
    log "Fast-path implement complete"
fi

# --- 4-6. Commit, push, PR create (skip if already completed) --------------
#
# These three steps are treated as one resumable unit. If fast_path_pr is
# completed, the PR exists and we read its number from status.json. If it
# is NOT completed, we run all three from scratch — meaning a mid-unit
# crash (e.g. between commit and push) is not recovered automatically.

if is_stage_completed fast_path_pr; then
    pr_number=$(read_pr_number_from_status)
    [[ -n "$pr_number" ]] || bail "pr_number_missing_on_resume"
    log "fast_path_pr already completed — reusing PR #$pr_number (resume)"
else
    set_stage_in_progress fast_path_pr

    git add -A 2>>"$LOG_FILE"

    hook_stderr="$LOG_BASE/stages/fast-path-commit.stderr"
    commit_msg="feat(issue-${ISSUE_NUMBER}): surgical fast-path change

Closes #${ISSUE_NUMBER}"

    if ! git commit -m "$commit_msg" 2>"$hook_stderr"; then
        capture_hook_failure "$hook_stderr"
        bail "pre_commit_hook_failed"
    fi

    if ! git push -u origin "$BRANCH" 2>>"$LOG_FILE"; then
        bail "push_rejected"
    fi

    pr_url=$(gh pr create \
        --base "$BASE_BRANCH" \
        --head "$BRANCH" \
        --title "feat(issue-${ISSUE_NUMBER}): surgical fast-path change" \
        --body "Closes #${ISSUE_NUMBER}

Created by the surgical fast-path. The triage classifier determined this
change met all six fast-path criteria (test-only scope, surgical size,
established pattern, precise specification, benign failure mode, no security
concerns). See triage.json for the classification record." \
        2>>"$LOG_FILE") || bail "pr_create_failed"

    pr_number=$(printf '%s' "$pr_url" | grep -oE '[0-9]+$' | head -1)
    [[ -n "$pr_number" ]] || bail "pr_number_unparseable"

    _jq_inplace "$STATUS_FILE" \
        --arg n "$pr_number" \
        '.stages.fast_path_pr.pr_number = ($n | tonumber)'

    set_stage_completed fast_path_pr
    log "Fast-path PR created: #$pr_number"
fi

# --- 7-8. Mergeability check + squash-merge (skip if already completed) ---

if is_stage_completed fast_path_merge; then
    log "fast_path_merge already completed — pipeline already finished (resume)"
else
    set_stage_in_progress fast_path_merge

    # GitHub computes mergeStateStatus asynchronously after PR creation.
    # The first ~2-10s post-create reliably returns UNKNOWN. Without retry
    # the fast-path would bail on virtually every real PR. Configurable so
    # tests can short-circuit.
    merge_check_attempts="${FAST_PATH_MERGE_CHECK_ATTEMPTS:-5}"
    merge_check_delay="${FAST_PATH_MERGE_CHECK_DELAY:-3}"
    merge_state="UNKNOWN"

    for ((attempt=1; attempt<=merge_check_attempts; attempt++)); do
        merge_state=$(gh pr view "$pr_number" --json mergeStateStatus 2>/dev/null \
            | jq -r '.mergeStateStatus // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
        case "$merge_state" in
            CLEAN|HAS_HOOKS) break ;;
            UNKNOWN)
                if (( attempt < merge_check_attempts )); then
                    log "mergeStateStatus=UNKNOWN (attempt $attempt/$merge_check_attempts) — retrying in ${merge_check_delay}s"
                    sleep "$merge_check_delay"
                fi
                ;;
            *) break ;;  # DIRTY, BLOCKED, BEHIND, etc. — bail without retry
        esac
    done

    case "$merge_state" in
        CLEAN|HAS_HOOKS) ;;
        *) bail "unsafe_merge_state_${merge_state}" ;;
    esac

    if ! gh pr merge "$pr_number" --squash --delete-branch 2>>"$LOG_FILE"; then
        bail "merge_failed"
    fi

    set_stage_completed fast_path_merge
fi

# --- 9. Mark complete ------------------------------------------------------

_jq_inplace "$STATUS_FILE" \
    '.state = "completed" |
     .current_stage = "complete" |
     .last_update = (now | todate)'

log "Surgical fast-path complete. PR #$pr_number merged and branch deleted."
exit 0
