#!/usr/bin/env bats
#
# test-skill-load.bats
# Smoke tests for load_skill() in implement-issue-orchestrator.sh (L1336-1348).
#
# Verifies that the test-discovery skill (issue #336) is loadable:
#   (a) the skill file path resolves to a real file (non-empty output)
#   (b) the YAML front-matter is present — 'name:' and 'description:' fields exist
#
# CLAUDE_PLUGIN_ROOT is set to the real plugin root so that load_skill resolves
# plugins/pipeline-core/skills/test-discovery/SKILL.md from the actual repo, not
# a test temp dir.
#

load 'helpers/test-helper.bash'

setup() {
    setup_test_env
    # Direct load_skill to the real project root (not the test temp dir).
    CLAUDE_PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
    # Point load_skill at the plugin root the way Claude Code does in
    # production. test-discovery lives under the plugin layout after the git mv;
    # prefer it and fall back to the legacy .claude layout. The
    # source_orchestrator_functions helper runs load_skill from a temp copy, so
    # its BASH_SOURCE-based dev fallback cannot compute the real repo root.
    if [[ -d "$CLAUDE_PROJECT_DIR/plugins/pipeline-core/skills" ]]; then
        CLAUDE_PLUGIN_ROOT="$CLAUDE_PROJECT_DIR/plugins/pipeline-core"
    else
        CLAUDE_PLUGIN_ROOT="$CLAUDE_PROJECT_DIR/.claude"
    fi
    export CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT
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

# =============================================================================
# load_skill CLAUDE_PLUGIN_ROOT-unset — installed-plugin layout (issue #652)
# =============================================================================
#
# The suite above sets CLAUDE_PLUGIN_ROOT explicitly in setup(), which never
# exercises the fallback load_skill takes when the orchestrator is launched
# headless (e.g. `nohup pipeline-core-batch ...`) and CLAUDE_PLUGIN_ROOT is
# unset. In that case load_skill self-locates via ${BASH_SOURCE[0]}, and the
# installed marketplace-plugin cache layout —
# <plugin>/<version>/scripts/ sibling to <plugin>/<version>/skills/ — was
# missing from the candidate chain (#652), so the dev-checkout fallback
# overshot by one directory level and every skill silently resolved to
# nothing.
#
# These tests build that fixture layout under TEST_TMP and extract
# load_skill() ALONE, sourcing it FROM the simulated
# <plugin>/<version>/scripts/ path so its BASH_SOURCE-based fallback resolves
# against the fixture tree instead of the real repo checkout (see the
# docstring at the top of this file for why source_orchestrator_functions()
# cannot be reused for this: it sources a flat copy from TEST_TMP directly,
# not from a nested <version>/scripts/ path).

setup_installed_plugin_fixture() {
    # <plugin>/<version>/{scripts,skills}/ — mirrors the real marketplace
    # cache layout, e.g.
    # ~/.claude/plugins/cache/<marketplace>/pipeline-core/0.4.0/{scripts,skills}/.
    PLUGIN_FIXTURE_DIR="$TEST_TMP/plugins/pipeline-core/0.4.0"
    mkdir -p "$PLUGIN_FIXTURE_DIR/scripts"
    mkdir -p "$PLUGIN_FIXTURE_DIR/skills/fixture-skill"

    cat > "$PLUGIN_FIXTURE_DIR/skills/fixture-skill/SKILL.md" <<'SKILL_EOF'
---
name: fixture-skill
description: Fixture skill for the installed-plugin layout regression test.
---

Fixture body content.
SKILL_EOF

    # Extract load_skill() alone and source it FROM the simulated
    # <plugin>/<version>/scripts/ path so ${BASH_SOURCE[0]} inside it
    # resolves against the fixture tree, not this test file's real location.
    local extracted="$PLUGIN_FIXTURE_DIR/scripts/implement-issue-orchestrator.sh"
    _extract_function_body load_skill "$ORCHESTRATOR_SCRIPT" > "$extracted"

    # load_skill calls log_warn on a genuine miss; stub it so sourcing the
    # extracted function doesn't depend on the rest of the orchestrator.
    log_warn() { :; }

    unset CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR
    source "$extracted"
}

@test "load_skill (CLAUDE_PLUGIN_ROOT unset) resolves a skill in the simulated <plugin>/<version>/scripts/ layout" {
    setup_installed_plugin_fixture

    local content
    content=$(load_skill "fixture-skill")
    [[ -n "$content" ]]
}

@test "load_skill (CLAUDE_PLUGIN_ROOT unset) returns the fixture's own content, not a stray match" {
    setup_installed_plugin_fixture

    local content
    content=$(load_skill "fixture-skill")
    [[ "$content" == *"Fixture skill for the installed-plugin layout regression test."* ]]
}

@test "load_skill (CLAUDE_PLUGIN_ROOT unset) still returns empty for a genuine miss in the simulated layout" {
    setup_installed_plugin_fixture

    local content
    content=$(load_skill "no-such-skill-xyzzy-999" 2>/dev/null)
    [[ -z "$content" ]]
}
