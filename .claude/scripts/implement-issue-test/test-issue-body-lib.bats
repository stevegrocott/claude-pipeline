#!/usr/bin/env bats
#
# test-issue-body-lib.bats
# Unit tests for issue-body-lib.sh:
#   valid_agents()           — derives the agent set from .claude/agents/*.md
#   assert_issue_valid(body) — validates a pipeline issue body against the
#                              six structural criteria (>=1 task, agents
#                              resolve, path suffixes resolve, AC present,
#                              Deploy Verification iff DEPLOY_VERIFY_CMD set,
#                              task granularity: no M/L task naming >2 paths),
#                              plus a non-failing non-S task-mix warning
#   _issue_body_task_complexity(desc)  — S/M/L hint extraction (default M)
#   _issue_body_task_path_count(desc)  — distinct path count (:Lnn-tolerant)
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

# --- Issue #600: App Router / new-dir paths, API-route & bare /word tokens ---

@test "assert_issue_valid: accepts a bracketed App Router path ([step]/page.tsx)" {
	# Defect 1 — the extractor char class must admit '[' ']' segments so the
	# whole backtick token is not silently dropped.  Ancestor exists → resolves.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/apps/frontend/src/app"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Add the step page — \`apps/frontend/src/app/onboarding/[step]/page.tsx\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "assert_issue_valid: accepts a parenthesised route-group path ((public)/login/page.tsx)" {
	# Defect 1 — '(' ')' route-group segments must match too.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/apps/frontend/src/app"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Add the login page — \`apps/frontend/src/app/(public)/login/page.tsx\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "assert_issue_valid: a backticked API-route token does not raise 'unresolved path'" {
	# Defect 2 — '/api/register' is extension-less and non-resolving → prose,
	# not a repo path.  The task still carries a real path so the body is valid.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/apps/frontend/src/app"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Wire the handler — \`apps/frontend/src/app/register.ts\` posts to \`/api/register\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"unresolved path"* ]]
}

@test "assert_issue_valid: a bare /word token does NOT satisfy the >=1-path requirement" {
	# Defect 3 — '/login' must be treated as prose, so a task whose only
	# path-like token is '/login' fails criterion 7 instead of silently passing.
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Redirect users to \`/login\` after sign-out

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"task has no file path"* ]]
}

# --- Issue #689: separator-less backticked filenames are name mentions, not
# navigation targets, so they are exempt from resolution but still cannot
# satisfy the >=1-path requirement on their own. ---

@test "assert_issue_valid: a backticked filename with no directory separator, mentioned in prose, does not raise 'unresolved path'" {
	# A slash-less filename named in ordinary prose (a warning not to touch
	# it, not a navigation target — replaying the #679 shape) must not be
	# resolution-checked.  The task's real navigation target is the files
	# suffix, `.claude/scripts/model-config.sh`.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/.claude/scripts"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Re-source the real config path in an isolated subshell — do NOT re-source \`model-config.sh\` in the test shell, see readonly hazard — \`.claude/scripts/model-config.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"unresolved path"* ]]
}

@test "assert_issue_valid: a slash-bearing bad path still fails even with an exempt bare filename in the same task" {
	# The exemption is narrow to separator-less tokens: a path with a
	# directory component that does not resolve must still fail criterion 3,
	# and the exemption on the bare filename must not leak into it.
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** See \`README.md\` and edit — \`nope/missing/file.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unresolved path: nope/missing/file.sh"* ]]
	[[ "$output" != *"unresolved path: README.md"* ]]
}

@test "assert_issue_valid: a separator-less filename alone does NOT satisfy the >=1-path requirement" {
	# Mirrors the bare /word rule (#600): demoting the token to prose means a
	# task whose only path-like token is a separator-less filename must still
	# fail criterion 7 — the exemption cannot be used to skip naming a real
	# path.
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Update \`config.yaml\` for the service

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"task has no file path"* ]]
}

# --- Issue #689 AC2: regression fixtures replaying the #679 and #678 bodies
# verbatim as they stood at rejection time (batch-20260730-212750,
# 2026-07-30T21:28 local / 2026-07-30T11:28:01Z-11:28:08Z UTC). Recovered via
# `gh api graphql` userContentEdits — the pre-fix snapshot immediately before
# each issue was hand-edited to full paths minutes after preflight skipped
# it. Bodies are reproduced byte-for-byte (including the bare `model-config.sh`,
# `test-timeout-escalation.bats` and `test-bundle-parity.bats` mentions that
# triggered "unresolved path"), not reconstructed, so this fixture would have
# caught the regression before #689 was ever filed. ---

@test "#689 AC2: replays the #679 body verbatim as rejected and it now validates" {
	# Preflight log at rejection time (orchestrator.log):
	#   WARN: Preflight #679: assert_issue_valid: unresolved path: model-config.sh
	#   WARN: Skipping issue #679: body failed structural validation
	#
	# Fixture is the exact issue body live at rejection (2026-07-30T21:28:01
	# local / 2026-07-30T11:28:01Z), recovered via `gh api graphql`
	# userContentEdits (the snapshot immediately before a hand-edit minutes
	# later rewrote the bare `model-config.sh` mention to a full path) — a
	# byte-for-byte replay, not a reconstruction. Stored as a file rather than
	# an inline heredoc: bash 3.2 (macOS default, what this suite runs under)
	# misparses a single-quoted heredoc containing an odd number of literal
	# apostrophes, which this prose body has several of.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/.claude/scripts/implement-issue-test"
	local fixtures_dir
	fixtures_dir="$(dirname "${BATS_TEST_FILENAME}")/fixtures"
	local body
	body=$(cat "$fixtures_dir/issue-679-rejected-body.md")
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"unresolved path"* ]]
}

@test "#689 AC2: replays the #678 body verbatim as rejected and it now validates" {
	# Preflight log at rejection time (orchestrator.log):
	#   WARN: Preflight #678: assert_issue_valid: unresolved path: test-bundle-parity.bats
	#   WARN: Preflight #678: assert_issue_valid: unresolved path: test-timeout-escalation.bats
	#   WARN: Skipping issue #678: body failed structural validation
	#
	# Fixture is the exact issue body live at rejection (2026-07-30T21:28:08
	# local / 2026-07-30T11:28:08Z), recovered the same way as #679 above.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/.claude/scripts/implement-issue-test"
	mkdir -p "$ISSUE_BODY_REPO_ROOT/plugins/pipeline-core/scripts"
	mkdir -p "$ISSUE_BODY_REPO_ROOT/tests"
	local fixtures_dir
	fixtures_dir="$(dirname "${BATS_TEST_FILENAME}")/fixtures"
	local body
	body=$(cat "$fixtures_dir/issue-678-rejected-body.md")
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"unresolved path"* ]]
}

@test "assert_issue_valid: accepts a new file in a not-yet-existing subdir when an ancestor exists" {
	# Defect 4 — resolution walks ancestors: 'app/api/' exists but
	# 'app/api/register/' does not yet, and the new file must still validate.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/apps/frontend/src/app/api"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Add the route handler — \`apps/frontend/src/app/api/register/route.ts\`

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

# --- Issue #630: bound the ancestor walk to at most 2 missing trailing
# segments, so a genuinely new file still resolves but a wholly invented
# deep path no longer does merely because some far ancestor exists. ---

@test "assert_issue_valid: accepts a path with exactly 2 new trailing segments under an existing ancestor" {
	# AC2 — 'app/api/' exists; 'register/route.ts' (a new dir plus a new
	# file) is exactly 2 missing trailing segments, still within bound.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/app/api"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Add the route handler — \`app/api/register/route.ts\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "assert_issue_valid: accepts a path inventing exactly 3 trailing segments beyond an existing ancestor" {
	# Boundary case — only 'src/' exists; 'made/up/file.ts' is exactly 3
	# missing trailing segments, which is the bound (#630): a new framework
	# route legitimately invents a feature dir, a dynamic segment and a file.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/src"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Edit — \`src/made/up/file.ts\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "assert_issue_valid: fails when a path invents 4 trailing segments beyond an existing ancestor" {
	# One past the bound — only 'src/' exists and 'totally/made/up/file.ts' is
	# four missing trailing segments, so it must not validate merely because
	# 'src/' happens to exist (AC1).
	mkdir -p "$ISSUE_BODY_REPO_ROOT/src"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Edit — \`src/totally/made/up/file.ts\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"src/totally/made/up/file.ts"* ]]
}

@test "assert_issue_valid: fails when a path invents more than 2 trailing segments beyond an existing ancestor" {
	# AC1 — only 'src/' exists; 'totally/made/up/file.ts' is 4 missing
	# trailing segments, well past the bound, so this must no longer
	# validate merely because 'src/' happens to exist.
	mkdir -p "$ISSUE_BODY_REPO_ROOT/src"
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Edit — \`src/totally/made/up/file.ts\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"src/totally/made/up/file.ts"* ]]
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
	[[ "$output" == *"missing 'Acceptance Criteria' section"* ]]
}

@test "assert_issue_valid: accepts ### Acceptance Criteria (level-3 heading)" {
	local body
	body=$(cat <<-'EOF'
	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Build — `.claude/scripts/x.sh`

	### Acceptance Criteria

	- [ ] done
	EOF
	)
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
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

@test "assert_issue_valid: accepts ### Deploy Verification heading (level-3)" {
	export DEPLOY_VERIFY_CMD="deploy && verify"
	local body
	body=$(cat <<-'EOF'
	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Build — `.claude/scripts/x.sh`

	## Acceptance Criteria

	- [ ] done

	### Deploy Verification

	**Verification command:** curl -fsS https://example/health
	EOF
	)
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "assert_issue_valid: DEPLOY_VERIFY_CMD set + section missing fails" {
	export DEPLOY_VERIFY_CMD="deploy && verify"
	run assert_issue_valid "$(valid_body)"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no 'Deploy Verification' section"* ]]
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
	[[ "$output" == *"'Deploy Verification' section present but DEPLOY_VERIFY_CMD unset"* ]]
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
	[[ "$output" == *"missing 'Acceptance Criteria' section"* ]]
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
	body=$(printf '%s\n' \
		"## Implementation Tasks" \
		"" \
		"- [ ] \`[bash-script-craftsman]\` **(M)** Build the lib — \`.claude/scripts/x.sh\`")
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
	[[ "$output" == *"Build the lib"* ]]
}

@test "_issue_body_parse_tasks: skips completed [x] tasks" {
	local body
	body=$(printf '%s\n' \
		"## Implementation Tasks" \
		"" \
		"- [x] \`[bash-script-craftsman]\` **(M)** Already done")
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "_issue_body_parse_tasks: parses task line without checkbox bracket" {
	local body
	body=$(printf '%s\n' \
		"## Implementation Tasks" \
		"" \
		"- \`[default]\` **(S)** Some task description")
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"default"* ]]
	[[ "$output" == *"Some task description"* ]]
}

@test "_issue_body_parse_tasks: output is tab-separated agent<TAB>description records" {
	local body
	body=$(printf '%s\n' \
		"## Implementation Tasks" \
		"" \
		"- [ ] \`[bash-script-craftsman]\` **(M)** Fix the handler — \`.claude/scripts/x.sh\`")
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	# Record must contain a tab separating agent from description.
	[[ "$output" == *$'\t'* ]]
}

@test "_issue_body_parse_tasks: parses multiple open task lines" {
	local body
	body=$(printf '%s\n' \
		"## Implementation Tasks" \
		"" \
		"- [ ] \`[bash-script-craftsman]\` **(M)** First task" \
		"- [ ] \`[code-reviewer]\` **(S)** Second task")
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

# =============================================================================
# _issue_body_parse_tasks() — SECTION SCOPING (## Implementation Tasks only)
# =============================================================================

@test "_issue_body_parse_tasks: ignores task-like lines outside ## Implementation Tasks" {
	local body
	body=$(cat <<-'EOF'
	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Real task

	## Acceptance Criteria

	- [ ] `[code-reviewer]` **(S)** Should not be parsed as a task
	EOF
	)
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
	[[ "$output" != *"code-reviewer"* ]]
}

@test "_issue_body_parse_tasks: stops at next ## heading after Implementation Tasks" {
	local body
	body=$(cat <<-'EOF'
	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** In-section task

	## Notes

	- [ ] `[default]` **(S)** Post-section task — must not appear

	## Acceptance Criteria

	- [ ] done
	EOF
	)
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	local line_count
	line_count=$(printf '%s\n' "$output" | grep -c $'\t' || true)
	[ "$line_count" -eq 1 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
}

@test "_issue_body_parse_tasks: returns empty when ## Implementation Tasks heading absent" {
	local body
	body=$(cat <<-'EOF'
	## Some Other Section

	- [ ] `[bash-script-craftsman]` **(M)** Should not be parsed
	EOF
	)
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "_issue_body_parse_tasks: recognizes ### Implementation Tasks heading (level-3)" {
	local body
	body=$(printf '%s\n' \
		"### Implementation Tasks" \
		"" \
		"- [ ] \`[bash-script-craftsman]\` **(M)** Level-three task")
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
	[[ "$output" == *"Level-three task"* ]]
}

@test "_issue_body_parse_tasks: stops at ### heading after Implementation Tasks" {
	local body
	body=$(cat <<-'EOF'
	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** In-section task

	### Notes

	- [ ] `[default]` **(S)** Post-section task — must not appear
	EOF
	)
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	local line_count
	line_count=$(printf '%s\n' "$output" | grep -c $'\t' || true)
	[ "$line_count" -eq 1 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
}

@test "assert_issue_valid: accepts body with ### Implementation Tasks heading" {
	local body
	body=$(cat <<-'EOF'
	### Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Build — `.claude/scripts/x.sh`

	## Acceptance Criteria

	- [ ] done
	EOF
	)
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

# =============================================================================
# REGRESSION: inline-code bullets in Research Findings / Acceptance Criteria
# =============================================================================

@test "assert_issue_valid: validates body with inline-code bullets in Research Findings and AC" {
	local body
	body=$(cat <<-'EOF'
	## Research Findings

	- `parse_tasks` matched any backtick bullet before section scoping
	- `assert_issue_valid` lacked coverage for non-task sections

	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Fix the parser — `.claude/scripts/x.sh`

	## Acceptance Criteria

	- [ ] `parse_tasks` only parses lines inside Implementation Tasks
	- [ ] `assert_issue_valid` returns 0 for this body
	EOF
	)
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "_issue_body_parse_tasks: inline-code bullets in Research Findings are not parsed as tasks" {
	local body
	body=$(cat <<-'EOF'
	## Research Findings

	- `parse_tasks` finding one
	- `assert_issue_valid` finding two

	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Canonical task

	## Acceptance Criteria

	- [ ] criteria item
	EOF
	)
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	local line_count
	line_count=$(printf '%s\n' "$output" | grep -c $'\t' || true)
	[ "$line_count" -eq 1 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
}

@test "_issue_body_parse_tasks: inline-code bullets in Acceptance Criteria are not parsed as tasks" {
	local body
	body=$(cat <<-'EOF'
	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Canonical task

	## Acceptance Criteria

	- [ ] `[code-reviewer]` has reviewed the output
	- [ ] `parse_tasks` returns only one record
	EOF
	)
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	local line_count
	line_count=$(printf '%s\n' "$output" | grep -c $'\t' || true)
	[ "$line_count" -eq 1 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
}

@test "assert_issue_valid: AC bullets beginning with agent-like inline-code spans do not affect validation" {
	local body
	body=$(cat <<-'EOF'
	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Build — `.claude/scripts/x.sh`

	## Acceptance Criteria

	- [ ] `[code-reviewer]` has reviewed the output
	- [ ] `[bash-script-craftsman]` validates cleanly
	EOF
	)
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "_issue_body_parse_tasks: prose under ### heading in non-task section is not parsed as task" {
	local body
	body=$(cat <<-'EOF'
	## Research Findings

	### Approach

	Some prose that looks like prose.

	## Implementation Tasks

	- [ ] `[bash-script-craftsman]` **(M)** Build — `.claude/scripts/x.sh`

	## Acceptance Criteria

	- [ ] done
	EOF
	)
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	local line_count
	line_count=$(printf '%s\n' "$output" | grep -c $'\t' || true)
	[ "$line_count" -eq 1 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
}

# =============================================================================
# _issue_body_task_complexity()
# =============================================================================

@test "_issue_body_task_complexity: extracts (S) hint" {
	run _issue_body_task_complexity "**(S)** Small task — \`a.sh\`"
	[ "$status" -eq 0 ]
	[ "$output" = "S" ]
}

@test "_issue_body_task_complexity: extracts (M) hint" {
	run _issue_body_task_complexity "**(M)** Medium task — \`a.sh\`"
	[ "$status" -eq 0 ]
	[ "$output" = "M" ]
}

@test "_issue_body_task_complexity: extracts (L) hint" {
	run _issue_body_task_complexity "**(L)** Large task — \`a.sh\`"
	[ "$status" -eq 0 ]
	[ "$output" = "L" ]
}

@test "_issue_body_task_complexity: defaults to M when no hint present" {
	run _issue_body_task_complexity "Do the thing without a size hint"
	[ "$status" -eq 0 ]
	[ "$output" = "M" ]
}

@test "_issue_body_task_complexity: normalizes a lowercase hint to uppercase" {
	run _issue_body_task_complexity "**(s)** small but lowercase"
	[ "$status" -eq 0 ]
	[ "$output" = "S" ]
}

# =============================================================================
# _issue_body_task_path_count()
# =============================================================================

@test "_issue_body_task_path_count: counts three plain backtick paths" {
	run _issue_body_task_path_count \
		"Big — \`.claude/scripts/a.sh\`, \`.claude/scripts/b.sh\`, \`.claude/scripts/c.sh\`"
	[ "$status" -eq 0 ]
	[ "$output" -eq 3 ]
}

@test "_issue_body_task_path_count: counts paths carrying a :Lnn line-range suffix" {
	run _issue_body_task_path_count \
		"Big — \`src/a.ts:L45-80\`, \`src/b.ts:L5\`, \`src/c.ts:L20-30\`"
	[ "$status" -eq 0 ]
	[ "$output" -eq 3 ]
}

@test "_issue_body_task_path_count: collapses the same file at different lines to one" {
	run _issue_body_task_path_count \
		"One file — \`src/a.ts:L1\`, \`src/a.ts:L50\`, \`src/a.ts:L90\`"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1 ]
}

@test "_issue_body_task_path_count: returns 0 when no paths are referenced" {
	run _issue_body_task_path_count "Refactor the retry logic for reliability"
	[ "$status" -eq 0 ]
	[ "$output" -eq 0 ]
}

# =============================================================================
# assert_issue_valid() — CRITERION 6: task granularity (M/L + >2 distinct paths)
# =============================================================================

@test "assert_issue_valid: rejects a decomposable M task naming three distinct paths" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Big task — \`.claude/scripts/a.sh\`, \`.claude/scripts/b.sh\`, \`.claude/scripts/c.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"granularity"* ]]
}

@test "assert_issue_valid: rejects a decomposable L task using the :Lnn path format" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(L)** Big task — \`.claude/scripts/a.sh:L1-10\`, \`.claude/scripts/b.sh:L5\`, \`.claude/scripts/c.sh:L9\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"granularity"* ]]
}

@test "assert_issue_valid: rejects a hint-less (default-M) task naming three distinct paths" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` Big task — \`.claude/scripts/a.sh\`, \`.claude/scripts/b.sh\`, \`.claude/scripts/c.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"granularity"* ]]
}

@test "assert_issue_valid: allows an atomic M task naming exactly two paths" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(M)** Atomic — \`.claude/scripts/a.sh\`, \`.claude/scripts/b.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"granularity"* ]]
}

@test "assert_issue_valid: allows an atomic L task referencing one file at multiple line ranges" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(L)** One file — \`.claude/scripts/a.sh:L1-10\`, \`.claude/scripts/a.sh:L90-120\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"granularity"* ]]
}

@test "assert_issue_valid: exempts an S task even when it names more than two paths" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Small but wide — \`.claude/scripts/a.sh\`, \`.claude/scripts/b.sh\`, \`.claude/scripts/c.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"granularity"* ]]
}

# =============================================================================
# assert_issue_valid() — CRITERION 7: every open task carries a file path
# =============================================================================

@test "assert_issue_valid: rejects an open task that references no file path" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Refactor the retry logic for reliability

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"task has no file path"* ]]
	# The diagnostic must name the offending task.
	[[ "$output" == *"Refactor the retry logic for reliability"* ]]
}

@test "assert_issue_valid: accepts an open task that references a resolvable file path" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Add a helper — \`.claude/scripts/issue-body-lib.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"task has no file path"* ]]
}

@test "assert_issue_valid: accepts an open task whose only path carries a :Lnn suffix" {
	# Reuses #581's :Lnn-tolerant path counter — a lone line-range-suffixed
	# path must satisfy the file-path requirement, not be silently skipped.
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Patch one spot — \`.claude/scripts/issue-body-lib.sh:L10-40\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"task has no file path"* ]]
}

@test "assert_issue_valid: accepts an open task whose only path is a directory" {
	# Dir-only paths still count as a path — no regression from criterion 7.
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Touch the scripts dir — \`.claude/scripts/\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"task has no file path"* ]]
}

@test "assert_issue_valid: exempts a checked [x] task that has no file path" {
	# Only OPEN tasks are gated; a completed task with no path must not fail.
	local body
	body="## Implementation Tasks

- [x] \`[bash-script-craftsman]\` **(S)** Legacy done task with no path at all
- [ ] \`[bash-script-craftsman]\` **(S)** Open task — \`.claude/scripts/x.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"task has no file path"* ]]
}

# =============================================================================
# assert_issue_valid() — TASK-MIX ADVISORY WARNING (non-failing)
# =============================================================================

@test "assert_issue_valid: warns on stderr when the body contains a non-S task" {
	local body
	body="## Implementation Tasks

- [ ] \`[default]\` **(M)** Medium task — \`.claude/scripts/a.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	# Warning does not fail the body.
	[ "$status" -eq 0 ]
	[[ "$output" == *"WARNING"* ]]
	[[ "$output" == *"non-S task"* ]]
}

@test "assert_issue_valid: does not warn when every task is S" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Small one — \`.claude/scripts/a.sh\`
- [ ] \`[bash-script-craftsman]\` **(S)** Small two — \`.claude/scripts/b.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" != *"WARNING"* ]]
}

@test "assert_issue_valid: warning counts M/L against S in a mixed body" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Small — \`.claude/scripts/a.sh\`
- [ ] \`[bash-script-craftsman]\` **(M)** Medium — \`.claude/scripts/b.sh\`
- [ ] \`[bash-script-craftsman]\` **(L)** Large — \`.claude/scripts/c.sh\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 non-S task(s)"* ]]
	[[ "$output" == *"1 S task(s)"* ]]
}

# =============================================================================
# Hardened section extraction (issue #584): CRLF + case-insensitive heading
# =============================================================================

@test "_issue_body_parse_tasks: parses a CRLF-terminated body and strips CR" {
	local body
	body=$(printf '## Implementation Tasks\r\n\r\n- [ ] `[bash-script-craftsman]` **(S)** Do it — `.claude/scripts/a.sh`\r\n\r\n## Acceptance Criteria\r\n')
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
	# No carriage return leaks into the emitted record.
	[[ "$output" != *$'\r'* ]]
}

@test "_issue_body_parse_tasks: matches a lowercase 'implementation tasks' heading" {
	local body
	body="## implementation tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Do it — \`.claude/scripts/a.sh\`

## Acceptance Criteria"
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
}

@test "_issue_body_parse_tasks: keeps valid tasks and drops prose in a mixed section" {
	local body
	body="## Implementation Tasks

Task 1: prose that should be ignored
- [ ] \`[bash-script-craftsman]\` **(S)** Real task — \`.claude/scripts/a.sh\`

## Acceptance Criteria"
	run _issue_body_parse_tasks "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"bash-script-craftsman"* ]]
	[[ "$output" != *"prose that should be ignored"* ]]
}

@test "assert_issue_valid: accepts a CRLF body with a lowercase heading" {
	local body
	body=$(printf '## implementation tasks\r\n\r\n- [ ] `[bash-script-craftsman]` **(S)** Do it — `.claude/scripts/a.sh`\r\n\r\n## Acceptance Criteria\r\n\r\n- [ ] done\r\n')
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

# =============================================================================
# lint_task_lines (issue #584): per-line rejection report
# =============================================================================

@test "lint_task_lines: reports prose 'Task N:' lines as format rejections" {
	local body
	body="## Implementation Tasks

Task 1: build the thing
Task 2: test the thing

## Acceptance Criteria"
	run lint_task_lines "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"format"*"Task 1: build the thing"* ]]
	[[ "$output" == *"format"*"Task 2: test the thing"* ]]
}

@test "lint_task_lines: reports a task missing both brackets and backticks as format" {
	local body
	body="## Implementation Tasks

- [ ] bash-script-craftsman do the work here

## Acceptance Criteria"
	run lint_task_lines "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"format"* ]]
}

@test "lint_task_lines: reports an unresolved agent" {
	local body
	body="## Implementation Tasks

- [ ] \`[nonexistent-agent]\` **(S)** Do it — \`.claude/scripts/a.sh\`

## Acceptance Criteria"
	run lint_task_lines "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"agent-unresolved"* ]]
	[[ "$output" == *"nonexistent-agent"* ]]
}

@test "lint_task_lines: reports an unresolved file path" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Do it — \`nonexistent/dir/ghost.sh\`

## Acceptance Criteria"
	run lint_task_lines "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"path-unresolved"* ]]
	[[ "$output" == *"nonexistent/dir/ghost.sh"* ]]
}

@test "lint_task_lines: emits nothing for a well-formed task list" {
	run lint_task_lines "$(valid_body)"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "lint_task_lines: tolerates CRLF and a lowercase heading" {
	local body
	body=$(printf '## implementation tasks\r\n\r\nTask 1: prose form\r\n\r\n## Acceptance Criteria\r\n')
	run lint_task_lines "$body"
	[ "$status" -eq 0 ]
	[[ "$output" == *"format"*"Task 1: prose form"* ]]
	[[ "$output" != *$'\r'* ]]
}

# =============================================================================
# bash-host guard (issue #601)
# =============================================================================

# (a) Structural: the POSIX-portable BASH_VERSION guard block is present.
@test "bash-host guard: BASH_VERSION check is present in the library" {
	run grep -F 'if [ -z "${BASH_VERSION:-}" ]; then' "$LIB_PATH"
	[ "$status" -eq 0 ]
	run grep -F 'requires bash' "$LIB_PATH"
	[ "$status" -eq 0 ]
}

# (b) Functional: sourcing under a non-bash shell (zsh) fails fast with a clear
# message. NOTE macOS /bin/sh is bash-in-posix-mode and SETS BASH_VERSION, so
# it is unsuitable for this check — use zsh. Skip when zsh is unavailable.
@test "bash-host guard: sourcing under zsh errors non-zero with a clear message" {
	if ! command -v zsh >/dev/null 2>&1; then
		skip "zsh not available"
	fi
	run zsh -c "source '$LIB_PATH'"
	[ "$status" -ne 0 ]
	[[ "$output" == *"requires bash"* ]]
}

# (c) Regression: under bash the lib still sources cleanly and validates a
# known-good body.
@test "bash-host guard: under bash the lib sources and assert_issue_valid still passes" {
	run assert_issue_valid "$(valid_body)"
	[ "$status" -eq 0 ]
}

# =============================================================================
# Issue #634 — criterion 7 exemption for declared NON-COMMIT deliverables
#
# assert_issue_valid is fail-closed at issue creation, so a task whose
# deliverable is an issue comment could not be authored at all while
# criterion 7 demanded a file path from every open task.  The exemption is
# narrow: it fires only for a task that declares `deliverable:...`, so it can
# only widen what the gate accepts — no body that validated before this
# change stops validating.
# =============================================================================

@test "#634 assert_issue_valid: accepts a comment-only task that names no file path" {
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Post the routing ruling as an issue comment — \`deliverable:comment:ruling-634\`

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -eq 0 ]
}

@test "#634 assert_issue_valid: still rejects an unannotated task with no file path" {
	# Regression guard: the exemption must not disarm criterion 7 generally.
	local body
	body="## Implementation Tasks

- [ ] \`[bash-script-craftsman]\` **(S)** Do something unspecified

## Acceptance Criteria

- [ ] done"
	run assert_issue_valid "$body"
	[ "$status" -ne 0 ]
	[[ "$output" == *"task has no file path"* ]]
}
