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

# Frontend path patterns — pipe-separated globs used by _matches_frontend_pattern()
# to decide whether a branch touches frontend code (gates E2E verification)
# e.g., "src/components/*|src/pages/*|tests/e2e/*"
FRONTEND_PATH_PATTERNS="${FRONTEND_PATH_PATTERNS:-}"

# Deploy verification (configure during /adapt if project has a test environment)
# Set DEPLOY_VERIFY_CMD to a shell command that triggers a deploy to the target
# environment (e.g., "./scripts/deploy-test.sh").  Leave empty to skip the stage.
# Set DEPLOY_VERIFY_HEALTH_URL to the health-check endpoint of that environment;
# the orchestrator polls it at 10 s intervals for up to 15 min (90 retries).
DEPLOY_VERIFY_CMD="${DEPLOY_VERIFY_CMD:-}"
DEPLOY_VERIFY_HEALTH_URL="${DEPLOY_VERIFY_HEALTH_URL:-}"
DEPLOY_VERIFY_TIMEOUT_SECS="${DEPLOY_VERIFY_TIMEOUT_SECS:-900}"  # Max seconds to poll health URL (default 15 min)

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

# Orchestrator iteration limits (override defaults from implement-issue-orchestrator.sh)
MAX_QUALITY_ITERATIONS="${MAX_QUALITY_ITERATIONS:-5}"
MAX_TEST_ITERATIONS="${MAX_TEST_ITERATIONS:-7}"
MAX_PR_REVIEW_ITERATIONS="${MAX_PR_REVIEW_ITERATIONS:-2}"
MAX_VALIDATION_FIX_ITERATIONS="${MAX_VALIDATION_FIX_ITERATIONS:-2}"
MAX_E2E_FIX_ITERATIONS="${MAX_E2E_FIX_ITERATIONS:-2}"
MAX_ORCHESTRATOR_WALL_TIME="${MAX_ORCHESTRATOR_WALL_TIME:-3600}"  # seconds (default 1 hour)
