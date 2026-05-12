---
name: resume-session
description: Resume Previous Session
argument-hint: "[session-file-path]"
inputs:
  - name: session_file_path
    type: file_path
    required: false
    description: Path to session summary file; defaults to the most recent file in .claude/sessions/ if omitted
outputs: []
side_effects:
  - may_checkout_git_branch: switches to the branch recorded in the session file if it differs from the current branch
composes: []
failure_modes:
  - id: session_file_not_found
    mitigation: list available files in .claude/sessions/ and ask the user to pick one; if none exist, inform user and stop
  - id: branch_mismatch
    mitigation: inform the user of the discrepancy and offer to checkout the session branch or proceed on the current branch
  - id: malformed_session_file
    mitigation: show the raw file contents and ask the user for guidance; do not attempt to infer missing sections
  - id: no_session_files
    mitigation: inform the user that no session files exist in .claude/sessions/ and suggest running /create-session-summary first
---

# Resume Session

Reload context from a session summary file and continue where you left off.

**Announce at start:** "Resuming session from $FILE_PATH"

**Arguments:**
- `$1` — Path to session summary file (required), e.g., `.claude/sessions/session-2026-02-20-1430.md`

## The Process

### Step 1: Read Session File

```bash
cat "$SESSION_FILE"
```

If no argument provided, find the most recent session file:

```bash
ls -t .claude/sessions/session-*.md 2>/dev/null | head -1
```

If no session files exist, stop and inform the user.

### Step 2: Verify Git State

Check that the current git state matches what's in the session file:

```bash
CURRENT_BRANCH=$(git branch --show-current)
# Compare against branch listed in session file
```

**If branch doesn't match:**
- Inform user: "Session was on branch `X` but you're on `Y`."
- Offer to checkout the correct branch
- If there are uncommitted changes, warn before switching

**If branch matches:** Proceed.

### Step 3: Verify Last Commit

```bash
git log --oneline -1
# Compare against last commit in session file
```

**If commits diverged** (new commits since session was saved):
- Show what changed: `git log --oneline SESSION_COMMIT..HEAD`
- Inform user but proceed — the new commits may be intentional

### Step 4: Restore Context

Read the session file sections and internalize:

1. **Active Skill** — If a skill was running, announce: "Resuming `skill-name` at `phase`."
2. **Remaining Work** — Load the pending tasks as your current work items
3. **Key Decisions** — Note these so you don't re-decide them
4. **Context for Resumption** — Apply any special context (blockers, error states, etc.)

### Step 5: Continue Work

Based on the Active Skill:

- **If a skill was active:** Resume that skill at the noted phase. Don't restart from the beginning.
- **If "manual":** Present the remaining work items and ask what to work on next.
- **If remaining work is empty:** Inform user the previous session appears complete.

## Edge Cases

| Situation | Action |
|-----------|--------|
| Session file not found | Stop, show available sessions in `.claude/sessions/` |
| Branch doesn't exist locally | Offer to fetch and checkout |
| Session file is empty or malformed | Stop, show file contents, ask user for guidance |
| No remaining work | Inform user, ask if there's new work |
| Multiple session files match | Show list, ask user to pick |

## Key Principles

- **Verify before acting** — always confirm git state matches before resuming work
- **Don't re-decide** — honor decisions listed in the session file
- **Don't restart skills** — resume at the noted phase, not from step 1
- **Be transparent** — if state doesn't match, explain the discrepancy clearly

## Integration

**Preceded by:** `/create-session-summary` then `/clear`
**Calls:** Whatever skill was active in the session (if any)
