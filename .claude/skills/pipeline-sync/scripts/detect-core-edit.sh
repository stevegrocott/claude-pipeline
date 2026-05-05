#!/usr/bin/env bash
#
# PostToolUse hook: Detect edits to core pipeline files.
#
# When a core pipeline file (scripts, hooks, universal skill) is modified
# in a project repo, outputs a reminder to sync the change back to
# claude-pipeline. Skips if already inside the claude-pipeline repo.
#
# Called from settings.json PostToolUse hook on Edit|Write.
# Reads JSON from stdin with tool_name and tool_input.file_path.

if [[ -t 0 ]]; then
    exit 0
fi

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty')

if [[ "$tool_name" != "Edit" && "$tool_name" != "Write" ]]; then
    exit 0
fi

file_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
[[ -z "$file_path" ]] && exit 0

# Don't fire inside the claude-pipeline repo itself
if [[ "${CLAUDE_PROJECT_DIR:-}" == */claude-pipeline ]]; then
    exit 0
fi

# Check if edited file is a core pipeline file
is_core=false
match_reason=""

case "$file_path" in
    */.claude/scripts/*)
        is_core=true
        match_reason="core script"
        ;;
    */.claude/hooks/*)
        is_core=true
        match_reason="core hook"
        ;;
esac

# Check universal skills
if [[ "$file_path" == */.claude/skills/* ]]; then
    skill_name=$(echo "$file_path" | sed -n 's|.*/.claude/skills/\([^/]*\)/.*|\1|p')

    # Read universal skills list from sync.sh if available
    SYNC_SCRIPT="${CLAUDE_PROJECT_DIR:-.}/../claude-pipeline/sync.sh"
    if [[ ! -f "$SYNC_SCRIPT" ]]; then
        SYNC_SCRIPT="$HOME/Projects/claude-pipeline/sync.sh"
    fi

    if [[ -f "$SYNC_SCRIPT" ]]; then
        # Extract UNIVERSAL_SKILLS array from sync.sh
        if grep -q "\"$skill_name\"" "$SYNC_SCRIPT" 2>/dev/null; then
            is_core=true
            match_reason="universal skill"
        fi
    else
        # Fallback: hardcoded list of known universal skills
        case "$skill_name" in
            brainstorming|create-session-summary|dispatching-parallel-agents|\
            executing-plans|explore|handle-issues|implement-issue|improvement-loop|\
            investigating-codebase-for-user-stories|mcp-tools|playwright-testing|\
            process-pr|resume-session|subagent-driven-development|systematic-debugging|\
            test-driven-development|using-git-worktrees|using-skills|writing-agents|\
            writing-plans|writing-skills|adapting-claude-pipeline|pipeline-sync)
                is_core=true
                match_reason="universal skill"
                ;;
        esac
    fi
fi

if [[ "$is_core" == "true" ]]; then
    filename=$(basename "$file_path")
    cat <<EOF
You just edited a $match_reason ($filename). This is a core pipeline file shared across projects. If this change should be upstreamed, use the pipeline-sync skill:

  cd ~/Projects/claude-pipeline && ./sync.sh from $CLAUDE_PROJECT_DIR
EOF
fi
