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

# =============================================================================
# _issue_body_remap_agent()
# =============================================================================

@test "_issue_body_remap_agent: test-engineer remaps to playwright-test-developer" {
	run _issue_body_remap_agent "test-engineer"
	[ "$status" -eq 0 ]
	[ "$output" = "playwright-test-developer" ]
}

@test "_issue_body_remap_agent: bash-script-craftsman passes through unchanged" {
	run _issue_body_remap_agent "bash-script-craftsman"
	[ "$status" -eq 0 ]
	[ "$output" = "bash-script-craftsman" ]
}

@test "_issue_body_remap_agent: default passes through unchanged" {
	run _issue_body_remap_agent "default"
	[ "$status" -eq 0 ]
	[ "$output" = "default" ]
}

@test "_issue_body_remap_agent: unknown agent name passes through unchanged" {
	run _issue_body_remap_agent "some-future-agent"
	[ "$status" -eq 0 ]
	[ "$output" = "some-future-agent" ]
}

# =============================================================================
# _issue_body_extract_paths()
# =============================================================================

@test "_issue_body_extract_paths: extracts backtick-quoted path with slash" {
	run _issue_body_extract_paths "Fix the bug — \`.claude/scripts/handler.sh\`"
	[ "$status" -eq 0 ]
	[[ "$output" == *".claude/scripts/handler.sh"* ]]
}

@test "_issue_body_extract_paths: extracts bare extension-bearing backtick token" {
	run _issue_body_extract_paths "Update \`config.yaml\` for the service"
	[ "$status" -eq 0 ]
	[[ "$output" == *"config.yaml"* ]]
}

@test "_issue_body_extract_paths: does not extract bare text without backticks" {
	run _issue_body_extract_paths "Fix input/output handling in the pipeline"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "_issue_body_extract_paths: returns empty for desc with no file reference" {
	run _issue_body_extract_paths "Add retry logic to improve reliability"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "_issue_body_extract_paths: extracts multiple paths from one desc" {
	run _issue_body_extract_paths \
		"Update \`.claude/scripts/a.sh\` and \`.claude/scripts/b.sh\`"
	[ "$status" -eq 0 ]
	[[ "$output" == *".claude/scripts/a.sh"* ]]
	[[ "$output" == *".claude/scripts/b.sh"* ]]
}

@test "_issue_body_extract_paths: output is sorted and unique" {
	# Same path twice → only one entry in output.
	run _issue_body_extract_paths \
		"See \`.claude/scripts/x.sh\` and also \`.claude/scripts/x.sh\`"
	[ "$status" -eq 0 ]
	local line_count
	line_count=$(printf '%s\n' "$output" | grep -c '.' || true)
	[ "$line_count" -eq 1 ]
}

@test "_infer_agent_from_path: strips :line suffix before extension lookup (.sh:330-334 → bash-script-craftsman)" {
	: > "$ISSUE_BODY_AGENTS_DIR/bash-script-craftsman.md"
	run _infer_agent_from_path ".claude/scripts/handler.sh:330-334"
	[ "$status" -eq 0 ]
	[ "$output" = "bash-script-craftsman" ]
}

@test "_infer_agent_from_path: strips :function suffix before extension lookup (.sh:my_func → bash-script-craftsman)" {
	run _infer_agent_from_path ".claude/scripts/deploy.sh:deploy_app"
	[ "$status" -eq 0 ]
	[ "$output" = "bash-script-craftsman" ]
}

@test "_issue_body_extract_paths: backtick-only function name is not treated as path" {
	# Backtick-quoted names like \`_infer_agent_from_path\` have no slash and
	# no known extension — they must not be matched as file paths.
	run _issue_body_extract_paths \
		"Strip suffix in \`_infer_agent_from_path\` before extension lookup"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

# =============================================================================
# _issue_body_parse_tasks()
# =============================================================================

@test "_issue_body_parse_tasks: parses canonical task line with checkbox" {
	local body
	body="- [ ] \`[bash-script-craftsman]\` **(M)** Build the lib — \`.claude/scripts/x.sh\`"
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
	[[ "$output" == *"Build the lib"* ]]
}

@test "_issue_body_parse_tasks: skips completed [x] tasks" {
	local body="- [x] \`[bash-script-craftsman]\` **(M)** Already done"
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "_issue_body_parse_tasks: parses task line without checkbox bracket" {
	local body="- \`[default]\` **(S)** Some task description"
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"default"* ]]
	[[ "$output" == *"Some task description"* ]]
}

@test "_issue_body_parse_tasks: output is tab-separated agent<TAB>description records" {
	local body
	body="- [ ] \`[bash-script-craftsman]\` **(M)** Fix the handler — \`.claude/scripts/x.sh\`"
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	# Record must contain a tab separating agent from description.
	[[ "$output" == *$'\t'* ]]
}

@test "_issue_body_parse_tasks: parses multiple open task lines" {
	local body
	body="- [ ] \`[bash-script-craftsman]\` **(M)** First task"$'\n'"- [ ] \`[code-reviewer]\` **(S)** Second task"
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	local line_count
	line_count=$(printf '%s\n' "$output" | grep -c $'\t' || true)
	[ "$line_count" -eq 2 ]
}

@test "_issue_body_parse_tasks: empty body yields no output" {
	run _issue_body_parse_tasks ""
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "_issue_body_parse_tasks: prose-only body yields no output" {
	run _issue_body_parse_tasks "This is just a description with no task lines."
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}
