---
name: create-session-summary
description: Create Session Summary
---

# Create Session Summary

Save the current session's working state to a file so work can resume after `/clear` or in a new conversation.

**Announce at start:** "Creating session summary for resumption."

## When to Use

- Before suggesting `/clear` to optimize token usage
- At the end of a long session that may continue later
- When switching context to a different task mid-session
- When a skill's context checkpoint triggers (see executing-plans, subagent-driven-development)

## The Process

### Step 1: Gather State

Collect all relevant context:

```bash
# Git state
BRANCH=$(git branch --show-current)
LAST_COMMIT=$(git log --oneline -1)
UNCOMMITTED=$(git status --short)

# Timestamp
TIMESTAMP=$(date +%Y-%m-%d-%H%M)
```

### Step 2: Write Summary File

Write to `.claude/sessions/session-YYYY-MM-DD-HHMM.md`:

```markdown
# Session Summary — YYYY-MM-DD HH:MM

## Active Skill
[Name of the skill that was running, or "manual" if no skill]

## Current Phase
[Which step/phase within the skill, e.g., "executing-plans Step 3: batch 2 of 4 complete"]

## Git State
- **Branch:** `feature/issue-NNN`
- **Last commit:** `abc1234 feat: description`
- **Uncommitted changes:** [yes/no — list if yes]

## Key Decisions Made
- [Decision 1 and rationale]
- [Decision 2 and rationale]

## Remaining Work
- [ ] Task/step still pending
- [ ] Task/step still pending

## Files Modified This Session
- `path/to/file.ts` — [what was changed]
- `path/to/other.ts` — [what was changed]

## Context for Resumption
[Any additional context needed to pick up where you left off — error states, blockers, pending questions, relevant findings]
```

### Step 3: Confirm and Suggest

After writing the file:

1. Print the file path
2. Suggest: "Session saved. You can run `/clear` to free context, then `/resume-session .claude/sessions/session-TIMESTAMP.md` to continue."

## File Location

All session files go in `.claude/sessions/`. Create the directory if it doesn't exist:

```bash
mkdir -p .claude/sessions
```

**Naming convention:** `session-YYYY-MM-DD-HHMM.md`

## Key Principles

- **Capture everything needed to resume** — the reader has zero context
- **Be specific** — "Task 3 of 7" not "partway through"
- **Include git state** — branch and commit are essential for resumption
- **List remaining work explicitly** — don't assume the reader remembers the plan
- **Keep it concise** — this is a handoff document, not a narrative

## Integration

**Called by:** Any skill at a context checkpoint, or user directly via `/create-session-summary`
**Followed by:** `/clear` (optional) then `/resume-session`
