#!/usr/bin/env bats
#
# block-gh-issue-create.bats
# Verifies the PreToolUse(Bash) guard at
# .claude/hooks/block-gh-issue-create.sh hard-blocks direct `gh issue create`
# invocations (exit 2) while allowing the validated wrapper scripts and every
# other gh subcommand (exit 0).
#
# The hook exists because #501 (SKILL instruction) and #513 (permission
# allowlist) are soft guardrails; this hook is the hard technical gate that
# forces all issue creation through create-followup-issue.sh /
# platform/create-issue.sh, which run assert_issue_valid fail-closed.

HOOK="${BATS_TEST_DIRNAME}/../.claude/hooks/block-gh-issue-create.sh"

# Run the hook with a given Bash command as the PreToolUse payload.
# Sets $status (0 = allow, 2 = block).
_run_hook() {
	local cmd="$1"
	run bash -c "printf '%s' \"\$1\" | jq -Rn '{tool_input:{command:input}}' | bash '$HOOK'" _ "$cmd"
}

@test "hook exists and is executable" {
	[ -f "$HOOK" ]
	[ -x "$HOOK" ]
}

# ---------------------------------------------------------------------------
# BLOCK — direct gh issue create in any form
# ---------------------------------------------------------------------------

@test "blocks plain gh issue create" {
	_run_hook 'gh issue create --title x --body y'
	[ "$status" -eq 2 ]
}

@test "blocks gh issue create with leading env-var assignment" {
	_run_hook 'FOO=bar gh issue create --title x'
	[ "$status" -eq 2 ]
}

@test "blocks gh issue create chained after another command" {
	_run_hook 'cd /tmp && gh issue create --title x'
	[ "$status" -eq 2 ]
}

@test "blocks gh issue create behind an env -u prefix" {
	_run_hook 'env -u CLAUDECODE gh issue create --title x'
	[ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# ALLOW — validated wrappers and unrelated gh subcommands
# ---------------------------------------------------------------------------

@test "allows the create-followup-issue.sh wrapper" {
	_run_hook '.claude/scripts/create-followup-issue.sh --title x --file-path .'
	[ "$status" -eq 0 ]
}

@test "allows the platform create-issue.sh wrapper" {
	_run_hook '.claude/scripts/platform/create-issue.sh --title x'
	[ "$status" -eq 0 ]
}

@test "allows gh issue list" {
	_run_hook 'gh issue list --state open'
	[ "$status" -eq 0 ]
}

@test "allows gh issue view" {
	_run_hook 'gh issue view 506'
	[ "$status" -eq 0 ]
}

@test "allows gh issue comment" {
	_run_hook 'gh issue comment 5 --body hi'
	[ "$status" -eq 0 ]
}

@test "allows gh pr create" {
	_run_hook 'gh pr create --title x --body y'
	[ "$status" -eq 0 ]
}

@test "allows an unrelated command" {
	_run_hook 'echo hello'
	[ "$status" -eq 0 ]
}

@test "allows the phrase inside a quoted argument (git commit message)" {
	# The phrase appears only inside a -m argument, not at a command
	# position — must NOT be blocked.
	_run_hook 'git commit -m "feat: hard-block direct gh issue create"'
	[ "$status" -eq 0 ]
}

@test "allows echo/grep that merely mention the phrase" {
	_run_hook 'echo "do not run gh issue create directly"'
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Robustness — malformed payload must fail OPEN (never block unrelated tools)
# ---------------------------------------------------------------------------

@test "fails open on malformed JSON payload" {
	run bash -c "printf 'not json' | bash '$HOOK'"
	[ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Guidance string (issue #632 AC5)
#
# The block message is the only instruction the model gets after being stopped,
# so it has to name a path that EXISTS in the repo it is running in. Consumers
# on the pipeline-core plugin have no .claude/scripts/ — those wrappers were
# removed by the plugin migration — so naming them sends the model to a dead
# path. Name the plugin bin/ entrypoints instead.
# ---------------------------------------------------------------------------

@test "(#632 AC5) block message names the plugin bin/ entrypoints" {
	_run_hook 'gh issue create --title x --body y'
	[ "$status" -eq 2 ]

	[[ "$output" == *"pipeline-core-create-followup-issue"* ]] || {
		printf 'FAIL: message does not name the follow-up bin entrypoint:\n%s\n' \
			"$output" >&2
		return 1
	}
	[[ "$output" == *"pipeline-core-platform-dir"* ]] || {
		printf 'FAIL: message does not name the platform-dir entrypoint:\n%s\n' \
			"$output" >&2
		return 1
	}
}

@test "(#632 AC5) block message names no removed .claude/scripts/ wrapper" {
	_run_hook 'gh issue create --title x --body y'
	[ "$status" -eq 2 ]

	[[ "$output" != *".claude/scripts/"* ]] || {
		printf 'FAIL: message still points at a removed wrapper path:\n%s\n' \
			"$output" >&2
		return 1
	}
}
