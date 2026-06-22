#!/usr/bin/env bats
#
# test-issue-body-lib.bats
# Unit tests for issue-body-lib.sh:
#   valid_agents()           — derives the agent set from .claude/agents/*.md
#   assert_issue_valid(body) — validates a pipeline issue body against the
#                              six structural criteria (>=1 task, agents
#                              resolve, path suffixes resolve, AC present,
#                              Deploy Verification iff DEPLOY_VERIFY_CMD set)
#

bats_require_minimum_version 1.5.0

LIB_PATH="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)/issue-body-lib.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP

	# Sandbox agents directory consulted by valid_agents().
	export ISSUE_BODY_AGENTS_DIR="$TEST_TMP/agents"
	mkdir -p "$ISSUE_BODY_AGENTS_DIR"
	: > "$ISSUE_BODY_AGENTS_DIR/bash-script-craftsman.md"
	: > "$ISSUE_BODY_AGENTS_DIR/code-reviewer.md"
	: > "$ISSUE_BODY_AGENTS_DIR/playwright-test-developer.md"

	# Sandbox repo root consulted for path-suffix resolution.
	export ISSUE_BODY_REPO_ROOT="$TEST_TMP/repo"
	mkdir -p "$ISSUE_BODY_REPO_ROOT/.claude/scripts"

	# Deploy verification must be opt-in per test.
	unset DEPLOY_VERIFY_CMD

	source "$LIB_PATH"
}

teardown() {
	if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A minimal well-formed body (no deploy section; DEPLOY_VERIFY_CMD unset).
valid_body() {
	cat <<-'EOF'
	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Build the lib — `.claude/scripts/issue-body-lib.sh`

	## Acceptance Criteria

	- [ ] The library exists and is sourceable
	EOF
}

# =============================================================================
# valid_agents()
# =============================================================================

@test "valid_agents: lists every agent definition by stem" {
	run valid_agents
	[ "$status" -eq 0 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
	[[ "$output" == *"code-reviewer"* ]]
	[[ "$output" == *"playwright-test-developer"* ]]
}

@test "valid_agents: strips the .md extension" {
	run valid_agents
	[ "$status" -eq 0 ]
	[[ "$output" != *".md"* ]]
}

@test "valid_agents: output is sorted and unique" {
	# Duplicate stem cannot exist on a filesystem; assert sorted ordering.
	run valid_agents
	[ "$status" -eq 0 ]
	local sorted
	sorted=$(printf '%s\n' "$output" | sort -u)
	[ "$output" == "$sorted" ]
}

@test "valid_agents: empty directory yields no output" {
	rm -f "$ISSUE_BODY_AGENTS_DIR"/*.md
	run valid_agents
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# =============================================================================
# assert_issue_valid() — HAPPY PATH
# =============================================================================

@test "assert_issue_valid: accepts a well-formed body" {
	run assert_issue_valid "$(valid_body)"
	[ "$status" -eq 0 ]
}

@test "assert_issue_valid: accepts a task with a new file in an existing dir" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Add helper — \`.claude/scripts/brand-new.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "assert_issue_valid: accepts the default agent" {
	local body
	body="## Implementation Tasks

- [ ] \`[default]\` **(M)** Generic task — \`.claude/scripts/x.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "assert_issue_valid: remaps legacy agent name test-engineer" {
	local body
	body="## Implementation Tasks

- [ ] \`[test-engineer]\` **(M)** Write tests — \`.claude/scripts/x.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

# =============================================================================
# assert_issue_valid() — CRITERION 1: >= 1 parseable task
# =============================================================================

@test "assert_issue_valid: fails when no parseable task lines exist" {
	local body
	body="## Implementation Tasks

Some prose but no task checkboxes.

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"task"* ]]
}

@test "assert_issue_valid: ignores already-completed [x] tasks" {
	local body
	body="## Implementation Tasks

- [x] \`[bash-script-craftsman]\` **(M)** Already done — \`.claude/scripts/x.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	# Only a checked task → zero open tasks → invalid
	[ "$status" -ne 0 ]
	[[ "$output" == *"task"* ]]
}

# =============================================================================
# assert_issue_valid() — CRITERION 2: agents resolve
# =============================================================================

@test "assert_issue_valid: fails on an unknown agent" {
	local body
	body="## Implementation Tasks

- [ ] \`[nonexistent-agent]\` **(M)** Do thing — \`.claude/scripts/x.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"nonexistent-agent"* ]]
}

# =============================================================================
# assert_issue_valid() — CRITERION 3: path suffixes resolve
# =============================================================================

@test "assert_issue_valid: fails when a path's parent directory is missing" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Edit — \`nope/missing/file.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"nope/missing/file.sh"* ]]
}

@test "assert_issue_valid: resolves a path to an existing file" {
	: > "$ISSUE_BODY_REPO_ROOT/.claude/scripts/exists.sh"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Edit — \`.claude/scripts/exists.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

# =============================================================================
# assert_issue_valid() — CRITERION 4: AC present
# =============================================================================

@test "assert_issue_valid: fails when Acceptance Criteria section is missing" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Build — \`.claude/scripts/x.sh\`"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Acceptance Criteria"* ]]
}

# =============================================================================
# assert_issue_valid() — CRITERION 5: Deploy Verification iff DEPLOY_VERIFY_CMD
# =============================================================================

@test "assert_issue_valid: DEPLOY_VERIFY_CMD set + section present passes" {
	export DEPLOY_VERIFY_CMD="deploy && verify"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Build — \`.claude/scripts/x.sh\`

## Acceptance Criteria

- [ ] done

## Deploy Verification

**Verification command:** curl -fsS https://example/health"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "assert_issue_valid: DEPLOY_VERIFY_CMD set + section missing fails" {
	export DEPLOY_VERIFY_CMD="deploy && verify"
	run assert_issue_valid "$(valid_body)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Deploy Verification"* ]]
}

@test "assert_issue_valid: DEPLOY_VERIFY_CMD unset + section present fails" {
	unset DEPLOY_VERIFY_CMD
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Build — \`.claude/scripts/x.sh\`

## Acceptance Criteria

- [ ] done

## Deploy Verification

**Verification command:** curl -fsS https://example/health"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"Deploy Verification"* ]]
}

@test "assert_issue_valid: DEPLOY_VERIFY_CMD unset + no section passes" {
	unset DEPLOY_VERIFY_CMD
	run assert_issue_valid "$(valid_body)"
	[ "$status" -eq 0 ]
}

# =============================================================================
# assert_issue_valid() — MULTIPLE FAILURES
# =============================================================================

@test "assert_issue_valid: reports multiple failures at once" {
	local body
	body="## Implementation Tasks

- [ ] \`[ghost-agent]\` **(M)** Do — \`bad/dir/file.sh\`"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"ghost-agent"* ]]
	[[ "$output" == *"bad/dir/file.sh"* ]]
	[[ "$output" == *"Acceptance Criteria"* ]]
}
