#!/usr/bin/env bats
#
# tests/post-pr-simplify.bats
# Verifies the PostToolUse(Bash) hook at .claude/hooks/post-pr-simplify.sh
# produces the correct decision (allow/block) after a PR is created (issue
# #782).
#
# Background: the hook used to hard-block every PR with >=100 added lines
# OR >=10 changed files, instructing the model to run a `code-simplifier`
# subagent that the plugin never ships (not in plugins/pipeline-core/, not
# in this repo's .claude/agents/, not in any consumer). The instruction was
# unsatisfiable, so the block could never be cleared. The fix makes the hook
# resolve the agent under .claude/agents/ (rooted at $CLAUDE_PROJECT_DIR,
# matching the resolution convention already used by sibling hooks such as
# pre-commit-skill-validate.sh and sync-reminder.sh) before blocking: absent
# -> allow with a warning naming the missing agent; present -> unchanged
# block behaviour.
#
# Per issue #782 AC4, this suite is expected to fail against the
# unmodified hook (it still blocks unconditionally on a large PR
# regardless of whether code-simplifier is resolvable).

bats_require_minimum_version 1.5.0

HOOK="${BATS_TEST_DIRNAME}/../.claude/hooks/post-pr-simplify.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
#
# CLAUDE_PROJECT_DIR is pointed at a scratch directory for every test, and
# the hook is always invoked with that same directory as its cwd, so the
# fixture works whichever of the two the real fix resolves the consumer's
# .claude/agents/ directory from.
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	mkdir -p "$TEST_TMP/.claude/agents" "$TEST_TMP/bin"

	_ORIGINAL_PATH="$PATH"
	_HAD_CLAUDE_PROJECT_DIR=0
	if [[ -n "${CLAUDE_PROJECT_DIR+set}" ]]; then
		_ORIGINAL_CLAUDE_PROJECT_DIR="$CLAUDE_PROJECT_DIR"
		_HAD_CLAUDE_PROJECT_DIR=1
	fi
	export CLAUDE_PROJECT_DIR="$TEST_TMP"
}

teardown() {
	export PATH="$_ORIGINAL_PATH"
	if [[ "$_HAD_CLAUDE_PROJECT_DIR" -eq 1 ]]; then
		export CLAUDE_PROJECT_DIR="$_ORIGINAL_CLAUDE_PROJECT_DIR"
	else
		unset CLAUDE_PROJECT_DIR
	fi
	[[ -n "$TEST_TMP" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Installs a mock `gh` on PATH whose `pr view --json files,additions` reports
# the given additions count and number of changed files, so the hook's
# stats come from a deterministic fixture rather than a real GitHub call.
_mock_gh_pr_view() {
	local additions="$1" file_count="$2"
	jq -n --argjson additions "$additions" --argjson file_count "$file_count" \
		'{additions: $additions, files: [range($file_count) | {path: ("file" + (. + 1 | tostring) + ".txt")}]}' \
		>"$TEST_TMP/gh_pr_view.json"

	cat >"$TEST_TMP/bin/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
	cat "$TEST_TMP/gh_pr_view.json"
	exit 0
fi
exit 1
EOF
	chmod +x "$TEST_TMP/bin/gh"
	export PATH="$TEST_TMP/bin:$PATH"
}

# Runs the hook with a PostToolUse(Bash) payload for a successful
# `gh pr create`, whose stdout contains the given PR URL. Sets $status /
# $output (bats `run`). The hook always runs with cwd == $TEST_TMP.
_run_hook() {
	local pr_url="$1"
	local payload
	payload=$(jq -n --arg cmd 'gh pr create --title x --body y' \
		--arg out "https://cli.github.com/  Created pull request: ${pr_url}" \
		'{tool_name: "Bash", tool_input: {command: $cmd}, tool_response: {stdout: $out}}')
	run bash -c "cd '$TEST_TMP' && printf '%s' \"\$1\" | bash '$HOOK'" _ "$payload"
}

_decision() {
	printf '%s' "$output" | jq -r '.decision'
}

_reason() {
	printf '%s' "$output" | jq -r '.reason'
}

# ---------------------------------------------------------------------------

@test "hook exists and is executable" {
	[ -f "$HOOK" ]
	[ -x "$HOOK" ]
}

# ---------------------------------------------------------------------------
# AC1 / AC3 — agent unresolvable: allow with a warning naming it
# ---------------------------------------------------------------------------

@test "(#782 AC1) allows a large PR when code-simplifier cannot be resolved" {
	_mock_gh_pr_view 150 3
	_run_hook "https://github.com/testorg/testrepo/pull/42"

	[ "$status" -eq 0 ]
	[ "$(_decision)" = "allow" ]
}

@test "(#782 AC3) warning names the missing agent and where to add it" {
	_mock_gh_pr_view 150 3
	_run_hook "https://github.com/testorg/testrepo/pull/42"

	local reason
	reason=$(_reason)
	[[ "$reason" == *"code-simplifier"* ]] || {
		printf 'FAIL: warning does not name the missing agent:\n%s\n' "$reason" >&2
		return 1
	}
	[[ "$reason" == *".claude/agents"* ]] || {
		printf 'FAIL: warning does not say where to supply the agent:\n%s\n' "$reason" >&2
		return 1
	}
}

@test "(#782 AC1) large-PR-by-file-count also allows when code-simplifier cannot be resolved" {
	_mock_gh_pr_view 20 12
	_run_hook "https://github.com/testorg/testrepo/pull/43"

	[ "$(_decision)" = "allow" ]
}

# ---------------------------------------------------------------------------
# AC2 — agent resolvable: behaviour unchanged (still blocks large PRs)
# ---------------------------------------------------------------------------

@test "(#782 AC2) still blocks a large PR when code-simplifier is resolvable" {
	: >"$TEST_TMP/.claude/agents/code-simplifier.md"
	_mock_gh_pr_view 150 3
	_run_hook "https://github.com/testorg/testrepo/pull/44"

	[ "$status" -eq 0 ]
	[ "$(_decision)" = "block" ]

	local reason
	reason=$(_reason)
	[[ "$reason" == *"code-simplifier"* ]]
	[[ "$reason" == *"Task tool"* ]]
}

# ---------------------------------------------------------------------------
# AC5 — small PR: unaffected, still allows with the existing suggestion
# ---------------------------------------------------------------------------

@test "(#782 AC5) allows a small PR with the existing suggestion text (agent absent)" {
	_mock_gh_pr_view 50 2
	_run_hook "https://github.com/testorg/testrepo/pull/7"

	[ "$(_decision)" = "allow" ]
	[[ "$(_reason)" == *"small PR"* ]]
}

@test "(#782 AC5) allows a small PR with the existing suggestion text (agent present)" {
	: >"$TEST_TMP/.claude/agents/code-simplifier.md"
	_mock_gh_pr_view 50 2
	_run_hook "https://github.com/testorg/testrepo/pull/8"

	[ "$(_decision)" = "allow" ]
	[[ "$(_reason)" == *"small PR"* ]]
}
