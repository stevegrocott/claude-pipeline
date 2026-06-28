#!/usr/bin/env bats
#
# tests/triage-classify-golden.bats
# Golden fixture tests for the triage-classify skill.
#
# Loads markdown fixtures from
#   .claude/scripts/implement-issue-test/fixtures/triage/
# and drives the skill-golden-lib.sh fixture runner with a mock claude
# binary that returns pre-baked triage JSON. Each test pins one routing
# outcome without live Claude invocations.
#
# Routing outcomes under test:
#   fast-path  — all six criteria pass → route=fast-path
#   full       — test_only_scope fails → route=full (non-test files)
#   disqualify — no_security_concerns fails → route=full (auth logic)
#
# The mock claude binary is configured via MOCK_CLAUDE_ROUTE:
#   fast-path   → returns fast-path JSON (all criteria passed)
#   disqualify  → returns full JSON with disqualifying_criterion=
#                 no_security_concerns
#   <any other> → returns full JSON with disqualifying_criterion=
#                 test_only_scope (default)
#
# Requires: bats >= 1.5.0, jq
#

# `run --separate-stderr` needs bats 1.5+.
bats_require_minimum_version 1.5.0

# Resolve paths once at load time so tests are CWD-independent.
REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
LIB_FILE="$REPO_ROOT/.claude/scripts/skill-golden-lib.sh"
PROMPT_FILE="$REPO_ROOT/.claude/scripts/prompts/triage-prompt.sh"
FIXTURE_DIR="$REPO_ROOT/.claude/scripts/implement-issue-test/fixtures/triage"
SCHEMA_FILE="$REPO_ROOT/.claude/scripts/schemas/implement-issue-triage.json"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Install mock claude before sourcing the lib so SG_CLAUDE_CLI is set.
	_install_mock_claude

	# Source in the test's subshell — functions are available to test body
	# because BATS runs setup() in the same subshell as the test case.
	# shellcheck source=/dev/null
	source "$LIB_FILE"
	# shellcheck source=/dev/null
	source "$PROMPT_FILE"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write pre-baked triage JSON response files to RESP_DIR.
# One file per routing outcome: fast-path.json, full.json, disqualify.json.
# Uses jq -cn so quoting and escaping are handled correctly.
_write_responses() {
	local resp_dir="$1"

	jq -cn '{structured_output: {
		status: "success",
		route: "fast-path",
		confidence: "high",
		disqualifying_criterion: null,
		established_pattern_grep: "test\\.use\\(",
		criteria: {
			test_only_scope: {
				passed: true,
				reason: "All paths are playwright specs"
			},
			surgical_size: {
				passed: true,
				reason: "Under 30 lines across 2 files"
			},
			established_pattern: {
				passed: true,
				reason: "storageState pattern in 5 existing specs"
			},
			precise_specification: {
				passed: true,
				reason: "File paths and line numbers provided"
			},
			benign_failure_mode: {
				passed: true,
				reason: "Only test files affected"
			},
			no_security_concerns: {
				passed: true,
				reason: "No auth logic involved"
			}
		},
		summary: "All six criteria pass; routing to fast-path.",
		error: null
	}}' > "$resp_dir/fast-path.json"

	jq -cn '{structured_output: {
		status: "success",
		route: "full",
		confidence: "high",
		disqualifying_criterion: "test_only_scope",
		established_pattern_grep: null,
		criteria: {
			test_only_scope: {
				passed: false,
				reason: "Includes apps/ source files alongside tests"
			},
			surgical_size: {
				passed: true,
				reason: "Small estimated diff"
			},
			established_pattern: {
				passed: true,
				reason: "Pattern found in existing code"
			},
			precise_specification: {
				passed: true,
				reason: "Specific file paths provided"
			},
			benign_failure_mode: {
				passed: false,
				reason: "Backend routes affected"
			},
			no_security_concerns: {
				passed: true,
				reason: "No security-sensitive logic"
			}
		},
		summary: "Non-test files in scope; routing to full.",
		error: null
	}}' > "$resp_dir/full.json"

	jq -cn '{structured_output: {
		status: "success",
		route: "full",
		confidence: "high",
		disqualifying_criterion: "no_security_concerns",
		established_pattern_grep: null,
		criteria: {
			test_only_scope: {
				passed: true,
				reason: "Auth spec files only"
			},
			surgical_size: {
				passed: true,
				reason: "Single-line diff"
			},
			established_pattern: {
				passed: true,
				reason: "Pattern found in existing specs"
			},
			precise_specification: {
				passed: true,
				reason: "File path and line number given"
			},
			benign_failure_mode: {
				passed: true,
				reason: "Test files only"
			},
			no_security_concerns: {
				passed: false,
				reason: "Auth login flow is touched"
			}
		},
		summary: "Auth test detected; no_security_concerns fails.",
		error: null
	}}' > "$resp_dir/disqualify.json"

	jq -cn '{structured_output: {
		status: "success",
		route: "full",
		confidence: "high",
		disqualifying_criterion: "established_pattern",
		established_pattern_grep: null,
		criteria: {
			test_only_scope: {
				passed: true,
				reason: "All paths are .bats test files under .claude/"
			},
			surgical_size: {
				passed: true,
				reason: "Small diff within pipeline bats files"
			},
			established_pattern: {
				passed: false,
				reason: "Pipeline bats changes have no established fast-path pattern"
			},
			precise_specification: {
				passed: true,
				reason: "Specific file paths provided"
			},
			benign_failure_mode: {
				passed: false,
				reason: "Pipeline test failures affect all downstream jobs"
			},
			no_security_concerns: {
				passed: true,
				reason: "No auth logic involved"
			}
		},
		summary: "Pipeline bats files lack established pattern; routing to full.",
		error: null
	}}' > "$resp_dir/bats-scope.json"
}

# Install a mock claude binary in $TEST_TMP/bin. The route returned is
# controlled at invocation time via MOCK_CLAUDE_ROUTE (see module header).
# Response files are located via MOCK_CLAUDE_RESP_DIR (exported here).
_install_mock_claude() {
	local mock_dir="$TEST_TMP/bin"
	local resp_dir="$TEST_TMP/responses"
	mkdir -p "$mock_dir" "$resp_dir"

	_write_responses "$resp_dir"

	export MOCK_CLAUDE_RESP_DIR="$resp_dir"

	# Single-quoted heredoc — no expansion; mock reads env vars at runtime.
	cat > "$mock_dir/claude" << 'MOCK'
#!/usr/bin/env bash
# Discard all CLI args; return pre-baked response based on MOCK_CLAUDE_ROUTE.
resp_dir="${MOCK_CLAUDE_RESP_DIR:-.}"
case "${MOCK_CLAUDE_ROUTE:-full}" in
	fast-path) cat "$resp_dir/fast-path.json" ;;
	disqualify) cat "$resp_dir/disqualify.json" ;;
	bats-scope) cat "$resp_dir/bats-scope.json" ;;
	*) cat "$resp_dir/full.json" ;;
esac
exit 0
MOCK
	chmod +x "$mock_dir/claude"
	export SG_CLAUDE_CLI="$mock_dir/claude"
}

# Run one manifest entry through sg_run_fixture and assert it produces a
# PASS line with exit status 0. Stderr is suppressed; only the fixture
# runner's formatted stdout line is captured for inspection.
#
# Usage: _assert_fixture_pass "fixture|expected_route|expected_criterion"
_assert_fixture_pass() {
	local entry="$1"
	local out rc

	out=$(sg_run_fixture "$entry" \
		"$FIXTURE_DIR" "$SCHEMA_FILE" "haiku" "build_prompt" \
		2>/dev/null)
	rc=$?

	if ((rc != 0)); then
		printf 'FAIL: sg_run_fixture returned %d for entry: %s\n' \
			"$rc" "$entry" >&2
		printf 'Captured output: %s\n' "$out" >&2
		return 1
	fi

	if [[ "$out" != *"PASS"* ]]; then
		printf 'FAIL: expected PASS in output for entry: %s\n' \
			"$entry" >&2
		printf 'Captured output: %s\n' "$out" >&2
		return 1
	fi
}

# ===========================================================================
# fast-path — all six criteria pass; route is fast-path
# ===========================================================================

@test "fast-path: issue-2836 routes to fast-path when all criteria pass" {
	[[ -f "$FIXTURE_DIR/issue-2836.md" ]] \
		|| skip "fixture issue-2836.md not found"

	export MOCK_CLAUDE_ROUTE=fast-path
	_assert_fixture_pass "issue-2836|fast-path|*"
}

# ===========================================================================
# full — test_only_scope criterion fails (non-test files in scope)
# ===========================================================================

@test "full: issue-2752 routes to full when test_only_scope fails" {
	[[ -f "$FIXTURE_DIR/issue-2752.md" ]] \
		|| skip "fixture issue-2752.md not found"

	export MOCK_CLAUDE_ROUTE=full
	_assert_fixture_pass "issue-2752|full|test_only_scope"
}

# ===========================================================================
# disqualify — no_security_concerns criterion fails (auth test)
# ===========================================================================

@test "disqualify: issue-auth-test routes to full on no_security_concerns" {
	[[ -f "$FIXTURE_DIR/issue-auth-test.md" ]] \
		|| skip "fixture issue-auth-test.md not found"

	export MOCK_CLAUDE_ROUTE=disqualify
	_assert_fixture_pass "issue-auth-test|full|no_security_concerns"
}

# ===========================================================================
# full — .claude/**/*.bats only scope must not fast-path (issue #511)
# ===========================================================================

@test "full: issue-bats-scope routes to full when tasks touch only .claude/**/*.bats" {
	[[ -f "$FIXTURE_DIR/issue-bats-scope.md" ]] \
		|| skip "fixture issue-bats-scope.md not found"

	export MOCK_CLAUDE_ROUTE=bats-scope
	_assert_fixture_pass "issue-bats-scope|full|established_pattern"
}
