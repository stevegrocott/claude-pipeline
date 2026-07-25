#!/usr/bin/env bats
#
# Tests for resolve-pipeline-root.sh — the self-locating pipeline scripts/schemas
# root resolver (issue #599).
#
# The resolver must self-locate via ${BASH_SOURCE[0]} and must NOT depend on
# $CLAUDE_PLUGIN_ROOT at runtime: that variable is UNSET in the model's Bash-tool
# shell (it is only a hooks.json path-substitution placeholder). CLAUDE_PLUGIN_ROOT
# is honored ONLY as an optional hint when set AND the target file exists there.
#
# Each scenario copies the real resolver into a temp layout and sources it in a
# fresh `bash -c` subshell so BASH_SOURCE self-location is exercised per layout
# (and the idempotent sourcing guard starts clean every time).

RESOLVER_SRC="$BATS_TEST_DIRNAME/../resolve-pipeline-root.sh"

setup() {
    # Normalize through cd/pwd so the temp root matches what the resolver's own
    # `cd ... && pwd` produces (macOS resolves /var -> /private/var).
    TEST_TMP="$(cd "$(mktemp -d)" && pwd)"
}

teardown() {
    [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

# Copy the resolver into <layout_dir>, creating it, and echo the copied path.
_install_resolver() {
    local layout_dir="$1"
    mkdir -p "$layout_dir"
    cp "$RESOLVER_SRC" "$layout_dir/resolve-pipeline-root.sh"
    printf '%s\n' "$layout_dir/resolve-pipeline-root.sh"
}

@test "resolver source file exists" {
    [ -f "$RESOLVER_SRC" ]
}

@test "(a) resolves a sibling file via BASH_SOURCE self-location with CLAUDE_PLUGIN_ROOT unset" {
    local scripts_dir="$TEST_TMP/.claude/scripts"
    local resolver
    resolver="$(_install_resolver "$scripts_dir")"
    mkdir -p "$scripts_dir/schemas"
    printf '{}' > "$scripts_dir/schemas/stage-result.json"

    run bash -c "unset CLAUDE_PLUGIN_ROOT; source '$resolver'; resolve_pipeline_file schemas/stage-result.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$scripts_dir/schemas/stage-result.json" ]
}

@test "(b) resolves correctly when the resolver lives in the plugin-bundle layout" {
    local scripts_dir="$TEST_TMP/plugins/pipeline-core/scripts"
    local resolver
    resolver="$(_install_resolver "$scripts_dir")"
    mkdir -p "$scripts_dir/schemas"
    printf '{}' > "$scripts_dir/schemas/stage-result.json"

    run bash -c "unset CLAUDE_PLUGIN_ROOT; source '$resolver'; resolve_pipeline_file schemas/stage-result.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$scripts_dir/schemas/stage-result.json" ]
}

@test "(c) prefers CLAUDE_PLUGIN_ROOT when set AND the file exists there" {
    # Self-location dir has the file too, but the plugin-root hint must win.
    local scripts_dir="$TEST_TMP/.claude/scripts"
    local resolver
    resolver="$(_install_resolver "$scripts_dir")"
    mkdir -p "$scripts_dir/schemas"
    printf 'local' > "$scripts_dir/schemas/stage-result.json"

    local plugin_root="$TEST_TMP/plugin-cache/pipeline-core"
    mkdir -p "$plugin_root/scripts/schemas"
    printf 'plugin' > "$plugin_root/scripts/schemas/stage-result.json"

    run bash -c "export CLAUDE_PLUGIN_ROOT='$plugin_root'; source '$resolver'; resolve_pipeline_file schemas/stage-result.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$plugin_root/scripts/schemas/stage-result.json" ]
}

@test "(c) falls back to self-location when CLAUDE_PLUGIN_ROOT is set but the file is absent there" {
    local scripts_dir="$TEST_TMP/.claude/scripts"
    local resolver
    resolver="$(_install_resolver "$scripts_dir")"
    mkdir -p "$scripts_dir/schemas"
    printf 'local' > "$scripts_dir/schemas/stage-result.json"

    # Plugin root is set but does NOT contain the requested file.
    local plugin_root="$TEST_TMP/plugin-cache/pipeline-core"
    mkdir -p "$plugin_root/scripts"

    run bash -c "export CLAUDE_PLUGIN_ROOT='$plugin_root'; source '$resolver'; resolve_pipeline_file schemas/stage-result.json"
    [ "$status" -eq 0 ]
    [ "$output" = "$scripts_dir/schemas/stage-result.json" ]
}

@test "(d) returns non-zero and empty output for a missing file" {
    local scripts_dir="$TEST_TMP/.claude/scripts"
    local resolver
    resolver="$(_install_resolver "$scripts_dir")"

    run bash -c "unset CLAUDE_PLUGIN_ROOT; source '$resolver'; resolve_pipeline_file schemas/does-not-exist.json"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "(d) returns non-zero for an empty relative-path argument" {
    local scripts_dir="$TEST_TMP/.claude/scripts"
    local resolver
    resolver="$(_install_resolver "$scripts_dir")"

    run bash -c "unset CLAUDE_PLUGIN_ROOT; source '$resolver'; resolve_pipeline_file ''"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "resolves nested relative paths (not just schemas/)" {
    local scripts_dir="$TEST_TMP/.claude/scripts"
    local resolver
    resolver="$(_install_resolver "$scripts_dir")"
    mkdir -p "$scripts_dir/prompts"
    printf '#stub' > "$scripts_dir/prompts/triage-prompt.sh"

    run bash -c "unset CLAUDE_PLUGIN_ROOT; source '$resolver'; resolve_pipeline_file prompts/triage-prompt.sh"
    [ "$status" -eq 0 ]
    [ "$output" = "$scripts_dir/prompts/triage-prompt.sh" ]
}
