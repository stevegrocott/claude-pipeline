#!/usr/bin/env bash
#
# run-tests.sh
# Test runner for platform wrapper script tests
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
# HELP
# =============================================================================

show_help() {
    echo "Usage: $0 [OPTIONS] [TEST_FILE]"
    echo ""
    echo "Options:"
    echo "  --tap        Output in TAP format"
    echo "  --verbose    Verbose output"
    echo "  --help       Show this help"
    echo ""
    echo "Test Files:"
    echo "  test-create-issue.bats       Issue creation tests (GitHub + Jira)"
    echo "  test-read-issue.bats         Issue reading tests (GitHub + Jira)"
    echo "  test-transition-issue.bats   Issue transition / close tests"
    echo "  test-create-mr.bats          MR/PR creation tests (GitHub + GitLab)"
    echo "  test-merge-mr.bats           MR/PR merge tests (squash/merge/rebase)"
    echo "  test-list-issues.bats        Issue listing tests (GitHub + Jira)"
    echo "  test-find-mr.bats            MR/PR lookup by branch tests"
    echo ""
    echo "Examples:"
    echo "  $0                            # Run all tests"
    echo "  $0 test-create-mr.bats        # Run specific test file"
    echo "  $0 --verbose                  # Run all with verbose output"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local bats_args=()
    local test_files=()

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
        test_files=(test-*.bats)
    fi

    # Verify test files exist
    for f in "${test_files[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo -e "${RED}Error: Test file not found: $f${NC}"
            exit 1
        fi
    done

    echo -e "${YELLOW}Running tests for platform wrapper scripts${NC}"
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
