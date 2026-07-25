#!/usr/bin/env bash
#
# run-batches-all.sh
# Sequential wrapper that runs all batches defined in IMPLEMENTATION_BATCHES.md.
#
# For each batch:
#   1. git tag -f batch-N-start
#   2. .claude/scripts/batch-orchestrator.sh --issues "..." --branch main
#   3. .claude/scripts/post-batch-validate.sh --batch N
#
# Stops on first non-zero exit and prints a summary.
#
# Usage:
#   ./.claude/scripts/run-batches-all.sh
#   ./.claude/scripts/run-batches-all.sh --start-batch 7
#   ./.claude/scripts/run-batches-all.sh --help
#
# Exit codes:
#   0  All batches passed
#   1  A batch or validation step failed (see summary)
#   3  Usage / configuration error
#

set -uo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$REPO_ROOT/logs/run-batches-all-$TIMESTAMP"

# =============================================================================
# BATCH DEFINITIONS — issue lists sourced from IMPLEMENTATION_BATCHES.md
#
# Batches 1-6 are already complete; included so --start-batch works correctly
# and git tags are placed for provenance.
# =============================================================================

# Using parallel arrays for bash 3 compatibility (macOS default bash)
BATCH_NUMS=(1 2 3 4 5 6 7 8 9 10 11)
BATCH_ISSUES_1="1389,1263,1391,1392,1319"
BATCH_ISSUES_2="1298,1292,1285,1388"
BATCH_ISSUES_3="1339,1340,1351,1338,1372"
BATCH_ISSUES_4="1399,1394,1405,1406,1400"
BATCH_ISSUES_5="1396,1397,1273,1271,1264"
BATCH_ISSUES_6="1417,1410,1408,1378,1379,1369,1282"
BATCH_ISSUES_7="1281,1331,1349,1259,1420"
BATCH_ISSUES_8="1257,1307,1416,1386,1436,1434"
BATCH_ISSUES_9="1251,1303,1305,1252,1454"
BATCH_ISSUES_10="1270,1296,1326"
BATCH_ISSUES_11="1422,1423,1424"

TOTAL_BATCHES=11

get_batch_issues() {
    local n="$1"
    local varname="BATCH_ISSUES_$n"
    echo "${!varname}"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

usage() {
    cat <<EOF
Usage: $0 [--start-batch N]

Options:
  --start-batch N   Resume from batch N (default: 1)
  --help            Show this help

Exit codes:
  0  All batches passed
  1  A batch or validation step failed
  3  Usage / configuration error
EOF
    exit 3
}

START_BATCH=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start-batch)
            [[ -n "${2:-}" ]] || { echo "ERROR: --start-batch requires a value" >&2; exit 3; }
            START_BATCH="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

if ! [[ "$START_BATCH" =~ ^[0-9]+$ ]] || (( START_BATCH < 1 )) || (( START_BATCH > TOTAL_BATCHES )); then
    echo "ERROR: --start-batch must be between 1 and $TOTAL_BATCHES, got: $START_BATCH" >&2
    exit 3
fi

# =============================================================================
# SETUP
# =============================================================================

mkdir -p "$LOG_DIR"

SUMMARY_FILE="$LOG_DIR/summary.txt"
FAILED_BATCH=""
FAILED_STEP=""

log() {
    local msg="$1"
    echo "$msg" | tee -a "$SUMMARY_FILE"
}

log "=== run-batches-all: start (batches $START_BATCH–$TOTAL_BATCHES) ==="
log "Log directory: $LOG_DIR"
log "Timestamp: $TIMESTAMP"
log ""

cd "$REPO_ROOT"

# =============================================================================
# MAIN LOOP
# =============================================================================

for (( batch=START_BATCH; batch<=TOTAL_BATCHES; batch++ )); do
    ISSUES="$(get_batch_issues "$batch")"
    BATCH_LOG_DIR="$LOG_DIR/batch-$batch"
    mkdir -p "$BATCH_LOG_DIR"

    log "--- Batch $batch/$TOTAL_BATCHES: issues=$ISSUES ---"

    # -------------------------------------------------------------------------
    # Step 1: git tag
    # -------------------------------------------------------------------------
    log "[batch $batch] git tag -f batch-$batch-start"
    if ! git tag -f "batch-$batch-start" >> "$BATCH_LOG_DIR/git-tag.log" 2>&1; then
        log "ERROR: git tag failed for batch $batch"
        FAILED_BATCH="$batch"
        FAILED_STEP="git-tag"
        break
    fi

    # -------------------------------------------------------------------------
    # Step 2: batch-orchestrator.sh
    # -------------------------------------------------------------------------
    ORCHESTRATOR_LOG="$BATCH_LOG_DIR/batch-orchestrator.log"
    log "[batch $batch] batch-orchestrator.sh --issues \"$ISSUES\" --branch main"

    ORCHESTRATOR_EXIT=0
    "$SCRIPT_DIR/batch-orchestrator.sh" \
        --issues "$ISSUES" \
        --branch main \
        2>&1 | tee "$ORCHESTRATOR_LOG" || ORCHESTRATOR_EXIT=$?

    if (( ORCHESTRATOR_EXIT != 0 )); then
        log "ERROR: batch-orchestrator.sh failed (exit $ORCHESTRATOR_EXIT) for batch $batch"
        FAILED_BATCH="$batch"
        FAILED_STEP="batch-orchestrator"
        break
    fi

    # -------------------------------------------------------------------------
    # Step 3: post-batch-validate.sh
    # -------------------------------------------------------------------------
    VALIDATE_LOG="$BATCH_LOG_DIR/post-batch-validate.log"
    log "[batch $batch] post-batch-validate.sh --batch $batch"

    VALIDATE_EXIT=0
    "$SCRIPT_DIR/post-batch-validate.sh" \
        --batch "$batch" \
        2>&1 | tee "$VALIDATE_LOG" || VALIDATE_EXIT=$?

    if (( VALIDATE_EXIT != 0 )); then
        log "ERROR: post-batch-validate.sh failed (exit $VALIDATE_EXIT) for batch $batch"
        FAILED_BATCH="$batch"
        FAILED_STEP="post-batch-validate"
        break
    fi

    log "[batch $batch] PASSED"
    log ""
done

# =============================================================================
# SUMMARY
# =============================================================================

log ""
log "=== run-batches-all: SUMMARY ==="

if [[ -n "$FAILED_BATCH" ]]; then
    log "FAILED at batch $FAILED_BATCH (step: $FAILED_STEP)"
    log "To resume: $0 --start-batch $FAILED_BATCH"
    log "Logs: $LOG_DIR"
    log ""
    log "Batches completed: $(( FAILED_BATCH - START_BATCH )) of $(( TOTAL_BATCHES - START_BATCH + 1 ))"
    exit 1
else
    COMPLETED=$(( TOTAL_BATCHES - START_BATCH + 1 ))
    log "All $COMPLETED batches passed (batches $START_BATCH–$TOTAL_BATCHES)"
    log "Logs: $LOG_DIR"
    exit 0
fi
