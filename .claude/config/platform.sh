#!/bin/bash
# Platform configuration for this project
# Modified by /adapting-claude-pipeline during setup

# Issue tracker
TRACKER="${TRACKER:-github}"              # github | jira
TRACKER_CLI="${TRACKER_CLI:-gh}"          # gh | acli
JIRA_PROJECT="${JIRA_PROJECT:-}"          # Jira project key (e.g., KIN) — only used when TRACKER=jira
JIRA_DEFAULT_ISSUE_TYPE="${JIRA_DEFAULT_ISSUE_TYPE:-Task}"
JIRA_DONE_TRANSITION="${JIRA_DONE_TRANSITION:-Done}"
JIRA_IN_PROGRESS_TRANSITION="${JIRA_IN_PROGRESS_TRANSITION:-In Progress}"

# Git host
GIT_HOST="${GIT_HOST:-github}"            # github | gitlab
GIT_CLI="${GIT_CLI:-gh}"                  # gh | glab

# Merge strategy
MERGE_STYLE="${MERGE_STYLE:-squash}"      # squash | merge | rebase

# Test commands (set during /adapt based on project stack)
TEST_UNIT_CMD="${TEST_UNIT_CMD:-}"        # e.g., "npm test", "vendor/bin/phpunit", "pytest"
TEST_E2E_CMD="${TEST_E2E_CMD:-}"          # e.g., "npx playwright test" — empty if no E2E
TEST_E2E_BASE_URL="${TEST_E2E_BASE_URL:-}"

# Claude CLI (resolve path for non-interactive shells where aliases aren't available)
if [[ -z "${CLAUDE_CLI:-}" ]]; then
  if [[ -x "$HOME/.claude/local/claude" ]]; then
    CLAUDE_CLI="$HOME/.claude/local/claude"
  else
    CLAUDE_CLI="claude"
  fi
fi

# Lint and format (set during /adapt)
LINT_CMD="${LINT_CMD:-}"
FORMAT_CMD="${FORMAT_CMD:-}"
