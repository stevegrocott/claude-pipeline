#!/usr/bin/env bash
# shellcheck shell=bash
#
# resolve-pipeline-root.sh — self-locating pipeline scripts/schemas root resolver.
#
# Pipeline orchestration scripts + JSON schemas live in one of two layouts:
#   - the marketplace plugin bundle:  plugins/pipeline-core/scripts/
#   - repo-local (pipeline repo + mid-transition consumers):  .claude/scripts/
#
# This helper resolves a file relative to whichever layout the caller is running
# from WITHOUT depending on $CLAUDE_PLUGIN_ROOT being exported at runtime.
#
# Why not CLAUDE_PLUGIN_ROOT? Per issue #599 (Task 1 verification): that variable
# is UNSET in the model's Bash-tool shell. It is only a path-substitution
# placeholder the harness expands inside hooks.json command strings — NOT an env
# var exported to scripts a skill instructs the model to run. So the resolver
# SELF-LOCATES via ${BASH_SOURCE[0]} and treats CLAUDE_PLUGIN_ROOT only as an
# optional hint (use-if-set-and-present, never a hard dependency).
#
# Because this library ships as a sibling of the orchestrator scripts and the
# schemas/ directory, the directory it lives in IS the pipeline scripts root —
# identically in the plugin bundle and in the repo-local .claude/scripts/ layout.
# That makes the repo-local fallback inherent: no big-bang cutover needed.
#
# A companion resolver, resolve_consumer_file(), handles the opposite case:
# per-repo config (platform.sh, context.md) that lives OUTSIDE the bundle, in
# whichever repo installed the plugin. See its docstring below for details.
#
# Usage:
#   source "$SCRIPT_DIR/resolve-pipeline-root.sh"
#   schema="$(resolve_pipeline_file schemas/stage-result.json)" || {
#       echo "schema not found" >&2; exit 1;
#   }
#   platform="$(resolve_consumer_file platform.sh)" || {
#       echo "platform.sh not found" >&2; exit 1;
#   }
#
# resolve_pipeline_file <relative/path>
#   Prints the first existing absolute path for <relative/path>, searching:
#     1. $CLAUDE_PLUGIN_ROOT/scripts/<rel>  — optional hint; only when the var is
#        non-empty AND the file exists there.
#     2. <dir-of-this-library>/<rel>        — self-location via BASH_SOURCE; the
#        canonical path for both layouts.
#   On a hit: prints the absolute path and returns 0.
#   On a miss (or empty argument): prints nothing and returns non-zero.
#
# resolve_consumer_file <relative/path>
#   Prints the first existing absolute path for <relative/path> under the
#   CONSUMER repo's .claude/config/, searching:
#     1. $PIPELINE_CONFIG_DIR/<rel>              — explicit override.
#     2. <git-toplevel-or-PWD>/.claude/config/<rel> — the consumer repo root.
#     3. <dir-of-this-library>/../config/<rel>   — legacy repo-local fallback.
#   On a hit: prints the absolute path and returns 0.
#   On a miss (or empty argument): prints nothing and returns non-zero.

# Idempotent sourcing guard — skip re-definition on repeated source.
if [[ -z "${_RESOLVE_PIPELINE_ROOT_SOURCED:-}" ]]; then
    _RESOLVE_PIPELINE_ROOT_SOURCED=1

    # Directory this library lives in, captured once at source time. At the top
    # level of the file, ${BASH_SOURCE[0]} is this file's own path regardless of
    # who sourced it, so this pins the pipeline scripts root for later calls even
    # if the caller's own BASH_SOURCE context changes.
    _PIPELINE_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # resolve_pipeline_file <relative/path>
    resolve_pipeline_file() {
        local rel="$1"
        [[ -n "$rel" ]] || return 1

        # 1. Optional CLAUDE_PLUGIN_ROOT hint. Used only when the var is set AND
        #    the file actually exists under it — never a hard runtime dependency.
        if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -e "${CLAUDE_PLUGIN_ROOT}/scripts/${rel}" ]]; then
            printf '%s\n' "${CLAUDE_PLUGIN_ROOT}/scripts/${rel}"
            return 0
        fi

        # 2. Self-location: sibling of this library. Canonical for the plugin
        #    bundle and the repo-local .claude/scripts/ layout alike.
        if [[ -e "${_PIPELINE_SCRIPTS_DIR}/${rel}" ]]; then
            printf '%s\n' "${_PIPELINE_SCRIPTS_DIR}/${rel}"
            return 0
        fi

        return 1
    }

    # resolve_consumer_file <relative/path>
    #   Prints the first existing absolute path for <relative/path> within a
    #   CONSUMER repo's .claude/config/ directory — distinct from
    #   resolve_pipeline_file() above, which resolves assets that ship
    #   INSIDE the bundle (schemas, prompts). Consumer config (platform.sh,
    #   context.md) by definition lives OUTSIDE the bundle, in the repo that
    #   installed the plugin, so it needs its own root anchor. Searches:
    #     1. $PIPELINE_CONFIG_DIR/<rel>   — explicit override; useful in
    #        CI/tests. Honored only when set AND the file exists there.
    #     2. <git-toplevel-or-PWD>/.claude/config/<rel> — the consumer repo
    #        root, resolved via `git rev-parse --show-toplevel`, falling
    #        back to $PWD when not inside a git repo.
    #     3. <dir-of-this-library>/../config/<rel> — legacy repo-local
    #        fallback. Identical file to (2) in the repo-local layout, so
    #        existing consumers see no behavior change.
    #   On a hit: prints the absolute path and returns 0.
    #   On a miss (or empty argument): prints nothing and returns non-zero.
    resolve_consumer_file() {
        local rel="$1"
        [[ -n "$rel" ]] || return 1

        # 1. Explicit override via PIPELINE_CONFIG_DIR (e.g. CI/tests).
        if [[ -n "${PIPELINE_CONFIG_DIR:-}" && \
            -e "${PIPELINE_CONFIG_DIR}/${rel}" ]]; then
            printf '%s\n' "${PIPELINE_CONFIG_DIR}/${rel}"
            return 0
        fi

        # 2. Consumer repo root: git toplevel, falling back to $PWD when
        #    not inside a git repo (e.g. a stripped-down CI checkout).
        local consumer_root
        consumer_root="$(git rev-parse --show-toplevel 2>/dev/null)"
        consumer_root="${consumer_root:-$PWD}"
        if [[ -e "${consumer_root}/.claude/config/${rel}" ]]; then
            printf '%s\n' "${consumer_root}/.claude/config/${rel}"
            return 0
        fi

        # 3. Legacy fallback: config/ sibling of this library's scripts/
        #    dir. Normalize away the ".." so callers get a clean path.
        local legacy_config_dir="${_PIPELINE_SCRIPTS_DIR}/../config"
        if [[ -e "${legacy_config_dir}/${rel}" ]]; then
            printf '%s\n' "$(cd "$legacy_config_dir" && pwd)/${rel}"
            return 0
        fi

        return 1
    }
fi
