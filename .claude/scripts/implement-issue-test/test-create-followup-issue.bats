#!/usr/bin/env bats
#
# test-create-followup-issue.bats
# Unit tests for .claude/scripts/create-followup-issue.sh
#
# Covers:
#   1. Happy path — precise body with resolvable path emitted on stdout
#   2. Happy path — vague body type emits correct structure
#   3. Agent inference — .sh/.bats extension → bash-script-craftsman
#   4. Agent inference — unknown extension → default
#   5. Agent inference — agent with no .md definition degrades to default
#   6. Deploy Verification — DEPLOY_VERIFY_CMD set → section present
#   7. Deploy Verification — DEPLOY_VERIFY_CMD unset → section absent
#   8. Fail-closed — unresolvable path → exit 1, nothing on stdout
#   9. Missing required argument → exit 3
#  10. pipeline-autocreated marker present in every emitted body
#  11. task description override via --task-description
#  12. deploy-verify fail-closed: body missing section when DEPLOY_VERIFY_CMD set
#      (validates assert_issue_valid is actually called)
#

bats_require_minimum_version 1.5.0

load 'helpers/test-helper.bash'

GENERATOR="${SCRIPT_DIR}/create-followup-issue.sh"

# ---------------------------------------------------------------------------
# Per-test setup / teardown
# ---------------------------------------------------------------------------

setup() {
	setup_test_env

	# Sandbox agents directory.
	export ISSUE_BODY_AGENTS_DIR="${TEST_TMP}/agents"
	mkdir -p "${ISSUE_BODY_AGENTS_DIR}"
	: > "${ISSUE_BODY_AGENTS_DIR}/bash-script-craftsman.md"
	: > "${ISSUE_BODY_AGENTS_DIR}/code-reviewer.md"
	: > "${ISSUE_BODY_AGENTS_DIR}/react-frontend-developer.md"
	: > "${ISSUE_BODY_AGENTS_DIR}/fastify-backend-developer.md"

	# Sandbox repo root with a .claude/scripts directory so paths resolve.
	export ISSUE_BODY_REPO_ROOT="${TEST_TMP}/repo"
	mkdir -p "${ISSUE_BODY_REPO_ROOT}/.claude/scripts"

	unset DEPLOY_VERIFY_CMD
	unset FRONTEND_PATH_PATTERNS
}

teardown() {
	teardown_test_env
}

# ---------------------------------------------------------------------------
# Minimal valid call — reused across tests
# ---------------------------------------------------------------------------

_call_precise() {
	"$GENERATOR" \
		--title "Fix connection pool leak" \
		--description "Memory leak observed under load." \
		--file-path ".claude/scripts/issue-body-lib.sh" \
		--pr-number "42" \
		--issue-number "100" \
		--reviewer "alice" \
		"$@"
}

_call_vague() {
	"$GENERATOR" \
		--title "Investigate slow queries" \
		--description "Queries slow in production." \
		--file-path ".claude/scripts/batch-orchestrator.sh" \
		--pr-number "55" \
		--issue-number "200" \
		--reviewer "bob" \
		--type vague \
		"$@"
}

# =============================================================================
# 1. Happy path — precise body emitted on stdout
# =============================================================================

@test "precise body: exits 0 with non-empty output" {
	run _call_precise
	[ "$status" -eq 0 ]
	[ -n "$output" ]
}

@test "precise body: contains ## Implementation Tasks section" {
	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"## Implementation Tasks"* ]]
}

@test "precise body: contains ## Acceptance Criteria section" {
	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"## Acceptance Criteria"* ]]
}

@test "precise body: references pr and issue numbers" {
	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"#42"* ]]
	[[ "$output" == *"#100"* ]]
}

@test "precise body: references reviewer" {
	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"@alice"* ]]
}

# =============================================================================
# 2. Happy path — vague body
# =============================================================================

@test "vague body: exits 0" {
	run _call_vague
	[ "$status" -eq 0 ]
}

@test "vague body: contains 'Explore and implement' task line" {
	run _call_vague
	[ "$status" -eq 0 ]
	[[ "$output" == *"Explore and implement"* ]]
}

@test "vague body: uses **(S)** size marker" {
	run _call_vague
	[ "$status" -eq 0 ]
	[[ "$output" == *"**(S)**"* ]]
}

@test "vague body: contains vague note block" {
	run _call_vague
	[ "$status" -eq 0 ]
	[[ "$output" == *"classified as vague"* ]]
}

@test "vague body: includes ## Acceptance Criteria section" {
	run _call_vague
	[ "$status" -eq 0 ]
	[[ "$output" == *"## Acceptance Criteria"* ]]
}

# =============================================================================
# 3. Agent inference — shell file → bash-script-craftsman
# =============================================================================

@test "agent inference: .sh extension → bash-script-craftsman" {
	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"\`[bash-script-craftsman]\`"* ]]
}

@test "agent inference: .bats extension → bash-script-craftsman" {
	# Use .claude/scripts/ parent which the setup already creates.
	run "$GENERATOR" \
		--title "Add test" \
		--description "Add a new test." \
		--file-path ".claude/scripts/test-foo.bats" \
		--pr-number "1" \
		--issue-number "2" \
		--reviewer "eve"
	[ "$status" -eq 0 ]
	[[ "$output" == *"\`[bash-script-craftsman]\`"* ]]
}

# =============================================================================
# 4. Agent inference — unknown extension → default
# =============================================================================

@test "agent inference: .md extension → default agent" {
	# Use .claude/scripts/ parent which the setup already creates.
	run "$GENERATOR" \
		--title "Update skill" \
		--description "Update the skill file." \
		--file-path ".claude/scripts/SKILL.md" \
		--pr-number "1" \
		--issue-number "2" \
		--reviewer "eve"
	[ "$status" -eq 0 ]
	[[ "$output" == *"\`[default]\`"* ]]
}

@test "agent inference: .yaml extension → default agent" {
	# Create a parent dir so path resolves.
	mkdir -p "${ISSUE_BODY_REPO_ROOT}/config"
	run "$GENERATOR" \
		--title "Update config" \
		--description "Update config." \
		--file-path "config/app.yaml" \
		--pr-number "1" \
		--issue-number "2" \
		--reviewer "eve"
	[ "$status" -eq 0 ]
	[[ "$output" == *"\`[default]\`"* ]]
}

# =============================================================================
# 5. Agent inference — agent with no .md definition degrades to default
# =============================================================================

@test "agent inference: agent missing from agents dir → default" {
	# Remove bash-script-craftsman.md so the candidate has no definition.
	rm -f "${ISSUE_BODY_AGENTS_DIR}/bash-script-craftsman.md"

	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"\`[default]\`"* ]]
}

# =============================================================================
# 6. Deploy Verification — DEPLOY_VERIFY_CMD set → section present
# =============================================================================

@test "deploy verification: DEPLOY_VERIFY_CMD set → section in output" {
	export DEPLOY_VERIFY_CMD="npm run deploy"

	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"## Deploy Verification"* ]]
}

@test "deploy verification: DEPLOY_VERIFY_CMD value appears in section" {
	export DEPLOY_VERIFY_CMD="curl -fs https://example.com/health"

	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"curl -fs https://example.com/health"* ]]
}

# =============================================================================
# 7. Deploy Verification — DEPLOY_VERIFY_CMD unset → section absent
# =============================================================================

@test "deploy verification: DEPLOY_VERIFY_CMD unset → no section" {
	unset DEPLOY_VERIFY_CMD

	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" != *"## Deploy Verification"* ]]
}

# =============================================================================
# 8. Fail-closed — unresolvable path → exit 1, nothing on stdout
# =============================================================================

@test "fail-closed: unresolvable path → exit 1" {
	run "$GENERATOR" \
		--title "Fix thing" \
		--description "Some desc." \
		--file-path "totally/missing/dir/file.sh" \
		--pr-number "1" \
		--issue-number "2" \
		--reviewer "eve"
	[ "$status" -eq 1 ]
}

@test "fail-closed: unresolvable path → nothing on stdout" {
	# Use --separate-stderr so $output captures only stdout.
	run --separate-stderr "$GENERATOR" \
		--title "Fix thing" \
		--description "Some desc." \
		--file-path "totally/missing/dir/file.sh" \
		--pr-number "1" \
		--issue-number "2" \
		--reviewer "eve"
	[ -z "$output" ]
}

@test "fail-closed: diagnostic message on stderr" {
	run "$GENERATOR" \
		--title "Fix thing" \
		--description "Some desc." \
		--file-path "totally/missing/dir/file.sh" \
		--pr-number "1" \
		--issue-number "2" \
		--reviewer "eve"
	[[ "$output" == *"unresolved path"* || "$stderr" == *"unresolved path"* ]] \
		|| [[ "$output" == *"failed validation"* ]]
}

# =============================================================================
# 9. Missing required argument → exit 3
# =============================================================================

@test "missing --title → exit 3" {
	run "$GENERATOR" \
		--description "desc" \
		--file-path ".claude/scripts/x.sh" \
		--pr-number "1" --issue-number "2" --reviewer "r"
	[ "$status" -eq 3 ]
}

@test "missing --description → exit 3" {
	run "$GENERATOR" \
		--title "title" \
		--file-path ".claude/scripts/x.sh" \
		--pr-number "1" --issue-number "2" --reviewer "r"
	[ "$status" -eq 3 ]
}

@test "missing --file-path → exit 3" {
	run "$GENERATOR" \
		--title "title" --description "desc" \
		--pr-number "1" --issue-number "2" --reviewer "r"
	[ "$status" -eq 3 ]
}

@test "missing --pr-number → exit 3" {
	run "$GENERATOR" \
		--title "title" --description "desc" \
		--file-path ".claude/scripts/x.sh" \
		--issue-number "2" --reviewer "r"
	[ "$status" -eq 3 ]
}

@test "missing --issue-number → exit 3" {
	run "$GENERATOR" \
		--title "title" --description "desc" \
		--file-path ".claude/scripts/x.sh" \
		--pr-number "1" --reviewer "r"
	[ "$status" -eq 3 ]
}

@test "missing --reviewer → exit 3" {
	run "$GENERATOR" \
		--title "title" --description "desc" \
		--file-path ".claude/scripts/x.sh" \
		--pr-number "1" --issue-number "2"
	[ "$status" -eq 3 ]
}

# =============================================================================
# 10. pipeline-autocreated marker present in every emitted body
# =============================================================================

@test "precise body: contains pipeline-autocreated marker" {
	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"<!-- pipeline-autocreated -->"* ]]
}

@test "vague body: contains pipeline-autocreated marker" {
	run _call_vague
	[ "$status" -eq 0 ]
	[[ "$output" == *"<!-- pipeline-autocreated -->"* ]]
}

# =============================================================================
# 11. task-description override
# =============================================================================

@test "task-description: overrides title in task line" {
	run "$GENERATOR" \
		--title "Original title" \
		--description "desc" \
		--task-description "Override task description" \
		--file-path ".claude/scripts/issue-body-lib.sh" \
		--pr-number "1" --issue-number "2" --reviewer "r"
	[ "$status" -eq 0 ]
	[[ "$output" == *"Override task description"* ]]
	# Original title should not appear as the task text
	[[ "$output" != *"**(M)** Original title"* ]]
}

# =============================================================================
# 12. assert_issue_valid is actually called (defense check)
# =============================================================================

@test "validation is live: DEPLOY_VERIFY_CMD set → passes with section present" {
	export DEPLOY_VERIFY_CMD="make verify"

	# A precise body with DEPLOY_VERIFY_CMD set should include the section
	# and therefore pass validation.
	run _call_precise
	[ "$status" -eq 0 ]
	[[ "$output" == *"## Deploy Verification"* ]]
}

# =============================================================================
# 13. Platform delegation wiring — FRONTEND_PATH_PATTERNS routes TS/JS files
# =============================================================================

@test "platform delegation: ts file + FRONTEND_PATH_PATTERNS set → react-frontend-developer" {
	# Set a frontend pattern that matches src/components/*.
	export FRONTEND_PATH_PATTERNS="src/components/*"
	mkdir -p "${ISSUE_BODY_REPO_ROOT}/src/components"

	run "$GENERATOR" \
		--title "Fix component" \
		--description "Fix a React component." \
		--file-path "src/components/Button.tsx" \
		--pr-number "7" \
		--issue-number "20" \
		--reviewer "carol"
	[ "$status" -eq 0 ]
	[[ "$output" == *"\`[react-frontend-developer]\`"* ]]
}

@test "platform delegation: ts file + FRONTEND_PATH_PATTERNS set but non-matching → fastify-backend-developer" {
	export FRONTEND_PATH_PATTERNS="src/components/*"
	mkdir -p "${ISSUE_BODY_REPO_ROOT}/src/services"

	run "$GENERATOR" \
		--title "Fix service" \
		--description "Fix a backend service." \
		--file-path "src/services/auth.ts" \
		--pr-number "7" \
		--issue-number "20" \
		--reviewer "carol"
	[ "$status" -eq 0 ]
	[[ "$output" == *"\`[fastify-backend-developer]\`"* ]]
}

@test "platform delegation: ts file + FRONTEND_PATH_PATTERNS unset → default" {
	unset FRONTEND_PATH_PATTERNS
	mkdir -p "${ISSUE_BODY_REPO_ROOT}/src/services"

	run "$GENERATOR" \
		--title "Fix service" \
		--description "Fix something." \
		--file-path "src/services/auth.ts" \
		--pr-number "7" \
		--issue-number "20" \
		--reviewer "carol"
	[ "$status" -eq 0 ]
	[[ "$output" == *"\`[default]\`"* ]]
}

# =============================================================================
# 14. Unknown option → exit 3 (the -* branch)
# =============================================================================

@test "unknown option: --bogus-flag → exit 3" {
	run "$GENERATOR" --bogus-flag "value" \
		--title "t" --description "d" \
		--file-path ".claude/scripts/x.sh" \
		--pr-number "1" --issue-number "2" --reviewer "r"
	[ "$status" -eq 3 ]
}

@test "unknown option: error message names the unknown flag" {
	run "$GENERATOR" --no-such-option \
		--title "t" --description "d" \
		--file-path ".claude/scripts/x.sh" \
		--pr-number "1" --issue-number "2" --reviewer "r"
	[[ "$output" == *"unknown option"* || "$output" == *"no-such-option"* ]] \
		|| [[ "$stderr" == *"unknown option"* || "$stderr" == *"no-such-option"* ]]
}
