#!/usr/bin/env bash
#
# run-tests.sh
# Test runner for implement-issue-orchestrator.sh tests
#
# Usage:
#   ./run-tests.sh              # Run all tests
#   ./run-tests.sh <test-file>  # Run specific test file
#   ./run-tests.sh --tap        # Output in TAP format
#   ./run-tests.sh --verbose    # Verbose output
#
# Prerequisites:
#   - bats-core installed (brew install bats-core OR npm install -g bats)
#   - jq installed (brew install jq OR apt install jq)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# =============================================================================
# PREREQUISITES CHECK
# =============================================================================

check_prerequisites() {
    local missing=()

    if ! command -v bats &>/dev/null; then
        missing+=("bats-core")
    fi

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if (( ${#missing[@]} > 0 )); then
        echo -e "${RED}Error: Missing required tools:${NC} ${missing[*]}"
        echo ""
        echo "Install with:"
        echo "  macOS:   brew install ${missing[*]}"
        echo "  Ubuntu:  sudo apt install ${missing[*]}"
        echo "  npm:     npm install -g bats (for bats-core only)"
        exit 1
    fi
}

# =============================================================================
# CI EXCLUSIONS  (issue #855)
# =============================================================================
#
# THIS IS THE LIST CI USES. `--ci` runs every test-*.bats in this directory
# EXCEPT the entries below, so a new suite is covered by CI the moment it is
# added — no workflow edit required, and no way to be silently forgotten.
#
# Before #855, CI ran 2 of 59 suites. Everything else was unrun, which is how
# a merge-block ordering test stayed red on main after #853 changed the
# process-pr skill: nothing executed it. Add to this list only with a reason.
#
# Each exclusion must say WHY. "Slow" is not a reason; "needs credentials CI
# does not have" is.
#
# Empirically verified 2026-09-01: 60 of 61 suites pass with `claude` absent
# from PATH and gh unauthenticated (empty HOME, no token) — i.e. under the
# conditions of a CI runner. The older claim that seven suites "shell out to
# gh/claude/curl" no longer holds; they mock those binaries.
CI_EXCLUDED_SUITES=(
    # Already run by .github/workflows/orchestrator-guards.yml, which owns the
    # timeout invariant. Excluded here only to avoid paying for it twice.
    test-timeout-escalation.bats

    # Already run by .github/workflows/bundle-parity.yml, which owns the
    # canonical/bundle byte-identity contract. Same reason.
    test-bundle-parity.bats
)

# Prints the CI-safe suite list, one per line.
#
# With SHARD_INDEX/SHARD_TOTAL set, prints only this shard's slice. The whole
# list runs serially in well over 30 minutes on a CI runner — the first
# attempt at this workflow was killed by its own timeout — so the workflow
# fans it out across parallel jobs. Round-robin (NR % total) rather than
# contiguous blocks: suite runtimes vary by an order of magnitude, and
# interleaving spreads the slow ones instead of stacking them in one shard.
ci_suite_list() {
    local f excluded n=0
    for f in test-*.bats; do
        excluded=0
        for skip in "${CI_EXCLUDED_SUITES[@]}"; do
            [[ "$f" == "$skip" ]] && { excluded=1; break; }
        done
        (( excluded )) && continue
        if [[ -n "${SHARD_TOTAL:-}" && -n "${SHARD_INDEX:-}" ]]; then
            (( n % SHARD_TOTAL == SHARD_INDEX % SHARD_TOTAL )) \
                && printf '%s\n' "$f"
            n=$(( n + 1 ))
        else
            printf '%s\n' "$f"
        fi
    done
}

# =============================================================================
# HELP
# =============================================================================

show_help() {
    echo "Usage: $0 [OPTIONS] [TEST_FILE]"
    echo ""
    echo "Options:"
    echo "  --tap        Output in TAP format"
    echo "  --verbose    Verbose output"
    echo "  --ci         Run the CI-safe subset (all but CI_EXCLUDED_SUITES)"
    echo "  --list-ci    Print the CI-safe suite list and exit"
    echo "  --help       Show this help"
    echo ""
    echo "Test Files:"
    echo "  test-argument-parsing.bats    CLI argument parsing tests"
    echo "  test-status-functions.bats    Status file management tests"
    echo "  test-rate-limit.bats          Rate limit detection tests"
    echo "  test-stage-runner.bats        Stage runner function tests"
    echo "  test-quality-loop.bats        Quality loop helper tests"
    echo "  test-constants.bats           Configuration constants tests"
    echo "  test-helper-functions.bats    detect_change_scope / should_run_quality_loop / get_max_review_attempts tests"
    echo "  test-integration.bats         Integration tests"
    echo ""
    echo "Examples:"
    echo "  $0                            # Run all tests"
    echo "  $0 test-argument-parsing.bats # Run specific test file"
    echo "  $0 --verbose                  # Run all with verbose output"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local bats_args=()
    local test_files=()
    local ci_mode=0

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tap)
                bats_args+=("--formatter" "tap")
                shift
                ;;
            --verbose|-v)
                bats_args+=("--verbose-run")
                shift
                ;;
            --ci)
                # Run everything except CI_EXCLUDED_SUITES. Used by
                # .github/workflows/bats-suite.yml (issue #855).
                ci_mode=1
                shift
                ;;
            --list-ci)
                # Print the CI-safe list and exit — lets a contributor see
                # exactly what CI will run without running it.
                ci_suite_list
                exit 0
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *.bats)
                test_files+=("$1")
                shift
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                show_help
                exit 1
                ;;
        esac
    done

    # Check prerequisites
    check_prerequisites

    # If no test files specified, run all
    if (( ${#test_files[@]} == 0 )); then
        if (( ci_mode )); then
            # shellcheck disable=SC2207
            test_files=($(ci_suite_list))
        else
            test_files=(test-*.bats)
        fi
    fi

    # Verify test files exist
    for f in "${test_files[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo -e "${RED}Error: Test file not found: $f${NC}"
            exit 1
        fi
    done

    echo -e "${YELLOW}Running tests for implement-issue-orchestrator.sh${NC}"
    echo "Test files: ${test_files[*]}"
    echo ""

    # Run tests
    if bats ${bats_args[@]+"${bats_args[@]}"} "${test_files[@]}"; then
        echo ""
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    else
        echo ""
        echo -e "${RED}Some tests failed.${NC}"
        exit 1
    fi
}

main "$@"
