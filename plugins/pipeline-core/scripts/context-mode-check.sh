#!/usr/bin/env bash
#
# context-mode-check.sh
# Smoke check for Context Mode integration health.
#
# Wraps `ctx doctor`/`ctx stats` (or `context-mode doctor`/`context-mode stats`)
# and runs the orchestrator BATS parsing-assertion suite to confirm
# output-parsing is unaffected when Context Mode is active.
#
# Usage: context-mode-check.sh [options]
#
# Options:
#   -h, --help           Show this help message
#   --skip-bats          Skip the BATS parsing-assertion suite
#   --ctx-only           Run ctx checks only; skip BATS suite
#   --bats-dir <path>    BATS test directory
#                        (default: .claude/scripts/implement-issue-test)
#   --bats-filter <pat>  bats --filter pattern (default: all tests)
#
# Environment:
#   CONTEXT_MODE_ENABLED  1 = ctx must be present (exit 1 when absent).
#                         0 (default) = skip gracefully when ctx missing.
#
# Exit codes:
#   0  all enabled checks passed (or gracefully skipped)
#   1  ctx health check failed (BATS not run or passed)
#   2  BATS parsing-assertion suite failed (ctx passed or was skipped)
#   3  usage / configuration error
#   4  BOTH ctx and BATS failed; both FAIL lines are printed to stderr
#

set -uo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Default BATS dir: co-located with the orchestrator scripts
readonly DEFAULT_BATS_DIR="$SCRIPT_DIR/implement-issue-test"

# =============================================================================
# OUTPUT HELPERS
# =============================================================================

log() {
	printf '[%s] %s\n' "$SCRIPT_NAME" "$*" >&2
}

result_pass() {
	printf 'PASS  %s\n' "$*"
}

result_fail() {
	printf 'FAIL  %s\n' "$*" >&2
}

die() {
	printf '%s: error: %s\n' "$SCRIPT_NAME" "$*" >&2
	exit 3
}

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME [options]

Smoke check for Context Mode integration health.

Wraps 'ctx doctor' and 'ctx stats', then runs the orchestrator BATS
parsing-assertion suite to confirm output-parsing is unaffected.

Options:
    -h, --help           Show this help message
    --skip-bats          Skip the BATS parsing-assertion suite
    --ctx-only           Run ctx checks only; skip BATS suite
    --bats-dir <path>    BATS test directory
                         (default: $DEFAULT_BATS_DIR)
    --bats-filter <pat>  bats --filter pattern (default: all tests)

Environment:
    CONTEXT_MODE_ENABLED  1 = ctx must be present (exit 1 when absent).
                          0 (default) = skip ctx gracefully when not
                          installed.

Exit codes:
    0  all enabled checks passed (or gracefully skipped)
    1  ctx health check failed (BATS not run or passed)
    2  BATS parsing-assertion suite failed (ctx passed or was skipped)
    3  usage / configuration error
    4  BOTH ctx and BATS failed; both FAIL lines are printed to stderr
EOF
}

# =============================================================================
# CTX CHECKS
# =============================================================================

check_ctx() {
	local ctx_enabled="${CONTEXT_MODE_ENABLED:-0}"

	# Resolve the CLI binary once — prefer ctx, fall back to context-mode
	local cli_bin=""
	if command -v ctx &>/dev/null; then
		cli_bin="ctx"
	elif command -v context-mode &>/dev/null; then
		cli_bin="context-mode"
	fi

	if [[ -z "$cli_bin" ]]; then
		if [[ "$ctx_enabled" == "1" ]]; then
			result_fail \
				"ctx (or context-mode) not installed;" \
				"CONTEXT_MODE_ENABLED=1 requires it"
			return 1
		fi
		log "ctx / context-mode not in PATH;" \
			"skipping (install plugin to enable)"
		return 0
	fi

	# --- doctor ---
	log "Running: $cli_bin doctor"
	local doctor_out
	if ! doctor_out=$("$cli_bin" doctor 2>&1); then
		result_fail "$cli_bin doctor"
		printf '%s\n' "$doctor_out" >&2
		return 1
	fi
	result_pass "$cli_bin doctor"
	printf '%s\n' "$doctor_out"

	# --- stats ---
	log "Running: $cli_bin stats"
	local stats_out
	if ! stats_out=$("$cli_bin" stats 2>&1); then
		result_fail "$cli_bin stats"
		printf '%s\n' "$stats_out" >&2
		return 1
	fi
	result_pass "$cli_bin stats"
	printf '%s\n' "$stats_out"

	return 0
}

# =============================================================================
# BATS PARSING ASSERTION
# =============================================================================

check_bats() {
	local bats_dir="$1"
	local bats_filter="$2"

	if ! command -v bats &>/dev/null; then
		result_fail "bats not found; install bats-core to run assertions"
		return 2
	fi

	if [[ ! -d "$bats_dir" ]]; then
		result_fail "BATS test directory not found: $bats_dir"
		return 2
	fi

	# Collect test files; nullglob ensures empty array on no match
	local -a test_files=()
	shopt -s nullglob
	test_files=("$bats_dir"/test-*.bats)
	shopt -u nullglob

	if (( ${#test_files[@]} == 0 )); then
		result_fail "No test-*.bats files found in: $bats_dir"
		return 2
	fi

	local -a bats_args=()
	if [[ -n "$bats_filter" ]]; then
		bats_args+=("--filter" "$bats_filter")
	fi

	log "Running orchestrator BATS suite" \
		"(${#test_files[@]} files): $bats_dir"

	local bats_out
	if ! bats_out=$(
		bats "${bats_args[@]+"${bats_args[@]}"}" \
			"${test_files[@]}" 2>&1
	); then
		result_fail "Orchestrator BATS suite: parsing assertions failed"
		printf '%s\n' "$bats_out" >&2
		return 2
	fi

	local passed_count=0
	passed_count=$(
		printf '%s\n' "$bats_out" | grep -c '^ok ' || true
	)
	result_pass "Orchestrator BATS suite (${passed_count} tests passed)"
	return 0
}

# =============================================================================
# MAIN
# =============================================================================

main() {
	local skip_bats=false
	local ctx_only=false
	local bats_dir="$DEFAULT_BATS_DIR"
	local bats_filter=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
			-h|--help)
				usage
				exit 0
				;;
			--skip-bats)
				skip_bats=true
				shift
				;;
			--ctx-only)
				ctx_only=true
				shift
				;;
			--bats-dir)
				[[ $# -ge 2 ]] || die "--bats-dir requires a value"
				bats_dir="$2"
				shift 2
				;;
			--bats-filter)
				[[ $# -ge 2 ]] || die "--bats-filter requires a value"
				bats_filter="$2"
				shift 2
				;;
			--)
				shift
				break
				;;
			-*)
				die "unknown option: $1"
				;;
			*)
				die "unexpected argument: $1"
				;;
		esac
	done

	local overall_exit=0
	local ctx_failed=false

	# ctx health checks
	if ! check_ctx; then
		overall_exit=1
		ctx_failed=true
	fi

	# Orchestrator parsing-assertion suite
	if [[ "$ctx_only" == false && "$skip_bats" == false ]]; then
		if ! check_bats "$bats_dir" "$bats_filter"; then
			# When ctx also failed, use exit code 4 so callers can distinguish
			# "only BATS failed" (2) from "both checks failed" (4).  Both FAIL
			# lines are always printed to stderr for the human reading the log.
			if $ctx_failed; then
				overall_exit=4
			else
				overall_exit=2
			fi
		fi
	fi

	if [[ "$overall_exit" -eq 0 ]]; then
		printf '\n%s: all checks passed\n' "$SCRIPT_NAME"
	else
		printf '\n%s: one or more checks failed (exit %d)\n' \
			"$SCRIPT_NAME" "$overall_exit" >&2
	fi

	return "$overall_exit"
}

main "$@"
