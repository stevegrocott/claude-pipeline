#!/usr/bin/env bash
#
# sync.sh — Sync core pipeline files between claude-pipeline and project repos
#
# Core files (scripts, hooks, schemas) are identical across projects.
# Adapted files (agents, skills, config, prompts) are project-specific
# and never synced.
#
# Usage:
#   ./sync.sh to   <project-path>   # Push core files to a project
#   ./sync.sh from <project-path>   # Pull core fixes from a project
#   ./sync.sh diff <project-path>   # Show differences in core files
#   ./sync.sh list                   # List core files that get synced
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PIPELINE_DIR="$SCRIPT_DIR/.claude"
# Universal skills were migrated out of .claude/skills/ into the pipeline-core
# plugin. When the pipeline is the sync source, skills are resolved from here
# as a fallback so plugin-hosted skill docs still propagate to consumers'
# .claude/skills/ until they adopt the plugin marketplace directly.
PLUGIN_SKILLS_DIR="$SCRIPT_DIR/plugins/pipeline-core/skills"
# Bundled plugin script tree — what consumers install. Hand-editing this tree
# is how it drifts from .claude/scripts/ (issue #623); `bundle` regenerates
# it instead.
BUNDLE_SCRIPTS_DIR="$SCRIPT_DIR/plugins/pipeline-core/scripts"

# ---------------------------------------------------------------------------
# Core files — synced between pipeline and projects.
# These are the orchestration engine; they don't contain project-specific config.
# ---------------------------------------------------------------------------
CORE_DIRS=(
    "scripts"
    "hooks"
)

# Files within .claude/ that are core (synced individually, wholesale-copied).
#
# settings.json is intentionally NOT here: every consumer customizes it
# (permissions, env, project hooks), so a wholesale copy would clobber that
# config. Instead, `to` calls register_detect_hook() which MERGES only the
# required detect-core-edit.sh hook into the project's own settings.json,
# leaving everything else untouched. Add a file here only if it is truly
# identical across all projects.
CORE_FILES=()

# ---------------------------------------------------------------------------
# Adapted files — NEVER synced. Project-specific.
# ---------------------------------------------------------------------------
# agents/*.md          — rewritten per project stack
# config/platform.sh   — project-specific tracker, git host, test commands
# prompts/*.md         — project-specific review checklists
# skills/              — mix of universal and adapted (handled separately)

# ---------------------------------------------------------------------------
# Skills — some are universal (synced), some are adapted (not synced).
# Universal skills are process-focused and stack-agnostic.
# ---------------------------------------------------------------------------
UNIVERSAL_SKILLS=(
    "brainstorming"
    "create-session-summary"
    "dispatching-parallel-agents"
    "executing-plans"
    "explore"
    "handle-issues"
    "implement-issue"
    "improvement-loop"
    "investigating-codebase-for-user-stories"
    "mcp-tools"
    "playwright-testing"
    "process-pr"
    "resume-session"
    "subagent-driven-development"
    "systematic-debugging"
    "test-driven-development"
    "using-git-worktrees"
    "using-skills"
    "writing-agents"
    "writing-plans"
    "writing-skills"
    "adapting-claude-pipeline"
    "pipeline-sync"
    "pr-creation"
    "pr-review"
    "complete-summary"
    "test-validation"
    "fix-from-review"
    "test-discovery"
    "enrich-issue"
)

# ---------------------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage: ./sync.sh <command> <project-path>

Commands:
  to     <path>   Push core pipeline files TO a project's .claude/
  from   <path>   Pull core pipeline fixes FROM a project's .claude/
  diff   <path>   Show differences between pipeline and project core files
  bundle          Regenerate plugins/pipeline-core/scripts/ from .claude/scripts/
  list            List all core files that get synced

Examples:
  ./sync.sh to     ~/Projects/allied-universal-assign
  ./sync.sh from   ~/Projects/allied-universal-assign
  ./sync.sh diff   ~/Projects/allied-universal-assign
  ./sync.sh bundle
USAGE
    exit 1
}

# Resolve the .claude directory in a project
resolve_project_dir() {
    local project_path="$1"
    local claude_dir="$project_path/.claude"

    if [[ ! -d "$claude_dir" ]]; then
        echo "ERROR: $claude_dir does not exist. Run /adapting-claude-pipeline first." >&2
        exit 1
    fi

    printf '%s' "$claude_dir"
}

# Sync a directory (rsync-style, preserving structure)
sync_dir() {
    local src="$1" dst="$2" dir="$3"

    if [[ ! -d "$src/$dir" ]]; then
        echo "  SKIP $dir/ (not in source)"
        return
    fi

    mkdir -p "$dst/$dir"
    rsync -a --delete \
        --exclude '.DS_Store' \
        "$src/$dir/" "$dst/$dir/"
    echo "  SYNC $dir/"
}

# Sync a single file
sync_file() {
    local src="$1" dst="$2" file="$3"

    if [[ ! -f "$src/$file" ]]; then
        echo "  SKIP $file (not in source)"
        return
    fi

    cp "$src/$file" "$dst/$file"
    echo "  SYNC $file"
}

# Sync universal skills (directory-level sync for each skill)
sync_skills() {
    local src="$1" dst="$2"

    for skill in "${UNIVERSAL_SKILLS[@]}"; do
        local skill_src
        skill_src=$(resolve_skill_src "$src" "$skill")
        if [[ -n "$skill_src" ]]; then
            mkdir -p "$dst/skills/$skill"
            rsync -a --delete \
                --exclude '.DS_Store' \
                "$skill_src/" "$dst/skills/$skill/"
            echo "  SYNC skills/$skill/"
        else
            echo "  SKIP skills/$skill/ (not in source)"
        fi
    done
}

# Resolve a universal skill's source directory. Skills were migrated out of
# .claude/skills/ into plugins/pipeline-core/skills/; when the source is the
# pipeline, fall back to the plugin location so plugin-hosted skills still
# sync. Prints the resolved dir, or nothing if the skill is not in source.
resolve_skill_src() {
    local base="$1" skill="$2"
    if [[ -d "$base/skills/$skill" ]]; then
        printf '%s' "$base/skills/$skill"
    elif [[ "$base" == "$PIPELINE_DIR" && -d "$PLUGIN_SKILLS_DIR/$skill" ]]; then
        printf '%s' "$PLUGIN_SKILLS_DIR/$skill"
    fi
}

# Subdirectories bundled alongside the top-level scripts. Kept in lockstep
# with PARITY_SUBDIRS in
# .claude/scripts/implement-issue-test/test-bundle-parity.bats — both lists
# must name the same directories or the generator and the guard silently
# diverge on scope again (issue #623).
BUNDLE_SCRIPT_SUBDIRS=(platform prompts schemas)

# ---------------------------------------------------------------------------
# Hook bundling (issue #640). plugins/pipeline-core/hooks/scripts/ used to be
# a hand-maintained copy of .claude/hooks/ with nothing enforcing agreement —
# the same unguarded arrangement that let the script bundle ship a broken
# release in #623. These three lists make hook scope EXPLICIT, and are kept
# in lockstep with PARITY_BUNDLE_HOOKS / PARITY_PROJECT_LOCAL_HOOKS /
# PARITY_PLUGIN_ONLY_HOOKS in
# .claude/scripts/implement-issue-test/test-bundle-parity.bats, which fails
# when the generator and the guard disagree.
#
# Not every hook in .claude/hooks/ belongs in a consumer's plugin install, so
# bundling is an ALLOWLIST rather than a directory mirror. The not-shipped set
# is named just as explicitly: a hook added here later and forgotten must show
# up as an unclassified-hook test failure, not silently never ship.
# ---------------------------------------------------------------------------

# Pipeline-owned hooks that ship in the plugin. Each is a core pipeline
# guardrail a consumer loses the moment it migrates off copied .claude/hooks/.
BUNDLE_HOOKS=(
    block-gh-issue-create.sh
    pipeline-status-inject.sh
    post-pr-simplify.sh
    pre-commit-skill-validate.sh
)

# Hooks that deliberately do NOT ship:
#   block-destructive-db-commands.sh  DB safety; not every consumer has a DB
#   rtk-rewrite.sh                    routes commands through project tooling
#   session-start.sh                  project-local session banner; unwired
#   sync-reminder.sh                  RETIRED for plugin consumers — it exists
#                                     to remind you to sync core pipeline
#                                     changes back upstream, which is
#                                     meaningless once the plugin IS the
#                                     source of those files
PROJECT_LOCAL_HOOKS=(
    block-destructive-db-commands.sh
    rtk-rewrite.sh
    session-start.sh
    sync-reminder.sh
)

# Hooks that live only in the bundle and have no .claude/hooks/ counterpart by
# design. The regenerator must not delete these.
PLUGIN_ONLY_HOOKS=(
    scaffold-placeholder.sh
)

# True when $1 appears among the remaining arguments.
_hook_listed() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# Regenerate the bundled hook tree from the canonical .claude/hooks/ tree —
# like the script bundle, this is PRODUCED, not hand-edited. Copies every hook
# named in BUNDLE_HOOKS and removes anything else that is not explicitly
# plugin-only, so the two trees cannot silently drift.
bundle_hooks() {
    local src="$PIPELINE_DIR/hooks"
    local dst="${BUNDLE_SCRIPTS_DIR%/scripts}/hooks/scripts"

    # No canonical hook tree to bundle from — nothing to regenerate. This is
    # not fatal: the parity guard is what fails when an allowlisted hook has
    # no canonical counterpart, so a missing tree surfaces there rather than
    # aborting an otherwise valid script-bundle run.
    if [[ ! -d "$src" ]]; then
        return 0
    fi

    mkdir -p "$dst"

    local existing base keep
    for existing in "$dst"/*; do
        [[ -f "$existing" ]] || continue
        base=${existing##*/}

        keep=0
        if _hook_listed "$base" "${PLUGIN_ONLY_HOOKS[@]}"; then
            keep=1
        elif _hook_listed "$base" "${BUNDLE_HOOKS[@]}" && [[ -f "$src/$base" ]]; then
            keep=1
        fi

        if ((keep == 0)); then
            rm "$existing"
            echo "  REMOVE hooks/$base (not an allowlisted pipeline hook)"
        fi
    done

    local hook
    for hook in "${BUNDLE_HOOKS[@]}"; do
        if [[ ! -f "$src/$hook" ]]; then
            echo "ERROR: allowlisted hook missing: $src/$hook" >&2
            echo "       Fix BUNDLE_HOOKS or restore the hook." >&2
            exit 1
        fi
        if [[ -f "$dst/$hook" ]] && \
            diff -q "$src/$hook" "$dst/$hook" > /dev/null 2>&1; then
            continue
        fi
        cp "$src/$hook" "$dst/$hook"
        chmod +x "$dst/$hook"
        echo "  BUNDLE hooks/$hook"
    done
}

# Regenerate one directory level of the bundle: copy every file in $src_dir
# matching $pattern that is missing/stale in $dst_dir, and remove files in
# $dst_dir with no canonical counterpart. $label prefixes progress output
# (e.g. "platform/").
_bundle_scripts_dir() {
    local src_dir="$1" dst_dir="$2" label="$3" pattern="$4"
    local existing base canonical

    for existing in "$dst_dir"/$pattern; do
        [[ -f "$existing" ]] || continue
        base=$(basename "$existing")
        if [[ ! -f "$src_dir/$base" ]]; then
            rm "$existing"
            echo "  REMOVE $label$base (no longer in .claude/scripts/)"
        fi
    done

    for canonical in "$src_dir"/$pattern; do
        [[ -f "$canonical" ]] || continue
        base=$(basename "$canonical")
        if [[ -f "$dst_dir/$base" ]] && \
            diff -q "$canonical" "$dst_dir/$base" > /dev/null 2>&1; then
            continue
        fi
        cp "$canonical" "$dst_dir/$base"
        echo "  BUNDLE $label$base"
    done
}

# Regenerate the bundled plugin script tree from the canonical .claude/scripts/
# tree (issue #623) — the bundle is PRODUCED, not hand-edited. Copies every
# canonical top-level *.sh plus every file under platform/, prompts/, and
# schemas/ into the bundle, and removes bundled files with no canonical
# counterpart, so the two trees never silently drift again. Also regenerates
# the bundled hook tree from .claude/hooks/ via bundle_hooks() (issue #640).
bundle_scripts() {
    local src="$PIPELINE_DIR/scripts"
    local dst="$BUNDLE_SCRIPTS_DIR"

    if [[ ! -d "$src" ]]; then
        echo "ERROR: $src does not exist." >&2
        exit 1
    fi

    mkdir -p "$dst"

    echo "Regenerating bundle: .claude/scripts/ -> plugins/pipeline-core/scripts/"
    echo ""

    _bundle_scripts_dir "$src" "$dst" "" "*.sh"

    local sub
    for sub in "${BUNDLE_SCRIPT_SUBDIRS[@]}"; do
        [[ -d "$src/$sub" ]] || continue
        mkdir -p "$dst/$sub"
        _bundle_scripts_dir "$src/$sub" "$dst/$sub" "$sub/" "*"
    done

    # Hooks are part of the same bundle and are regenerated in the same pass,
    # so `./sync.sh bundle` leaves no hand-maintained corner behind (#640).
    bundle_hooks

    echo ""
    echo "Done. Bundle regenerated from .claude/scripts/ and .claude/hooks/."
}

# Strip <!-- STACK-SPECIFIC: --> from line 1 of consumer agent files.
# Agents whose first line is already --- are left untouched.
# HTML comments that appear after line 1 are never removed.
patch_agents() {
	local dst="$1"
	local agents_dir="$dst/agents"

	[[ -d "$agents_dir" ]] || return

	local file first_line tmp
	local patched=0
	for file in "$agents_dir"/*.md; do
		[[ -f "$file" ]] || continue
		IFS= read -r first_line < "$file"
		if [[ "$first_line" == '<!-- STACK-SPECIFIC:'* ]]; then
			tmp=$(mktemp)
			tail -n +2 "$file" > "$tmp" && mv "$tmp" "$file"
			echo "  PATCH agents/${file##*/}" \
				"(stripped STACK-SPECIFIC comment from line 1)"
			patched=$((patched + 1))
		fi
	done

	if [[ "$patched" -eq 0 ]]; then
		echo "  OK   agents/ (no STACK-SPECIFIC line-1 comments found)"
	fi
}

# Diff a directory
diff_dir() {
    local src="$1" dst="$2" dir="$3"

    if [[ ! -d "$src/$dir" || ! -d "$dst/$dir" ]]; then
        echo "  SKIP $dir/ (missing in one side)"
        return
    fi

    local changes
    changes=$(diff -rq "$src/$dir" "$dst/$dir" \
        --exclude '.DS_Store' \
        --exclude '__pycache__' 2>/dev/null) || true

    if [[ -z "$changes" ]]; then
        echo "  OK   $dir/"
    else
        echo "  DIFF $dir/"
        echo "$changes" | sed 's/^/       /'
    fi
}

# Diff a single file
diff_file() {
    local src="$1" dst="$2" file="$3"

    if [[ ! -f "$src/$file" || ! -f "$dst/$file" ]]; then
        echo "  SKIP $file (missing in one side)"
        return
    fi

    if diff -q "$src/$file" "$dst/$file" > /dev/null 2>&1; then
        echo "  OK   $file"
    else
        echo "  DIFF $file"
        diff -u "$src/$file" "$dst/$file" | head -20 | sed 's/^/       /'
    fi
}

# Register detect-core-edit.sh hook in a project's settings.json if not already present
register_detect_hook() {
    local settings_path="$1"

    if [[ ! -f "$settings_path" ]]; then
        return
    fi

    # Check if already registered
    local already
    already=$(jq -r '
        .hooks.PostToolUse[]?
        | select(.matcher == "Edit|Write")
        | .hooks[]?
        | select(.command != null)
        | .command
        | select(contains("detect-core-edit.sh"))
    ' "$settings_path" 2>/dev/null)

    if [[ -n "$already" ]]; then
        return
    fi

    # Add the hook entry
    local hook_entry='{"type":"command","command":"\"$CLAUDE_PROJECT_DIR/.claude/skills/pipeline-sync/scripts/detect-core-edit.sh\"","timeout":10}'

    local tmp
    tmp=$(mktemp)
    jq --argjson entry "$hook_entry" '
        .hooks.PostToolUse = [
            .hooks.PostToolUse[]
            | if .matcher == "Edit|Write" then
                .hooks += [$entry]
              else
                .
              end
        ]
    ' "$settings_path" > "$tmp" && mv "$tmp" "$settings_path"

    echo "  HOOK detect-core-edit.sh registered in project settings.json"
}

# Diff universal skills
diff_skills() {
    local src="$1" dst="$2"

    for skill in "${UNIVERSAL_SKILLS[@]}"; do
        local skill_src
        skill_src=$(resolve_skill_src "$src" "$skill")
        if [[ -n "$skill_src" && -d "$dst/skills/$skill" ]]; then
            local changes
            changes=$(diff -rq "$skill_src" "$dst/skills/$skill" \
                --exclude '.DS_Store' 2>/dev/null) || true
            if [[ -z "$changes" ]]; then
                echo "  OK   skills/$skill/"
            else
                echo "  DIFF skills/$skill/"
                echo "$changes" | sed 's/^/       /'
            fi
        fi
    done
}

# List all core files
list_core() {
    echo "Core directories (fully synced):"
    for dir in "${CORE_DIRS[@]}"; do
        echo "  .claude/$dir/"
    done

    echo ""
    echo "Core files (individually synced):"
    for file in ${CORE_FILES[@]+"${CORE_FILES[@]}"}; do
        echo "  .claude/$file"
    done

    echo ""
    echo "Universal skills (synced):"
    for skill in "${UNIVERSAL_SKILLS[@]}"; do
        echo "  .claude/skills/$skill/"
    done

    echo ""
    echo "Never synced (project-specific):"
    echo "  .claude/agents/*.md"
    echo "  .claude/config/platform.sh"
    echo "  .claude/prompts/*.md"
    echo "  .claude/skills/ (non-universal skills)"
}

# Deprecation notice for the script/skill copy path. Marketplace consumers
# should enable the pipeline-core plugin instead of copying files. Non-fatal:
# the legacy copy still runs below for mid-transition consumers that have not
# adopted the plugin marketplace yet.
print_marketplace_deprecation() {
    cat <<'NOTICE'
  ---------------------------------------------------------------------------
  DEPRECATED: copying .claude/scripts + skills into a consumer is being phased
  out in favour of the pipeline-core marketplace plugin (no file copying).

  Prefer: merge plugins/pipeline-core/consumer-settings.example.json into the
  consumer's .claude/settings.json and commit it — Claude Code then resolves
  scripts, schemas, skills, and hooks from the installed plugin.

  The legacy copy below still runs for mid-transition consumers.
  ---------------------------------------------------------------------------
NOTICE
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[[ $# -lt 1 ]] && usage

COMMAND="$1"

case "$COMMAND" in
    to)
        [[ $# -lt 2 ]] && usage
        PROJECT_DIR=$(resolve_project_dir "$2")
        print_marketplace_deprecation
        echo ""
        echo "Syncing core files: pipeline → $2"
        echo ""

        for dir in "${CORE_DIRS[@]}"; do
            sync_dir "$PIPELINE_DIR" "$PROJECT_DIR" "$dir"
        done

        for file in ${CORE_FILES[@]+"${CORE_FILES[@]}"}; do
            sync_file "$PIPELINE_DIR" "$PROJECT_DIR" "$file"
        done

        echo ""
        echo "Syncing universal skills:"
        sync_skills "$PIPELINE_DIR" "$PROJECT_DIR"

        register_detect_hook "$PROJECT_DIR/settings.json"

        echo ""
        echo "Patching consumer agents:"
        patch_agents "$PROJECT_DIR"

        echo ""
        echo "Done. Project-specific files (config, prompts) untouched."
        ;;

    from)
        [[ $# -lt 2 ]] && usage
        PROJECT_DIR=$(resolve_project_dir "$2")
        echo "Pulling core fixes: $2 → pipeline"
        echo ""

        for dir in "${CORE_DIRS[@]}"; do
            sync_dir "$PROJECT_DIR" "$PIPELINE_DIR" "$dir"
        done

        for file in ${CORE_FILES[@]+"${CORE_FILES[@]}"}; do
            sync_file "$PROJECT_DIR" "$PIPELINE_DIR" "$file"
        done

        echo ""
        echo "Pulling universal skills:"
        sync_skills "$PROJECT_DIR" "$PIPELINE_DIR"

        echo ""
        echo "Done. Review changes with: cd $(dirname "$PIPELINE_DIR") && git diff"
        ;;

    diff)
        [[ $# -lt 2 ]] && usage
        PROJECT_DIR=$(resolve_project_dir "$2")
        echo "Comparing core files: pipeline vs $2"
        echo ""

        for dir in "${CORE_DIRS[@]}"; do
            diff_dir "$PIPELINE_DIR" "$PROJECT_DIR" "$dir"
        done

        for file in ${CORE_FILES[@]+"${CORE_FILES[@]}"}; do
            diff_file "$PIPELINE_DIR" "$PROJECT_DIR" "$file"
        done

        echo ""
        echo "Universal skills:"
        diff_skills "$PIPELINE_DIR" "$PROJECT_DIR"
        ;;

    bundle)
        bundle_scripts
        ;;

    list)
        list_core
        ;;

    *)
        usage
        ;;
esac
