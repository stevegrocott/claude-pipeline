#!/usr/bin/env bash
# UserPromptSubmit hook: inject pipeline status into conversation context
# Reads $CLAUDE_PROJECT_DIR/status.json; if state == "running", outputs
# a one-line status summary as additionalContext. Exits 0 silently otherwise.

set -euo pipefail

STATUS_FILE="${CLAUDE_PROJECT_DIR:-}/status.json"

# Exit silently if file doesn't exist
if [[ ! -f "$STATUS_FILE" ]]; then
    exit 0
fi

# Read fields using grep/sed (no jq dependency)
state=$(grep -o '"state"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATUS_FILE" | sed 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)

# Exit silently if not running
if [[ "$state" != "running" ]]; then
    exit 0
fi

issue=$(grep -o '"issue"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATUS_FILE" | sed 's/.*"issue"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
current_stage=$(grep -o '"current_stage"[[:space:]]*:[[:space:]]*"[^"]*"' "$STATUS_FILE" | sed 's/.*"current_stage"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
current_task=$(grep -o '"current_task"[[:space:]]*:[[:space:]]*[0-9]*' "$STATUS_FILE" | sed 's/.*"current_task"[[:space:]]*:[[:space:]]*\([0-9]*\)/\1/' || true)

summary="Pipeline running: issue #${issue}, stage: ${current_stage}, task: ${current_task}"

# Output context injection as JSON (same pattern as session-start.sh)
cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "${summary}"
  }
}
EOF

exit 0
