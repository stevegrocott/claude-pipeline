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

# ---------------------------------------------------------------------------
# Core files — synced between pipeline and projects.
# These are the orchestration engine; they don't contain project-specific config.
# ---------------------------------------------------------------------------
CORE_DIRS=(
    "scripts"
    "hooks"
)

# Files within .claude/ that are core (synced individually)
CORE_FILES=(
    "settings.json"
)

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
  to   <path>   Push core pipeline files TO a project's .claude/
  from <path>   Pull core pipeline fixes FROM a project's .claude/
  diff <path>   Show differences between pipeline and project core files
  list          List all core files that get synced

Examples:
  ./sync.sh to   ~/Projects/allied-universal-assign
  ./sync.sh from ~/Projects/allied-universal-assign
  ./sync.sh diff ~/Projects/allied-universal-assign
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
        if [[ -d "$src/skills/$skill" ]]; then
            mkdir -p "$dst/skills/$skill"
            rsync -a --delete \
                --exclude '.DS_Store' \
                "$src/skills/$skill/" "$dst/skills/$skill/"
            echo "  SYNC skills/$skill/"
        else
            echo "  SKIP skills/$skill/ (not in source)"
        fi
    done
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
        if [[ -d "$src/skills/$skill" && -d "$dst/skills/$skill" ]]; then
            local changes
            changes=$(diff -rq "$src/skills/$skill" "$dst/skills/$skill" \
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
    for file in "${CORE_FILES[@]}"; do
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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

[[ $# -lt 1 ]] && usage

COMMAND="$1"

case "$COMMAND" in
    to)
        [[ $# -lt 2 ]] && usage
        PROJECT_DIR=$(resolve_project_dir "$2")
        echo "Syncing core files: pipeline → $2"
        echo ""

        for dir in "${CORE_DIRS[@]}"; do
            sync_dir "$PIPELINE_DIR" "$PROJECT_DIR" "$dir"
        done

        for file in "${CORE_FILES[@]}"; do
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

        for file in "${CORE_FILES[@]}"; do
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

        for file in "${CORE_FILES[@]}"; do
            diff_file "$PIPELINE_DIR" "$PROJECT_DIR" "$file"
        done

        echo ""
        echo "Universal skills:"
        diff_skills "$PIPELINE_DIR" "$PROJECT_DIR"
        ;;

    list)
        list_core
        ;;

    *)
        usage
        ;;
esac
