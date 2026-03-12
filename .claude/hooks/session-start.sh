#!/usr/bin/env bash
# SessionStart hook for project
# Injects the using-skills skill content into conversation context

set -euo pipefail

# Determine project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Read using-skills content
using_skills_content=$(cat "${PROJECT_ROOT}/.claude/skills/using-skills/SKILL.md" 2>&1 || echo "Error reading using-skills skill")

# Escape outputs for JSON using pure bash
escape_for_json() {
    local input="$1"
    local output=""
    local i char
    for (( i=0; i<${#input}; i++ )); do
        char="${input:$i:1}"
        case "$char" in
            $'\\') output+='\\' ;;
            '"') output+='\"' ;;
            $'\n') output+='\n' ;;
            $'\r') output+='\r' ;;
            $'\t') output+='\t' ;;
            *) output+="$char" ;;
        esac
    done
    printf '%s' "$output"
}

using_skills_escaped=$(escape_for_json "$using_skills_content")

# Check if local customizations exist
adaptation_warning=""
if [[ ! -d "${PROJECT_ROOT}/.claude/local" ]]; then
    adaptation_warning="\n\n**Pipeline not yet adapted:** No .claude/local/ directory found. Run /adapting-claude-pipeline to customize agents and config for this project. Generic defaults are active."
fi
adaptation_warning_escaped=$(escape_for_json "$adaptation_warning")

# Output context injection as JSON
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<EXTREMELY_IMPORTANT>\nYou have project-level skills.\n\n**Below is the full content of your 'using-skills' skill - your introduction to using skills. For all other skills, use the 'Skill' tool:**\n\n---\n${using_skills_escaped}\n${adaptation_warning_escaped}\n</EXTREMELY_IMPORTANT>"
  }
}
EOF

exit 0
