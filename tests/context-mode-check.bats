#!/usr/bin/env bats
#
# tests/context-mode-check.bats
# Tests for .claude/scripts/context-mode-check.sh
#
# context-mode-check.sh is a smoke script that:
#   (1) runs `ctx doctor` and `ctx stats` when Context Mode is installed
#   (2) skips those checks gracefully when ctx is absent and
#       CONTEXT_MODE_ENABLED is 0 (the default)
#   (3) runs the orchestrator BATS parsing-assertion suite to confirm
#       output-parsing is unaffected by Context Mode
#
# Test cases:
#   HAPPY PATH
#     (a) --help exits 0 and prints usage
#     (b) ctx present + BATS passing → exit 0, PASS lines printed
#     (c) ctx absent + CONTEXT_MODE_ENABLED=0 + BATS passing → exit 0
#     (d) --skip-bats skips BATS suite; only ctx checks run
#     (e) --ctx-only skips BATS suite; only ctx checks run
#     (f) --bats-dir overrides the default test directory
#     (g) --bats-filter is forwarded to bats
#
#   CTX FAILURE CASES
#     (h) ctx absent + CONTEXT_MODE_ENABLED=1 → exit 1
#     (i) ctx doctor exits non-zero → exit 1
#     (j) ctx stats exits non-zero (doctor passes) → exit 1
#
#   BATS FAILURE CASES
#     (k) bats not in PATH → exit 2
#     (l) --bats-dir not found → exit 2
#     (m) bats-dir has no test-*.bats files → exit 2
#     (n) bats exits non-zero → exit 2
#
#   ARGUMENT ERRORS
#     (o) unknown option → exit 3
#     (p) --bats-dir missing value → exit 3
#     (q) --bats-filter missing value → exit 3
#     (r) unexpected positional argument → exit 3
#
#   DUAL-FAILURE CASE
#     (s) ctx failing AND bats failing → exit 4 (dedicated both-failed code)
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
SCRIPT_UNDER_TEST="$REPO_ROOT/.claude/scripts/context-mode-check.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Snapshot PATH so mock bins don't leak between tests
	_ORIGINAL_PATH="$PATH"

	# Create mock bin directory and prepend it to PATH
	mkdir -p "$TEST_TMP/bin"
	export PATH="$TEST_TMP/bin:$PATH"

	# Default: CONTEXT_MODE_ENABLED not set (0 behaviour)
	unset CONTEXT_MODE_ENABLED

	# Fake BATS test directory with two stub test files
	mkdir -p "$TEST_TMP/bats-dir"
	touch "$TEST_TMP/bats-dir/test-json-parsing.bats"
	touch "$TEST_TMP/bats-dir/test-verdict-parsing.bats"

	# Install default mocks (both pass by default)
	_install_mock_ctx 0 0
	_install_mock_bats 0
}

teardown() {
	export PATH="${_ORIGINAL_PATH:-$PATH}"
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Mock helpers
# ---------------------------------------------------------------------------

# _install_mock_ctx <doctor_exit> <stats_exit>
# Creates a `ctx` mock in $TEST_TMP/bin.  The mock reads exit-code env
# vars written to $TEST_TMP/mock_config.bash so individual tests can
# control behaviour without rebuilding the script.
_install_mock_ctx() {
	local doctor_exit="${1:-0}"
	local stats_exit="${2:-0}"

	cat > "$TEST_TMP/mock_config.bash" <<EOF
MOCK_CTX_DOCTOR_EXIT_CODE=${doctor_exit}
MOCK_CTX_STATS_EXIT_CODE=${stats_exit}
EOF

	cat > "$TEST_TMP/bin/ctx" << 'MOCK_EOF'
#!/usr/bin/env bash
source "${BASH_SOURCE%/*}/../mock_config.bash"
case "$1" in
    doctor)
        echo "Context Mode: healthy"
        exit "${MOCK_CTX_DOCTOR_EXIT_CODE:-0}"
        ;;
    stats)
        echo "Sessions: 3  Tokens saved: 4567"
        exit "${MOCK_CTX_STATS_EXIT_CODE:-0}"
        ;;
    *)
        echo "unknown ctx subcommand: $1" >&2
        exit 1
        ;;
esac
MOCK_EOF
	chmod +x "$TEST_TMP/bin/ctx"
}

# _install_mock_bats <exit_code>
# Creates a `bats` mock that emits two TAP ok-lines and exits with
# the given code.
_install_mock_bats() {
	local exit_code="${1:-0}"
	cat > "$TEST_TMP/bin/bats" <<EOF
#!/usr/bin/env bash
printf 'ok 1 test-json-parsing\\n'
printf 'ok 2 test-verdict-parsing\\n'
exit ${exit_code}
EOF
	chmod +x "$TEST_TMP/bin/bats"
}

# _remove_ctx removes the ctx mock so the script sees ctx as absent.
_remove_ctx() {
	rm -f "$TEST_TMP/bin/ctx"
}

# _remove_bats removes the bats mock so the script sees bats as absent.
_remove_bats() {
	rm -f "$TEST_TMP/bin/bats"
}

# =============================================================================
# HAPPY PATH
# =============================================================================

@test "(a) --help exits 0 and prints Usage" {
	run bash "$SCRIPT_UNDER_TEST" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage:"* ]]
	[[ "$output" == *"ctx doctor"* ]]
}

@test "(b) ctx present + BATS passing → exit 0, PASS lines emitted" {
	run bash "$SCRIPT_UNDER_TEST" \
		--bats-dir "$TEST_TMP/bats-dir"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS  ctx doctor"* ]]
	[[ "$output" == *"PASS  ctx stats"* ]]
	[[ "$output" == *"PASS  Orchestrator BATS suite"* ]]
}

@test "(c) ctx absent + CONTEXT_MODE_ENABLED=0 + BATS passing → exit 0" {
	_remove_ctx
	run bash "$SCRIPT_UNDER_TEST" \
		--bats-dir "$TEST_TMP/bats-dir"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS  Orchestrator BATS suite"* ]]
	# No FAIL lines
	[[ "$output" != *"FAIL"* ]]
}

@test "(d) --skip-bats skips BATS suite; ctx checks still run" {
	run bash "$SCRIPT_UNDER_TEST" --skip-bats
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS  ctx doctor"* ]]
	[[ "$output" == *"PASS  ctx stats"* ]]
	[[ "$output" != *"BATS suite"* ]]
}

@test "(e) --ctx-only skips BATS suite; ctx checks still run" {
	run bash "$SCRIPT_UNDER_TEST" --ctx-only
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS  ctx doctor"* ]]
	[[ "$output" == *"PASS  ctx stats"* ]]
	[[ "$output" != *"BATS suite"* ]]
}

@test "(f) --bats-dir overrides the default test directory" {
	local custom_dir="$TEST_TMP/custom-tests"
	mkdir -p "$custom_dir"
	touch "$custom_dir/test-custom.bats"

	run bash "$SCRIPT_UNDER_TEST" --bats-dir "$custom_dir"
	[ "$status" -eq 0 ]
	[[ "$output" == *"PASS  Orchestrator BATS suite"* ]]
}

@test "(g) --bats-filter is forwarded to bats" {
	# Create a bats mock that records its args
	cat > "$TEST_TMP/bin/bats" << 'FILTER_MOCK'
#!/usr/bin/env bash
# Write args so the test can inspect them
printf '%s\n' "$@" > "${TEST_TMP}/bats_args.txt"
printf 'ok 1 filtered-test\n'
exit 0
FILTER_MOCK
	chmod +x "$TEST_TMP/bin/bats"

	run bash "$SCRIPT_UNDER_TEST" \
		--bats-dir "$TEST_TMP/bats-dir" \
		--bats-filter "json-parsing"
	[ "$status" -eq 0 ]

	local recorded_args
	recorded_args=$(< "$TEST_TMP/bats_args.txt")
	[[ "$recorded_args" == *"--filter"* ]]
	[[ "$recorded_args" == *"json-parsing"* ]]
}

# =============================================================================
# CTX FAILURE CASES
# =============================================================================

@test "(h) ctx absent + CONTEXT_MODE_ENABLED=1 → exit 1" {
	_remove_ctx
	CONTEXT_MODE_ENABLED=1 \
		run bash "$SCRIPT_UNDER_TEST" --skip-bats
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"CONTEXT_MODE_ENABLED=1"* ]]
}

@test "(i) ctx doctor exits non-zero → exit 1" {
	_install_mock_ctx 1 0
	run bash "$SCRIPT_UNDER_TEST" --skip-bats
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL  ctx doctor"* ]]
}

@test "(j) ctx stats exits non-zero (doctor passes) → exit 1" {
	_install_mock_ctx 0 1
	run bash "$SCRIPT_UNDER_TEST" --skip-bats
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL  ctx stats"* ]]
}

# =============================================================================
# BATS FAILURE CASES
# =============================================================================

@test "(k) bats not in PATH → exit 2" {
	_remove_bats
	# Use `env PATH=...` to restrict the subprocess PATH so the system bats
	# (e.g. /opt/homebrew/bin/bats) is not visible, while keeping /bin and
	# /usr/bin so bash and builtins work correctly.
	run env PATH="$TEST_TMP/bin:/bin:/usr/bin" \
		bash "$SCRIPT_UNDER_TEST" \
		--bats-dir "$TEST_TMP/bats-dir"
	[ "$status" -eq 2 ]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"bats not found"* ]]
}

@test "(l) --bats-dir path does not exist → exit 2" {
	run bash "$SCRIPT_UNDER_TEST" \
		--bats-dir "$TEST_TMP/nonexistent"
	[ "$status" -eq 2 ]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"not found"* ]]
}

@test "(m) bats-dir exists but has no test-*.bats files → exit 2" {
	local empty_dir="$TEST_TMP/empty-tests"
	mkdir -p "$empty_dir"
	run bash "$SCRIPT_UNDER_TEST" \
		--bats-dir "$empty_dir"
	[ "$status" -eq 2 ]
	[[ "$output" == *"FAIL"* ]]
	[[ "$output" == *"No test-*.bats"* ]]
}

@test "(n) bats exits non-zero → exit 2" {
	_install_mock_bats 1
	run bash "$SCRIPT_UNDER_TEST" \
		--bats-dir "$TEST_TMP/bats-dir"
	[ "$status" -eq 2 ]
	[[ "$output" == *"FAIL  Orchestrator BATS suite"* ]]
}

# =============================================================================
# ARGUMENT ERRORS
# =============================================================================

@test "(o) unknown option → exit 3" {
	run bash "$SCRIPT_UNDER_TEST" --unknown-flag
	[ "$status" -eq 3 ]
	[[ "$output" == *"error"* ]]
}

@test "(p) --bats-dir missing value → exit 3" {
	run bash "$SCRIPT_UNDER_TEST" --bats-dir
	[ "$status" -eq 3 ]
	[[ "$output" == *"error"* ]]
}

@test "(q) --bats-filter missing value → exit 3" {
	run bash "$SCRIPT_UNDER_TEST" --bats-filter
	[ "$status" -eq 3 ]
	[[ "$output" == *"error"* ]]
}

@test "(r) unexpected positional argument → exit 3" {
	run bash "$SCRIPT_UNDER_TEST" unexpected-arg
	[ "$status" -eq 3 ]
	[[ "$output" == *"error"* ]]
}

# =============================================================================
# DUAL-FAILURE CASE
# =============================================================================

@test "(s) ctx failing AND bats failing → exit 4 (both-failed code)" {
	_install_mock_ctx 1 0
	_install_mock_bats 1
	# $output contains merged stdout+stderr (BATS default; no --separate-stderr).
	# bats_require_minimum_version 1.5.0 at L44 covers this merge behaviour.
	run bash "$SCRIPT_UNDER_TEST" \
		--bats-dir "$TEST_TMP/bats-dir"
	[ "$status" -eq 4 ]
	[[ "$output" == *"FAIL  ctx doctor"* ]]
	[[ "$output" == *"FAIL  Orchestrator BATS suite"* ]]
}
