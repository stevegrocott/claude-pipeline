#!/usr/bin/env bats
#
# test-context-mode-check.bats
# Tests for context-mode-check.sh — check_ctx() binary resolution
#

# ---------------------------------------------------------------------------
# Setup / teardown
# ---------------------------------------------------------------------------

setup() {
	# BATS_TEST_DIRNAME is the real on-disk directory of this test file
	SCRIPT_UNDER_TEST="$BATS_TEST_DIRNAME/../context-mode-check.sh"
	export SCRIPT_UNDER_TEST

	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Lay down a mock bin directory so tests control which binaries exist
	mkdir -p "$TEST_TMP/bin"
}

teardown() {
	[[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run context-mode-check.sh with --ctx-only.
#
# Uses a MINIMAL PATH ($TEST_TMP/bin + standard POSIX dirs only) so that
# system-installed ctx / context-mode binaries (e.g. from Homebrew) never
# shadow the test mocks and cannot be found when no mock is provided.
# Callers place mock binaries in $TEST_TMP/bin before calling this helper.
#
# Usage: _run_check [KEY=val ...] [extra-flags]
#   KEY=val args are forwarded via env(1) before the mock PATH.
_run_check() {
	local -a env_args=("PATH=$TEST_TMP/bin:/usr/bin:/bin")
	local -a script_args=("--ctx-only")

	# Collect leading KEY=val arguments and pass them via env
	while [[ "${1:-}" == *=* ]]; do
		env_args+=("$1")
		shift
	done
	# Remaining args forwarded to the script (e.g. extra flags)
	script_args+=("$@")

	run env -i HOME="$HOME" "${env_args[@]}" \
		bash "$SCRIPT_UNDER_TEST" "${script_args[@]}"
}

# Write an executable mock binary to $TEST_TMP/bin.
# Usage: _write_mock <name> [exit_code]
_write_mock() {
	local name="$1"
	local exit_code="${2:-0}"
	printf '#!/usr/bin/env bash\necho "mock-%s $*"\nexit %s\n' \
		"$name" "$exit_code" > "$TEST_TMP/bin/$name"
	chmod +x "$TEST_TMP/bin/$name"
}

# =============================================================================
# BINARY RESOLUTION — prefer ctx over context-mode
# =============================================================================

@test "uses ctx when only ctx is in PATH" {
	_write_mock ctx 0
	_run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"mock-ctx doctor"* ]]
	[[ "$output" == *"mock-ctx stats"* ]]
}

@test "falls back to context-mode when ctx is absent" {
	_write_mock context-mode 0
	_run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"mock-context-mode doctor"* ]]
	[[ "$output" == *"mock-context-mode stats"* ]]
}

@test "prefers ctx over context-mode when both are present" {
	_write_mock ctx 0
	_write_mock context-mode 0
	_run_check
	[ "$status" -eq 0 ]
	[[ "$output" == *"mock-ctx doctor"* ]]
	[[ "$output" != *"mock-context-mode"* ]]
}

# =============================================================================
# MISSING BINARY — graceful skip (CONTEXT_MODE_ENABLED=0)
# =============================================================================

@test "skips gracefully when neither binary present and CONTEXT_MODE_ENABLED=0" {
	_run_check CONTEXT_MODE_ENABLED=0
	[ "$status" -eq 0 ]
	[[ "$output" != *"FAIL"* ]]
}

@test "default CONTEXT_MODE_ENABLED is 0 — skips when binaries absent" {
	_run_check
	[ "$status" -eq 0 ]
	[[ "$output" != *"FAIL"* ]]
}

# =============================================================================
# MISSING BINARY — hard fail (CONTEXT_MODE_ENABLED=1)
# =============================================================================

@test "fails with exit 1 when neither binary present and CONTEXT_MODE_ENABLED=1" {
	_run_check CONTEXT_MODE_ENABLED=1
	[ "$status" -eq 1 ]
}

@test "FAIL message names ctx when neither binary is installed" {
	_run_check CONTEXT_MODE_ENABLED=1
	[[ "$output" == *"ctx"* ]]
}

@test "FAIL message names context-mode when neither binary is installed" {
	_run_check CONTEXT_MODE_ENABLED=1
	[[ "$output" == *"context-mode"* ]]
}

@test "FAIL message references CONTEXT_MODE_ENABLED=1 requirement" {
	_run_check CONTEXT_MODE_ENABLED=1
	[[ "$output" == *"CONTEXT_MODE_ENABLED=1"* ]]
}

# =============================================================================
# DOCTOR / STATS FAILURE PROPAGATION
# =============================================================================

@test "returns exit 1 when ctx doctor fails" {
	cat > "$TEST_TMP/bin/ctx" <<-'SH'
		#!/usr/bin/env bash
		if [[ "$*" == "doctor" ]]; then
			echo "doctor-error" >&2
			exit 1
		fi
		echo "ok"
		exit 0
	SH
	chmod +x "$TEST_TMP/bin/ctx"

	_run_check
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
}

@test "returns exit 1 when ctx stats fails" {
	cat > "$TEST_TMP/bin/ctx" <<-'SH'
		#!/usr/bin/env bash
		if [[ "$*" == "stats" ]]; then
			echo "stats-error" >&2
			exit 1
		fi
		echo "ok"
		exit 0
	SH
	chmod +x "$TEST_TMP/bin/ctx"

	_run_check
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
}

@test "returns exit 1 when context-mode doctor fails" {
	cat > "$TEST_TMP/bin/context-mode" <<-'SH'
		#!/usr/bin/env bash
		if [[ "$*" == "doctor" ]]; then
			echo "doctor-error" >&2
			exit 1
		fi
		echo "ok"
		exit 0
	SH
	chmod +x "$TEST_TMP/bin/context-mode"

	_run_check
	[ "$status" -eq 1 ]
	[[ "$output" == *"FAIL"* ]]
}
