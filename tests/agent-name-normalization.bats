#!/usr/bin/env bats
#
# tests/agent-name-normalization.bats
# Coverage for the agent-name normalization added in issue #313:
#   * _normalize_agent_name() — legacy alias remapping + "default" fallback for
#     names with no local .claude/agents/<name>.md definition.
#   * _parse_task_lines() — bracket-less `agent` selectors are accepted
#     silently (no "Fuzzy task parse" warning) and normalized; other
#     malformations still emit a fuzzy warning.
#
# These functions live in implement-issue-orchestrator.sh.  They are sourced
# in-process via an awk range extraction (the same pattern used by
# decide-action.bats and event-emission.bats).  If a function does not exist
# yet (the orchestrator change for issue #313 not merged), the awk range
# matches nothing, the function stays undefined, and the relevant tests fail
# as expected (RED) until the implementation lands.
#

bats_require_minimum_version 1.5.0

REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
ORCHESTRATOR="$REPO_ROOT/.claude/scripts/implement-issue-orchestrator.sh"
AGENTS_DIR="$REPO_ROOT/.claude/agents"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# _normalize_agent_name resolves "${SCRIPT_DIR}/../agents/<name>.md", so
	# SCRIPT_DIR must point at the real scripts directory.
	export SCRIPT_DIR="$REPO_ROOT/.claude/scripts"
	export SCRIPT_NAME="agent-name-normalization-test"

	# Empty LOG_FILE → log/log_warn write only to stderr (no file needed).
	export LOG_FILE=""
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Source the orchestrator functions exercised by these tests.  Header lines
# (readonly / set -o) are skipped so the test can supply SCRIPT_DIR etc.
_source_orchestrator_functions() {
	local func_file="$TEST_TMP/orchestrator_funcs.bash"
	awk '
		/^readonly /                              { next }
		/^set -o /                                { next }
		/^log\(\) \{$/,/^\}$/                    { print; next }
		/^log_warn\(\) \{$/,/^\}$/               { print; next }
		/^_normalize_agent_name\(\) \{$/,/^\}$/  { print; next }
		/^_parse_task_lines\(\) \{$/,/^\}$/      { print; next }
	' "$ORCHESTRATOR" > "$func_file"
	# shellcheck disable=SC1090
	source "$func_file"
}

# Parse a single task line and echo the agent recorded for task 1.
_agent_of_first_task() {
	local line="$1"
	_parse_task_lines "$line" | jq -r '.[0].agent'
}

# ===========================================================================
# _normalize_agent_name()
# ===========================================================================

@test "(1) _normalize_agent_name maps legacy 'test-engineer' to 'playwright-test-developer'" {
	[[ -f "$ORCHESTRATOR" ]] || fail "orchestrator script not present"
	[[ -f "$AGENTS_DIR/playwright-test-developer.md" ]] \
		|| fail "fixture precondition: playwright-test-developer.md must exist"

	_source_orchestrator_functions

	run --separate-stderr _normalize_agent_name "test-engineer"
	[ "$status" -eq 0 ]
	[ "$output" = "playwright-test-developer" ] || {
		printf 'FAIL: expected playwright-test-developer, got: %q\n' "$output" >&2
		return 1
	}
}

@test "(2) _normalize_agent_name leaves a known local agent unchanged" {
	[[ -f "$AGENTS_DIR/bash-script-craftsman.md" ]] \
		|| fail "fixture precondition: bash-script-craftsman.md must exist"

	_source_orchestrator_functions

	run --separate-stderr _normalize_agent_name "bash-script-craftsman"
	[ "$status" -eq 0 ]
	[ "$output" = "bash-script-craftsman" ]
}

@test "(3) _normalize_agent_name falls back to 'default' for a name with no local definition" {
	[[ ! -f "$AGENTS_DIR/totally-bogus-agent.md" ]] \
		|| skip "unexpected: totally-bogus-agent.md exists in the repo"

	_source_orchestrator_functions

	run --separate-stderr _normalize_agent_name "totally-bogus-agent"
	[ "$status" -eq 0 ]
	[ "$output" = "default" ] || {
		printf 'FAIL: expected default, got: %q\n' "$output" >&2
		return 1
	}
}

@test "(4) _normalize_agent_name falls back to 'default' for an empty name" {
	_source_orchestrator_functions

	run --separate-stderr _normalize_agent_name ""
	[ "$status" -eq 0 ]
	[ "$output" = "default" ]
}

# ===========================================================================
# _parse_task_lines() — normalization + bracket-less selector handling
# ===========================================================================

@test "(5) _parse_task_lines normalizes a bracketed legacy agent name in its JSON output" {
	_source_orchestrator_functions

	local line='- [ ] `[test-engineer]` **(S)** Add coverage — `tests/`'
	local agent
	agent="$(_agent_of_first_task "$line")"
	[ "$agent" = "playwright-test-developer" ] || {
		printf 'FAIL: expected playwright-test-developer, got: %q\n' "$agent" >&2
		return 1
	}
}

@test "(6) _parse_task_lines accepts a bracket-less backtick selector with no fuzzy warning" {
	_source_orchestrator_functions

	local line='- [ ] `playwright-test-developer` **(S)** Add coverage — `tests/`'
	run --separate-stderr _parse_task_lines "$line"
	[ "$status" -eq 0 ]

	# No "Fuzzy task parse" warning of any kind for a bare backtick selector.
	[[ "$stderr" != *"Fuzzy task parse"* ]] || {
		printf 'FAIL: did not expect a fuzzy-parse warning, got stderr:\n%s\n' \
			"$stderr" >&2
		return 1
	}

	# The task is still parsed and the agent is preserved.
	local agent
	agent="$(printf '%s' "$output" | jq -r '.[0].agent')"
	[ "$agent" = "playwright-test-developer" ]
}

@test "(7) _parse_task_lines normalizes a bracket-less legacy selector to the mapped agent" {
	_source_orchestrator_functions

	local line='- [ ] `test-engineer` **(S)** Add coverage — `tests/`'
	run --separate-stderr _parse_task_lines "$line"
	[ "$status" -eq 0 ]
	[[ "$stderr" != *"Fuzzy task parse"* ]]

	local agent
	agent="$(printf '%s' "$output" | jq -r '.[0].agent')"
	[ "$agent" = "playwright-test-developer" ] || {
		printf 'FAIL: expected playwright-test-developer, got: %q\n' "$agent" >&2
		return 1
	}
}

@test "(8) _parse_task_lines still emits a fuzzy warning for a missing-backticks malformation" {
	_source_orchestrator_functions

	# Square brackets, no backticks — a genuine formatting problem that must
	# still be surfaced (the bracket-less change must not silence everything).
	local line='- [ ] [playwright-test-developer] **(S)** Add coverage — `tests/`'
	run --separate-stderr _parse_task_lines "$line"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"Fuzzy task parse"* ]] || {
		printf 'FAIL: expected a fuzzy-parse warning, got stderr:\n%s\n' \
			"$stderr" >&2
		return 1
	}
}

@test "(9) _parse_task_lines normalizes an unknown agent name to 'default'" {
	[[ ! -f "$AGENTS_DIR/totally-bogus-agent.md" ]] \
		|| skip "unexpected: totally-bogus-agent.md exists in the repo"

	_source_orchestrator_functions

	local line='- [ ] `[totally-bogus-agent]` **(S)** Add coverage — `tests/`'
	local agent
	agent="$(_agent_of_first_task "$line")"
	[ "$agent" = "default" ] || {
		printf 'FAIL: expected default, got: %q\n' "$agent" >&2
		return 1
	}
}
