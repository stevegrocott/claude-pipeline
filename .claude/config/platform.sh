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
# AUTO_MERGE: set to 1 to automatically merge the PR after all checks pass.
# Set to 0 to leave the PR open for manual review and merging.
# MERGE_STYLE (above) controls the merge method used when AUTO_MERGE=1.
AUTO_MERGE="${AUTO_MERGE:-0}"             # 0 = manual merge | 1 = auto-merge when checks pass

# Test commands (set during /adapt based on project stack)
TEST_UNIT_CMD="${TEST_UNIT_CMD:-}"        # e.g., "npm test", "vendor/bin/phpunit", "pytest"
TEST_E2E_CMD="${TEST_E2E_CMD:-}"          # e.g., "npx playwright test" — empty if no E2E
TEST_E2E_BASE_URL="${TEST_E2E_BASE_URL:-}"
# TDD reordering for E2E: default true when TEST_E2E_CMD is set; set false to keep smoke tests only without TDD reordering
if [[ -z "${E2E_TDD_ENABLED:-}" ]]; then
  [[ -n "${TEST_E2E_CMD:-}" ]] && E2E_TDD_ENABLED=true || E2E_TDD_ENABLED=false
fi

# RTK (Rust Token Killer) opt-in — https://github.com/rtk-ai/rtk
# Rewrites verbose commands (git status, ls, grep, find, git diff, test
# runners) and filters/truncates output, cutting LLM token use 60-90%.
# Scoped to THIS repo only — never run `rtk init -g` (global hook).
#
# Setup:    brew install rtk
#           OR: curl -fsSL https://rtk.sh | sh
#           Set RTK_ENABLED=1 in your environment or export it before running.
# Enable:   RTK_ENABLED=1
# Rollback: RTK_ENABLED=0  (or unset RTK_ENABLED)
#           Remove the PreToolUse hook entry from .claude/settings.local.json
RTK_ENABLED="${RTK_ENABLED:-0}"

# Frontend path patterns — pipe-separated globs used by _matches_frontend_pattern()
# to decide whether a branch touches frontend code (gates E2E verification)
# e.g., "src/components/*|src/pages/*|tests/e2e/*"
FRONTEND_PATH_PATTERNS="${FRONTEND_PATH_PATTERNS:-}"

# Migration path patterns — pipe-separated globs used by _select_deploy_cmd()
# to detect when a branch touches database migrations (schema changes, seeders,
# data fixes).  Matching files promote a Tier-3 backend deploy to Tier 2
# (local build first, then full remote deploy).
# e.g., "migrations/*|db/migrate/*|prisma/migrations/*"
MIGRATION_PATH_PATTERNS="${MIGRATION_PATH_PATTERNS:-}"

# Extra commit paths — pipe-separated globs of additional files that agents
# should stage and commit beyond the files a task explicitly modifies (e.g.,
# generated lockfiles, build manifests, or config snapshots that must travel
# with the change).  Empty by default so nothing extra is staged.
# e.g., "package-lock.json|dist/manifest.json|.claude/config/*.lock"
EXTRA_COMMIT_PATHS="${EXTRA_COMMIT_PATHS:-}"

# Change-aware deploy tiers — _select_deploy_cmd() selects the deploy command
# based on which files changed in the merged commit (first match wins):
#
#   Tier 0  empty diff → DEPLOY_VERIFY_CMD (fail-safe; never downgrade)
#   Tier 1  no apps/backend or packages/ changes →
#           DEPLOY_VERIFY_CMD --health-only  (frontend-only; skip rebuild)
#   Tier 2  backend + MIGRATION_PATH_PATTERNS match →
#           DEPLOY_LOCAL_CMD && DEPLOY_VERIFY_CMD  (local first, then remote)
#           (falls back to DEPLOY_VERIFY_CMD when DEPLOY_LOCAL_CMD unset)
#   Tier 3  backend, no migration, DEPLOY_LOCAL_CMD set →
#           DEPLOY_LOCAL_CMD only  (~5-10 min vs 60-120 min remote deploy)
#           (falls back to DEPLOY_VERIFY_CMD when DEPLOY_LOCAL_CMD unset)
#
# Activate Tier-3 local-only deploys: set DEPLOY_LOCAL_CMD below.
# Promote Tier-3 to Tier-2 on migrations: set MIGRATION_PATH_PATTERNS above.
#
# DEPLOY_LOCAL_CMD — shell command that builds/starts the app locally
# (e.g., "npm run dev", "./scripts/start-local.sh", "docker compose up -d").
# Leave empty to skip local-launch steps entirely.
DEPLOY_LOCAL_CMD="${DEPLOY_LOCAL_CMD:-}"
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

# Project context file — project teams write their patterns, conventions, and
# architecture notes here so that agents have consistent codebase context.
# The orchestrator injects this file into agent prompts when it exists.
PLATFORM_CONTEXT_FILE="${PLATFORM_CONTEXT_FILE:-.claude/config/context.md}"

# Orchestrator iteration limits (override defaults from implement-issue-orchestrator.sh)
MAX_QUALITY_ITERATIONS="${MAX_QUALITY_ITERATIONS:-5}"
MAX_TEST_ITERATIONS="${MAX_TEST_ITERATIONS:-7}"
MAX_PR_REVIEW_ITERATIONS="${MAX_PR_REVIEW_ITERATIONS:-2}"
MAX_VALIDATION_FIX_ITERATIONS="${MAX_VALIDATION_FIX_ITERATIONS:-2}"
MAX_E2E_FIX_ITERATIONS="${MAX_E2E_FIX_ITERATIONS:-2}"
MAX_ORCHESTRATOR_WALL_TIME="${MAX_ORCHESTRATOR_WALL_TIME:-10800}" # seconds (default 3 hours — long-running issues with many tasks or slow test suites can easily exceed 1 hour)
MAX_TASK_WALL_TIME_SECS="${MAX_TASK_WALL_TIME_SECS:-900}"        # seconds per parallel task (default 15 min)
