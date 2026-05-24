#!/usr/bin/env bats
#
# test-enrich-issue.bats
# Tests for the enrich-issue skill (issue #368).
#
# The enrich-issue skill rewrites a pipeline-autocreated GitHub issue body
# in place with /explore-quality research + planning, then removes the
# needs-explore label.  These tests assert that the SKILL.md:
#   1. Exists at the canonical path with valid frontmatter
#   2. Documents idempotency — no-op when label absent or marker absent
#   3. Documents the pipeline-autocreated HTML comment marker check
#   4. Documents needs-explore label removal on success
#

load 'helpers/test-helper.bash'

setup() {
	setup_test_env
	PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
	SKILL_FILE="$PROJECT_DIR/.claude/skills/enrich-issue/SKILL.md"
	export PROJECT_DIR SKILL_FILE
	CLAUDE_PROJECT_DIR="$PROJECT_DIR"
	export CLAUDE_PROJECT_DIR
	source_orchestrator_functions
}

teardown() {
	teardown_test_env
}

# =============================================================================
# Group 1: Skill file existence and frontmatter
# =============================================================================

@test "enrich-issue SKILL.md exists at the canonical path" {
	[[ -f "$SKILL_FILE" ]]
}

@test "load_skill enrich-issue returns non-empty content" {
	local content
	content=$(load_skill "enrich-issue")
	[[ -n "$content" ]]
}

@test "SKILL.md frontmatter contains name: enrich-issue" {
	grep -q '^name: enrich-issue' "$SKILL_FILE"
}

@test "SKILL.md frontmatter documents label removal side effect" {
	grep -qiE 'remove.*label|removes_github_label' "$SKILL_FILE"
}

# =============================================================================
# Group 2: Idempotency
# =============================================================================

@test "SKILL.md documents idempotency — no-op when needs-explore absent" {
	grep -qiE 'no-op|idempotent|already.enriched' "$SKILL_FILE"
}

@test "SKILL.md documents idempotency — no-op when marker absent" {
	local content
	content=$(cat "$SKILL_FILE")
	[[ "$content" == *"pipeline-autocreated"* ]]
	printf '%s' "$content" | \
		grep -qiE 'bail|skip|abort|no-op'
}

@test "SKILL.md documents a clear log/message for the no-op case" {
	grep -qiE 'log|message|skip|bail|abort' "$SKILL_FILE"
}

# =============================================================================
# Group 3: Marker check
# =============================================================================

@test "SKILL.md documents the pipeline-autocreated HTML comment marker" {
	grep -q 'pipeline-autocreated' "$SKILL_FILE"
}

@test "SKILL.md documents bailing/skipping when the marker is absent" {
	local pattern
	pattern='bail|skip|abort|no-op'
	pattern="$pattern|marker.*(absent|missing)"
	pattern="$pattern|(absent|missing).*marker"
	grep -qiE "$pattern" "$SKILL_FILE"
}

# =============================================================================
# Group 4: Label removal
# =============================================================================

@test "SKILL.md documents removing the needs-explore label on success" {
	grep -qi 'needs-explore' "$SKILL_FILE"
	grep -qiE 'remov' "$SKILL_FILE"
}

@test "SKILL.md references gh issue edit or remove-label for label ops" {
	grep -qE 'gh issue edit|remove-label' "$SKILL_FILE"
}

# =============================================================================
# Group 5: batch-orchestrator.sh integration (--enrich-followups sweep)
# =============================================================================

@test "batch-orchestrator.sh exists at expected path" {
	local script
	script="$PROJECT_DIR/.claude/scripts/batch-orchestrator.sh"
	[[ -f "$script" ]]
}

@test "batch-orchestrator.sh accepts --enrich-followups flag" {
	local script
	script="$PROJECT_DIR/.claude/scripts/batch-orchestrator.sh"
	grep -q 'enrich-followups' "$script"
}

@test "handle-issues SKILL.md documents --enrich-followups flag" {
	local skill
	skill="$PROJECT_DIR/.claude/skills/handle-issues/SKILL.md"
	[[ -f "$skill" ]]
	grep -q 'enrich-followups' "$skill"
}

@test "enrich-issue SKILL.md integration section references batch-orchestrator" {
	grep -qiE 'batch-orchestrator|enrich-followups' "$SKILL_FILE"
}
