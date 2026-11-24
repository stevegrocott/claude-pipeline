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

# --- version pinning helpers (issue #1158) ---------------------------------

# Build <cache>/<ver>/{scripts,bin,.claude-plugin/plugin.json}; echo scripts dir.
_install_versioned() {
    local cache="$1" ver="$2"
    mkdir -p "$cache/$ver/bin" "$cache/$ver/.claude-plugin"
    printf '{\n  "name": "pipeline-core",\n  "version": "%s"\n}\n' "$ver" \
        > "$cache/$ver/.claude-plugin/plugin.json"
    _install_resolver "$cache/$ver/scripts" > /dev/null
    printf '%s\n' "$cache/$ver/scripts/resolve-pipeline-root.sh"
}

@test "pipeline_pin_bin_first puts this version's bin first and drops sibling-version bins" {
    local cache="$TEST_TMP/cache"
    local resolver
    resolver="$(_install_versioned "$cache" 0.8.22)"
    mkdir -p "$cache/0.8.12/bin"

    run bash -c "PATH='$cache/0.8.12/bin:/usr/bin:$cache/0.8.22/bin:/bin'; source '$resolver'; pipeline_pin_bin_first; printf '%s\n' \"\$PATH\"; printf 'removed=%s\n' \"\$PIPELINE_PIN_REMOVED\""
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$cache/0.8.22/bin:/usr/bin:/bin" ]
    [ "${lines[1]}" = "removed=$cache/0.8.12/bin" ]
}

@test "pipeline_pin_bin_first keeps other plugins' bins" {
    local cache="$TEST_TMP/cache"
    local other="$TEST_TMP/other-plugin/1.2.3/bin"
    local resolver
    resolver="$(_install_versioned "$cache" 0.8.22)"

    run bash -c "PATH='$other:/usr/bin'; source '$resolver'; pipeline_pin_bin_first; printf '%s\n' \"\$PATH\"; printf 'removed=%s\n' \"\$PIPELINE_PIN_REMOVED\""
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "$cache/0.8.22/bin:$other:/usr/bin" ]
    [ "${lines[1]}" = "removed=" ]
}

@test "pipeline_pin_bin_first fails and leaves PATH alone with no bin dir" {
    local resolver
    resolver="$(_install_resolver "$TEST_TMP/.claude/scripts")"

    run bash -c "PATH='/usr/bin:/bin'; source '$resolver'; pipeline_pin_bin_first || echo rc=\$?; printf '%s\n' \"\$PATH\""
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" == *"/usr/bin:/bin" ]]
}

@test "pipeline_version reports the version from plugin.json" {
    local resolver
    resolver="$(_install_versioned "$TEST_TMP/cache" 0.8.22)"

    run bash -c "source '$resolver'; pipeline_version"
    [ "$status" -eq 0 ]
    [ "$output" = "0.8.22" ]
}

@test "pipeline_version fails in the repo-local layout" {
    local resolver
    resolver="$(_install_resolver "$TEST_TMP/.claude/scripts")"

    run bash -c "source '$resolver'; pipeline_version"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "pipeline_newer_versions lists only newer siblings in version order" {
    local cache="$TEST_TMP/cache"
    local resolver
    resolver="$(_install_versioned "$cache" 0.8.12)"
    _install_versioned "$cache" 0.8.9 > /dev/null
    _install_versioned "$cache" 0.8.22 > /dev/null
    _install_versioned "$cache" 0.8.13 > /dev/null

    run bash -c "source '$resolver'; pipeline_newer_versions"
    [ "$status" -eq 0 ]
    [ "$output" = $'0.8.13\n0.8.22' ]
}

@test "pipeline_newer_versions prints nothing when running the newest" {
    local cache="$TEST_TMP/cache"
    local resolver
    resolver="$(_install_versioned "$cache" 0.8.22)"
    _install_versioned "$cache" 0.8.12 > /dev/null
    mkdir -p "$cache/not-a-version"

    run bash -c "source '$resolver'; pipeline_newer_versions"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# --- redact_local_paths -----------------------------------------------------

_redact() {
    local root="$1" home="$2" text="$3"
    PIPELINE_REDACT_ROOT="$root" HOME="$home" bash -c \
        'source "$1"; redact_local_paths "$2"' _ "$RESOLVER_SRC" "$text"
}

@test "redact_local_paths makes repo-root paths relative" {
    run _redact /h/u/repo /h/u "see /h/u/repo/.claude/a.sh:10 now"
    [ "$status" -eq 0 ]
    [ "$output" = "see .claude/a.sh:10 now" ]
}

@test "redact_local_paths maps the bare repo root to a dot" {
    run _redact /h/u/repo /h/u "cwd=/h/u/repo,"
    [ "$output" = "cwd=.," ]
    run _redact /h/u/repo /h/u "in /h/u/repo"
    [ "$output" = "in ." ]
}

@test "redact_local_paths maps home to tilde" {
    run _redact /h/u/repo /h/u "cfg /h/u/.config/x and /h/u"
    [ "$output" = "cfg ~/.config/x and ~" ]
}

@test "redact_local_paths does not match a sibling dir sharing the prefix" {
    run _redact /h/u/repo /h/u "/h/u/repo2/a /h/u/repo-old/b /h/user/c"
    [ "$output" = "~/repo2/a ~/repo-old/b /h/user/c" ]
}

@test "redact_local_paths ignores prefix embedded inside a longer path" {
    run _redact /h/u/repo /h/u "/other/h/u/repo/a and /other/h/u"
    [ "$output" = "/other/h/u/repo/a and /other/h/u" ]
}

@test "redact_local_paths redacts every occurrence incl. repeats" {
    run _redact /h/u/repo /h/u "/h/u/repo/a /h/u/repo/b /h/u/x"
    [ "$output" = "a b ~/x" ]
}

@test "redact_local_paths reads stdin and preserves newlines" {
    run bash -c 'source "$1"; printf "/h/u/repo/a\n/h/u/b\n" \
        | PIPELINE_REDACT_ROOT=/h/u/repo HOME=/h/u redact_local_paths' \
        _ "$RESOLVER_SRC"
    [ "$status" -eq 0 ]
    [ "$output" = $'a\n~/b' ]
}

@test "redact_local_paths leaves unrelated text and empty input alone" {
    run _redact /h/u/repo /h/u "nothing here"
    [ "$output" = "nothing here" ]
    run _redact /h/u/repo /h/u ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "redact_local_paths tolerates trailing slash on root and home" {
    run _redact /h/u/repo/ /h/u/ "/h/u/repo/a /h/u/b"
    [ "$output" = "a ~/b" ]
}
