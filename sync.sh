#!/usr/bin/env bash
#
# sync.sh — Sync core pipeline files between claude-pipeline and project repos
#
# Core files (hooks, universal skills) are identical across projects.
# Adapted files (agents, prompts) are project-specific and never synced.
# Consumer config (config/platform.sh, config/context.md) is seeded once and
# then left alone.
#
# .claude/scripts/ is NOT synced (issue #632): it is this repo's dogfood tree,
# and consumers get the same scripts from the pipeline-core plugin bundle.
# assert_no_plugin_shadow() fails the sync if that scope ever widens again.
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
# Root of the plugin bundle. Anything under here is what a consumer installs
# via the marketplace, so anything the sync would ALSO copy into the consumer's
# .claude/ is a dead duplicate (see assert_no_plugin_shadow, issue #632).
PLUGIN_ROOT="$SCRIPT_DIR/plugins/pipeline-core"
# Bundled plugin script tree — what consumers install. Hand-editing this tree
# is how it drifts from .claude/scripts/ (issue #623); `bundle` regenerates
# it instead.
BUNDLE_SCRIPTS_DIR="$PLUGIN_ROOT/scripts"

# ---------------------------------------------------------------------------
# Core files — synced between pipeline and projects.
# These are the orchestration engine; they don't contain project-specific config.
#
# "scripts" is deliberately ABSENT (issue #632). .claude/scripts/ is this
# repo's DOGFOOD tree: the orchestrators it runs on itself, plus
# implement-issue-test/, platform-test/, schemas/ and prompts/. Consumers get
# every one of those from the plugin bundle (plugins/pipeline-core/scripts/,
# reached via pipeline-core-platform-dir and the bin/ entrypoints), so copying
# the tree in leaves files that are dead on arrival:
#
#   - implement-issue-test/ — 53 .bats suites that source
#     $SCRIPT_DIR/implement-issue-orchestrator.sh, which the plugin migration
#     removes from the consumer. Every test fails; wired into CI, CI is
#     permanently red.
#   - platform/ + platform-test/ — never executed, and UNREPAIRABLE by
#     re-syncing: upstream's copy needs ../resolve-pipeline-root.sh, which the
#     migration deletes from the consumer. Deletion is the only correct action.
#   - schemas/ + prompts/ — byte-identical to the bundle and never read; edits
#     to the consumer copy silently do nothing.
#
# 132 such files were left orphaned in stevegrocott/beegee-farm-3.
# assert_no_plugin_shadow() below is the guard that stops this recurring.
CORE_DIRS=(
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

# Genuinely consumer-side config (issue #632). The plugin provides no
# .claude/config/, so these are the consumer's own — its tracker, git host and
# test commands, and its project context. They are SEEDED, never overwritten:
# a consumer that has none gets a starting point, a consumer that has its own
# keeps it. A wholesale copy would push this repo's github/bats settings over a
# consumer's jira/phpunit ones.
CONSUMER_CONFIG_FILES=(
    "config/platform.sh"
    "config/context.md"
)

# ---------------------------------------------------------------------------
# Adapted files — NEVER synced. Project-specific.
# ---------------------------------------------------------------------------
# agents/*.md          — rewritten per project stack
# config/platform.sh   — project-specific tracker, git host, test commands
#                        (seeded if absent; never overwritten)
# prompts/*.md         — project-specific review checklists
# scripts/             — dogfood only; consumers get these from the plugin
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

# Seed consumer-owned config that the consumer does not have yet. Never
# overwrites: config/ holds the consumer's tracker, git host and test commands
# (issue #632).
sync_consumer_config() {
    local src="$1" dst="$2"
    local file

    for file in ${CONSUMER_CONFIG_FILES[@]+"${CONSUMER_CONFIG_FILES[@]}"}; do
        if [[ ! -f "$src/$file" ]]; then
            echo "  SKIP $file (not in source)"
            continue
        fi
        if [[ -f "$dst/$file" ]]; then
            echo "  KEEP $file (consumer-owned, left untouched)"
            continue
        fi
        mkdir -p "$(dirname "$dst/$file")"
        cp "$src/$file" "$dst/$file"
        echo "  SEED $file"
    done
}

# Every .claude-relative path a `to` sync would write into a consumer.
planned_sync_paths() {
    local dir file found

    # Strip the source prefix with parameter expansion rather than sed: the
    # path is data, and PIPELINE_DIR contains regex metacharacters (".claude").
    for dir in ${CORE_DIRS[@]+"${CORE_DIRS[@]}"}; do
        [[ -d "$PIPELINE_DIR/$dir" ]] || continue
        while IFS= read -r found; do
            [[ -n "$found" ]] || continue
            printf '%s\n' "${found#"$PIPELINE_DIR"/}"
        done < <(find "$PIPELINE_DIR/$dir" -type f ! -name '.DS_Store')
    done

    for file in ${CORE_FILES[@]+"${CORE_FILES[@]}"}; do
        [[ -f "$PIPELINE_DIR/$file" ]] && printf '%s\n' "$file"
    done

    for file in ${CONSUMER_CONFIG_FILES[@]+"${CONSUMER_CONFIG_FILES[@]}"}; do
        [[ -f "$PIPELINE_DIR/$file" ]] && printf '%s\n' "$file"
    done

    return 0
}

# Fail the sync when its scope overlaps the plugin bundle (issue #632).
#
# A consumer on the pipeline-core plugin already has everything under
# plugins/pipeline-core/. Copying the same relative path into its .claude/
# produces a second, never-executed copy that silently rots — and, once the
# migration removes the loaders those copies depend on, cannot be repaired by
# re-syncing. Comments alone did not prevent that (132 orphans in
# beegee-farm-3), so this is a hard gate: named paths, non-zero exit, nothing
# written.
#
# The check is per-FILE, not per-directory: .claude/hooks/ legitimately syncs
# because the plugin's hooks/ provides different files.
assert_no_plugin_shadow() {
    [[ -d "$PLUGIN_ROOT" ]] || return 0

    local rel shadowed=""
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        if [[ -e "$PLUGIN_ROOT/$rel" ]]; then
            shadowed+="  .claude/$rel"$'\n'
        fi
    done < <(planned_sync_paths)

    [[ -n "$shadowed" ]] || return 0

    {
        echo "ERROR: sync scope overlaps the pipeline-core plugin bundle."
        echo ""
        echo "These paths are already provided by plugins/pipeline-core/, so"
        echo "copying them into a consumer creates a dead duplicate (issue #632):"
        echo ""
        printf '%s' "$shadowed"
        echo ""
        echo "Remove them from CORE_DIRS / CORE_FILES / CONSUMER_CONFIG_FILES —"
        echo "consumers reach them through the plugin's bin/ entrypoints and"
        echo "pipeline-core-platform-dir instead."
    } >&2
    exit 1
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
# counterpart, so the two trees never silently drift again.
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

    echo ""
    echo "Done. Bundle regenerated from .claude/scripts/."
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
    for dir in ${CORE_DIRS[@]+"${CORE_DIRS[@]}"}; do
        echo "  .claude/$dir/"
    done

    echo ""
    echo "Core files (individually synced):"
    for file in ${CORE_FILES[@]+"${CORE_FILES[@]}"}; do
        echo "  .claude/$file"
    done

    echo ""
    echo "Consumer config (seeded only if absent, never overwritten):"
    for file in ${CONSUMER_CONFIG_FILES[@]+"${CONSUMER_CONFIG_FILES[@]}"}; do
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
    echo "  .claude/prompts/*.md"
    echo "  .claude/skills/ (non-universal skills)"

    echo ""
    echo "Never synced (dogfood only — consumers get these from the plugin):"
    echo "  .claude/scripts/  -> plugins/pipeline-core/scripts/"
    echo "                       via bin/pipeline-core-* and"
    echo "                       pipeline-core-platform-dir"
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
        # Fail BEFORE writing anything: a partially-applied sync is what
        # leaves orphans behind (issue #632).
        assert_no_plugin_shadow
        print_marketplace_deprecation
        echo ""
        echo "Syncing core files: pipeline → $2"
        echo ""

        for dir in ${CORE_DIRS[@]+"${CORE_DIRS[@]}"}; do
            sync_dir "$PIPELINE_DIR" "$PROJECT_DIR" "$dir"
        done

        for file in ${CORE_FILES[@]+"${CORE_FILES[@]}"}; do
            sync_file "$PIPELINE_DIR" "$PROJECT_DIR" "$file"
        done

        echo ""
        echo "Seeding consumer config (existing files left untouched):"
        sync_consumer_config "$PIPELINE_DIR" "$PROJECT_DIR"

        echo ""
        echo "Syncing universal skills:"
        sync_skills "$PIPELINE_DIR" "$PROJECT_DIR"

        register_detect_hook "$PROJECT_DIR/settings.json"

        echo ""
        echo "Patching consumer agents:"
        patch_agents "$PROJECT_DIR"

        echo ""
        echo "Done. Project-specific files (agents, prompts, existing config)"
        echo "untouched; .claude/scripts/ is never copied — consumers resolve"
        echo "those from the pipeline-core plugin."
        ;;

    from)
        [[ $# -lt 2 ]] && usage
        PROJECT_DIR=$(resolve_project_dir "$2")
        echo "Pulling core fixes: $2 → pipeline"
        echo ""

        for dir in ${CORE_DIRS[@]+"${CORE_DIRS[@]}"}; do
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

        for dir in ${CORE_DIRS[@]+"${CORE_DIRS[@]}"}; do
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
