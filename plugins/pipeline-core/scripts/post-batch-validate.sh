#!/usr/bin/env bash
#
# post-batch-validate.sh
# Post-batch validation: maps a batch number to a validation tier, builds Docker
# if needed, runs unit tests, and runs targeted or full E2E tests.
#
# Usage:
#   ./.claude/scripts/post-batch-validate.sh --batch N
#
# Exit codes:
#   0 — all tests passed
#   1 — unit test failure
#   2 — E2E failure after fix attempts
#   3 — usage / configuration error
#

set -uo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../config/platform.sh"

HEALTH_URL="http://localhost:30004/health"
HEALTH_TIMEOUT=120      # seconds to poll /health after Docker rebuild
HEALTH_INTERVAL=5       # seconds between health poll attempts

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
# TIER MAP
#
# Tier names:
#   unit-only           — npm test only; no Docker rebuild, no E2E
#   build+unit          — Docker rebuild + npm test; no E2E
#   unit+targeted-E2E   — Docker rebuild + npm test + targeted playwright project
#   unit+full-E2E       — Docker rebuild + npm test + full-journey playwright project
#
# Batch → tier assignment:
#   1-3    unit-only
#   4      unit+targeted-E2E  (project: batch-4-regression)
#   5-9    build+unit
#   10     unit+targeted-E2E  (project: batch-10-regression)
#   11+    unit+full-E2E      (project: full-journey)
# =============================================================================

map_batch_to_tier() {
    local batch="$1"
    if (( batch >= 1 && batch <= 3 )); then
        echo "unit-only"
    elif (( batch == 4 )); then
        echo "unit+targeted-E2E"
    elif (( batch >= 5 && batch <= 9 )); then
        echo "build+unit"
    elif (( batch == 10 )); then
        echo "unit+targeted-E2E"
    else
        echo "unit+full-E2E"
    fi
}

map_batch_to_e2e_project() {
    local batch="$1"
    case "$batch" in
        4)  echo "batch-4-regression" ;;
        10) echo "batch-10-regression" ;;
        *)  echo "full-journey" ;;
    esac
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

usage() {
    cat <<EOF
Usage: $0 --batch N

Options:
  --batch N   Batch number (required, positive integer)
  --help      Show this help

Exit codes:
  0  All tests passed
  1  Unit test failure
  2  E2E failure after fix attempts
  3  Usage / configuration error
EOF
    exit 3
}

BATCH_NUMBER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --batch)
            [[ -n "${2:-}" ]] || { echo "ERROR: --batch requires a value" >&2; exit 3; }
            BATCH_NUMBER="$2"
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

if [[ -z "$BATCH_NUMBER" ]]; then
    echo "ERROR: --batch N is required" >&2
    usage
fi

if ! [[ "$BATCH_NUMBER" =~ ^[0-9]+$ ]] || (( BATCH_NUMBER < 1 )); then
    echo "ERROR: --batch must be a positive integer, got: $BATCH_NUMBER" >&2
    exit 3
fi

# =============================================================================
# DERIVE TIER AND E2E PROJECT
# =============================================================================

TIER=$(map_batch_to_tier "$BATCH_NUMBER")
E2E_PROJECT=$(map_batch_to_e2e_project "$BATCH_NUMBER")

echo "=== post-batch-validate: batch=$BATCH_NUMBER tier=$TIER ==="

# =============================================================================
# DOCKER REBUILD (all tiers except unit-only)
# =============================================================================

needs_docker_rebuild() {
    [[ "$TIER" != "unit-only" ]]
}

poll_health() {
    local deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
    echo "Polling $HEALTH_URL (timeout ${HEALTH_TIMEOUT}s)..."
    while (( $(date +%s) < deadline )); do
        if curl -sf "$HEALTH_URL" >/dev/null 2>&1; then
            echo "Health check passed."
            return 0
        fi
        sleep "$HEALTH_INTERVAL"
    done
    echo "ERROR: Health check timed out after ${HEALTH_TIMEOUT}s" >&2
    return 1
}

if needs_docker_rebuild; then
    echo "--- Docker rebuild: frontend ---"
    docker-compose build --no-cache frontend || {
        echo "ERROR: docker-compose build failed" >&2
        exit 1
    }
    docker-compose up -d frontend || {
        echo "ERROR: docker-compose up failed" >&2
        exit 1
    }
    poll_health || exit 1
fi

# =============================================================================
# UNIT TESTS
# =============================================================================

echo "--- Unit tests: npm test ---"
npm test || {
    echo "ERROR: Unit tests failed" >&2
    exit 1
}

echo "Unit tests passed."

# =============================================================================
# E2E TESTS (unit+targeted-E2E and unit+full-E2E tiers only)
# =============================================================================

needs_e2e() {
    [[ "$TIER" == "unit+targeted-E2E" || "$TIER" == "unit+full-E2E" ]]
}

if needs_e2e; then
    echo "--- E2E tests: project=$E2E_PROJECT ---"

    E2E_EXIT=0
    npx playwright test --project="$E2E_PROJECT" --reporter=json || E2E_EXIT=$?

    if (( E2E_EXIT != 0 )); then
        echo "E2E tests failed (exit $E2E_EXIT). Invoking test-fix-loop..." >&2

        FIX_EXIT=0
        bash "$SCRIPT_DIR/test-fix-loop.sh" \
            --max-iterations 2 \
            --branch main || FIX_EXIT=$?

        if (( FIX_EXIT != 0 )); then
            echo "ERROR: E2E tests still failing after fix attempts" >&2
            exit 2
        fi

        echo "E2E tests passed after fix loop."
    else
        echo "E2E tests passed."
    fi
fi

echo "=== post-batch-validate: PASSED (batch=$BATCH_NUMBER tier=$TIER) ==="
exit 0
