#!/usr/bin/env bats
#
# test-skill-load.bats
# Smoke tests for load_skill() in implement-issue-orchestrator.sh (L1336-1348).
#
# Verifies that the test-discovery skill (issue #336) is loadable:
#   (a) the skill file path resolves to a real file (non-empty output)
#   (b) the YAML front-matter is present — 'name:' and 'description:' fields exist
#
# CLAUDE_PROJECT_DIR is set to the real project root so that load_skill resolves
# .claude/skills/test-discovery/SKILL.md from the actual repo, not a test temp dir.
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    # Direct load_skill to the real project root (not the test temp dir).
    CLAUDE_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
    export CLAUDE_PROJECT_DIR
    source_orchestrator_functions
}

teardown() {
    teardown_test_env
}

# =============================================================================
# load_skill test-discovery — smoke tests (issue #336)
# =============================================================================

@test "load_skill test-discovery returns non-empty content (skill file path resolves)" {
    local content
    content=$(load_skill "test-discovery")
    [[ -n "$content" ]]
}

@test "load_skill test-discovery output starts with YAML front-matter delimiter ---" {
    local content
    content=$(load_skill "test-discovery")
    [[ "$content" == "---"* ]]
}

@test "load_skill test-discovery output contains 'name:' front-matter field" {
    local content
    content=$(load_skill "test-discovery")
    printf '%s\n' "$content" | grep -q '^name:'
}

@test "load_skill test-discovery output contains 'description:' front-matter field" {
    local content
    content=$(load_skill "test-discovery")
    printf '%s\n' "$content" | grep -q '^description:'
}

@test "load_skill returns empty string for a nonexistent skill name" {
    local content
    content=$(load_skill "no-such-skill-xyzzy-999" 2>/dev/null)
    [[ -z "$content" ]]
}
