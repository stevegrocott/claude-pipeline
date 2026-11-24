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
# A third resolver, resolve_consumer_dir(), handles the same "outside the
# bundle" case but for a whole directory (agents/, skills/, etc.) rather than
# a single config file. See its docstring below for details.
#
# Usage:
#   source "$SCRIPT_DIR/resolve-pipeline-root.sh"
#   schema="$(resolve_pipeline_file schemas/stage-result.json)" || {
#       echo "schema not found" >&2; exit 1;
#   }
#   platform="$(resolve_consumer_file platform.sh)" || {
#       echo "platform.sh not found" >&2; exit 1;
#   }
#   agents_dir="$(resolve_consumer_dir agents)" || {
#       echo "agents dir not found" >&2; exit 1;
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
#
# resolve_consumer_dir <name>
#   Prints the first existing absolute path for the CONSUMER repo's
#   .claude/<name>/ directory (e.g. "agents", "skills") — the directory-level
#   counterpart to resolve_consumer_file(), for callers that need a whole
#   directory rather than one file inside .claude/config/. Searching:
#     1. $PIPELINE_<NAME>_DIR/    — explicit override (name uppercased, non
#        alnum characters folded to "_"; e.g. name="agents" checks
#        $PIPELINE_AGENTS_DIR). Honored only when set AND it exists.
#     2. <git-toplevel-or-PWD>/.claude/<name>/ — the consumer repo root,
#        resolved via `git rev-parse --show-toplevel`, falling back to $PWD
#        when not inside a git repo.
#     3. <dir-of-this-library>/../<name>/ — legacy repo-local fallback.
#        Identical directory to (2) in the repo-local layout, so existing
#        consumers see no behavior change.
#   On a hit: prints the absolute path and returns 0.
#   On a miss (or empty argument): prints nothing and returns non-zero.
#
# redact_local_paths [text]
#   Prints text (argument or stdin) with the repo root made relative and
#   $HOME replaced by "~" (and its dash-encoded form by "-HOME"),
#   path-boundary safe. See its docstring below.

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

    # resolve_consumer_dir <name>
    #   Directory-level counterpart to resolve_consumer_file(): locates a
    #   CONSUMER repo's .claude/<name>/ directory (agents/, skills/, etc.)
    #   rather than a single file under .claude/config/. Searches:
    #     1. $PIPELINE_<NAME>_DIR — explicit override; <name> uppercased with
    #        non alnum characters folded to "_" (e.g. name="agents" checks
    #        $PIPELINE_AGENTS_DIR). Honored only when set AND the directory
    #        exists there.
    #     2. <git-toplevel-or-PWD>/.claude/<name> — the consumer repo root,
    #        falling back to $PWD when not inside a git repo (e.g. a
    #        stripped-down CI checkout).
    #     3. <dir-of-this-library>/../<name> — legacy fallback: <name>
    #        sibling of this library's scripts/ dir. Identical directory to
    #        (2) in the repo-local layout, so existing consumers see no
    #        behavior change.
    #   On a hit: prints the absolute path and returns 0.
    #   On a miss (or empty argument): prints nothing and returns non-zero.
    resolve_consumer_dir() {
        local name="$1"
        [[ -n "$name" ]] || return 1

        # 1. Explicit override via PIPELINE_<NAME>_DIR. Built with tr (not
        #    bash 4's ${name^^}) so this stays compatible with macOS-system
        #    bash 3.2. Non alnum characters (e.g. "-") become "_" so a name
        #    like "test-fixtures" still maps to a valid variable name.
        local override_var
        override_var="PIPELINE_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')_DIR"
        override_var="$(printf '%s' "$override_var" | tr -c 'A-Z0-9_' '_')"
        local override_dir="${!override_var:-}"
        if [[ -n "$override_dir" && -e "$override_dir" ]]; then
            printf '%s\n' "$override_dir"
            return 0
        fi

        # 2. Consumer repo root: git toplevel, falling back to $PWD when
        #    not inside a git repo (e.g. a stripped-down CI checkout).
        local consumer_root
        consumer_root="$(git rev-parse --show-toplevel 2>/dev/null)"
        consumer_root="${consumer_root:-$PWD}"
        if [[ -e "${consumer_root}/.claude/${name}" ]]; then
            printf '%s\n' "${consumer_root}/.claude/${name}"
            return 0
        fi

        # 3. Legacy fallback: <name> sibling of this library's scripts/
        #    dir. Normalize away the ".." so callers get a clean path.
        local legacy_dir="${_PIPELINE_SCRIPTS_DIR}/../${name}"
        if [[ -e "$legacy_dir" ]]; then
            printf '%s\n' "$(cd "$legacy_dir" && pwd)"
            return 0
        fi

        return 1
    }

    # pipeline_plugin_root
    #   Prints the plugin root (the dir holding bin/, scripts/ and
    #   .claude-plugin/) when this library lives in a plugin bundle, i.e. the
    #   parent of the scripts dir has .claude-plugin/plugin.json. Returns
    #   non-zero (printing nothing) in the repo-local .claude/scripts layout.
    pipeline_plugin_root() {
        local root
        root="$(cd "${_PIPELINE_SCRIPTS_DIR}/.." && pwd)" || return 1
        [[ -f "${root}/.claude-plugin/plugin.json" ]] || return 1
        printf '%s\n' "$root"
    }

    # pipeline_pin_bin_first
    #   Puts THIS version's bin/ first on PATH (de-duplicated) and exports it,
    #   so every session the run starts resolves the pipeline-core-* shims to
    #   the version that is running — not to a stale entry inherited from a
    #   long-lived session. A no-op returning non-zero when there is no bin/
    #   next to this library (repo-local layout). Sibling-version bins
    #   (<cache>/<other version>/bin) are dropped too and listed, colon
    #   separated, in PIPELINE_PIN_REMOVED; other plugins' bins are kept.
    pipeline_pin_bin_first() {
        local bin_dir
        bin_dir="$(cd "${_PIPELINE_SCRIPTS_DIR}/../bin" 2>/dev/null && pwd)" \
            || return 1
        local cache_dir="${bin_dir%/*/bin}"
        local entry ver
        local -a kept=()
        local -a removed=()
        local -a entries=()
        IFS=: read -r -a entries <<< "$PATH"
        for entry in "${entries[@]}"; do
            [[ "$entry" == "$bin_dir" ]] && continue
            # Sibling version bin: <cache>/<numeric version>/bin
            if [[ "$entry" == "${cache_dir}"/*/bin ]]; then
                ver="${entry#"${cache_dir}"/}"
                ver="${ver%/bin}"
                if [[ "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
                    removed+=("$entry")
                    continue
                fi
            fi
            kept+=("$entry")
        done
        local IFS=:
        PATH="${bin_dir}${kept[*]:+:${kept[*]}}"
        PIPELINE_PIN_REMOVED="${removed[*]}"
        export PATH PIPELINE_PIN_REMOVED
    }

    # pipeline_version
    #   Prints the running plugin's version from .claude-plugin/plugin.json.
    #   Returns non-zero (printing nothing) when it cannot be determined.
    pipeline_version() {
        local root version
        root="$(pipeline_plugin_root)" || return 1
        version="$(sed -n \
            's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "${root}/.claude-plugin/plugin.json" | head -n 1)"
        [[ -n "$version" ]] || return 1
        printf '%s\n' "$version"
    }

    # pipeline_newer_versions
    #   Prints (one per line, ascending) the sibling plugin versions in the
    #   cache dir that are newer than the running one. Prints nothing and
    #   returns 0 when the running version is the newest or there are no
    #   versioned siblings; returns non-zero if the version is unknown.
    pipeline_newer_versions() {
        local root version parent dir name
        local -a found=()
        root="$(pipeline_plugin_root)" || return 1
        version="$(pipeline_version)" || return 1
        parent="${root%/*}"
        for dir in "$parent"/*/; do
            [[ -d "$dir" ]] || continue
            dir="${dir%/}"
            name="${dir##*/}"
            [[ "$name" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
            [[ "$name" == "$version" ]] && continue
            found+=("$name")
        done
        ((${#found[@]} > 0)) || return 0
        printf '%s\n' "${found[@]}" "$version" \
            | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n \
            | awk -v v="$version" 'seen { print } $0 == v { seen = 1 }'
    }

    # _redact_prefix <text> <prefix> <bare-replacement> <slash-replacement>
    #                [any-before]
    #   Prints <text> with every path-boundary-safe occurrence of <prefix>
    #   replaced: "<prefix>/" becomes <slash-replacement>, a bare "<prefix>"
    #   becomes <bare-replacement>. A hit counts only when the char before it
    #   is not a path char and the char after it is "/" or not a name char,
    #   so /home/u/repo never matches inside /home/u/repo2 or /x/home/u/repo.
    #   With a non-empty [any-before] (the $HOME rule) the preceding-char
    #   check is skipped, so a home prefix is redacted after ANY character
    #   (e.g. "path=/home/u/x" or "/other/home/u"), and a single trailing
    #   "." that ends the text or precedes a non-name char is a sentence
    #   boundary, not a name char ("/home/u." -> "~.").
    #   Pure bash 3.2 (no regex captures, no ${var^^}).
    _redact_prefix() {
        local text="$1" prefix="$2" bare="$3" slashed="$4" anybefore="${5:-}"
        local out="" before after rest
        while [[ "$text" == *"$prefix"* ]]; do
            before="${text%%"$prefix"*}"
            after="${text#*"$prefix"}"
            out+="$before"
            if [[ -z "$anybefore" && -n "$before" \
                && "${before: -1}" == [A-Za-z0-9._~/-] ]]; then
                out+="$prefix"
            elif [[ "$after" == /* ]]; then
                out+="$slashed"
                after="${after#/}"
            elif [[ -z "$after" || "${after:0:1}" != [A-Za-z0-9._-] ]]; then
                out+="$bare"
            elif [[ -n "$anybefore" && "${after:0:1}" == "." ]] \
                && rest="${after:1}" \
                && [[ -z "$rest" || "${rest:0:1}" != [A-Za-z0-9._-] ]]; then
                out+="$bare"
            else
                out+="$prefix"
            fi
            text="$after"
        done
        printf '%s' "${out}${text}"
    }

    # _redact_dash_home <text> <dash-home>
    #   Prints <text> with each dash-encoded home (e.g. "-Users-me", how
    #   Claude names ~/.claude/projects dirs) replaced by "-HOME". A hit
    #   counts only when the char before it is not a name char or "-" (so
    #   "--root-dir" is untouched) and the char after is not a name char.
    _redact_dash_home() {
        local text="$1" prefix="$2"
        local out="" before after
        while [[ "$text" == *"$prefix"* ]]; do
            before="${text%%"$prefix"*}"
            after="${text#*"$prefix"}"
            out+="$before"
            if [[ -n "$before" && "${before: -1}" == [A-Za-z0-9._~-] ]]; then
                out+="$prefix"
            elif [[ -n "$after" && "${after:0:1}" == [A-Za-z0-9_.] ]]; then
                out+="$prefix"
            else
                out+="-HOME"
            fi
            text="$after"
        done
        printf '%s' "${out}${text}"
    }

    # redact_local_paths [text]
    #   Prints <text> (or stdin when no argument is given) with machine-local
    #   absolute paths made safe to publish: the repo root (override via
    #   $PIPELINE_REDACT_ROOT, else git toplevel) becomes a relative path
    #   ("." for the root itself) and $HOME becomes "~". The repo root is
    #   handled first because it normally lives under $HOME. In a linked
    #   worktree the main checkout root is redacted too ("<main>"). Matching
    #   is path-boundary safe (see _redact_prefix). PIPELINE_REDACT_PATHS=0
    #   passes the text through untouched. Always returns 0.
    redact_local_paths() {
        local text root home main common
        if (($# > 0)); then
            text="$1"
        else
            text="$(cat; printf x)"
            text="${text%x}"
        fi
        if [[ "${PIPELINE_REDACT_PATHS:-}" == "0" ]]; then
            printf '%s' "$text"
            return 0
        fi
        root="${PIPELINE_REDACT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
        home="${HOME:-}"
        while [[ "$root" == */ ]]; do root="${root%/}"; done
        while [[ "$home" == */ ]]; do home="${home%/}"; done
        if [[ -n "$root" ]]; then
            text="$(_redact_prefix "$text" "$root" "." ""; printf x)"
            text="${text%x}"
            # Linked worktree: the main checkout is the parent of the
            # shared git dir. Absent (or equal to root) in a plain clone.
            common="$(cd "$root" 2>/dev/null \
                && git rev-parse --git-common-dir 2>/dev/null)"
            if [[ -n "$common" ]]; then
                [[ "$common" == /* ]] || common="$root/$common"
                common="$(cd "$common" 2>/dev/null && pwd -P)"
                main="${common%/.git}"
                while [[ "$main" == */ ]]; do main="${main%/}"; done
                if [[ "$common" == */.git && -n "$main" \
                    && "$main" != "$root" ]]; then
                    text="$(_redact_prefix "$text" "$main" \
                        "<main>" "<main>/"; printf x)"
                    text="${text%x}"
                fi
            fi
        fi
        if [[ -n "$home" ]]; then
            text="$(_redact_prefix "$text" "$home" "~" "~/" any; printf x)"
            text="${text%x}"
            # Dash-encoded home (two or more segments); /root stays alone.
            local dash="${home//\//-}"
            if [[ "${home#/}" == */* ]]; then
                text="$(_redact_dash_home "$text" "$dash"; printf x)"
                text="${text%x}"
            fi
        fi
        printf '%s' "$text"
    }
fi
