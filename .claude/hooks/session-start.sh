#!/usr/bin/env bash
# SessionStart hook for project
# Injects minimal skills pointer into conversation context

set -euo pipefail

# Output context injection as JSON
cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<EXTREMELY_IMPORTANT>\nYou have project-level skills. Use the Skill tool to read and execute skills as needed. Check available skills before starting any task.\n</EXTREMELY_IMPORTANT>"
  }
}
EOF

exit 0
