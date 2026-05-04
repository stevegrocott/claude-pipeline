---
name: complete-summary
description: Generate a structured completion summary for a PR comment using only the issue number, branch name, PR number, and prompt context — no file exploration
inputs:
  - name: issue_number
    type: string
    required: true
    description: GitHub issue number being closed by this PR
  - name: branch_name
    type: string
    required: true
    description: Feature branch name that was implemented
  - name: pr_number
    type: string
    required: true
    description: Pull request number to reference in the summary
outputs:
  - name: pr_comment
    type: string
    description: Formatted PR comment text ready to post, following the standard Implementation Complete template
side_effects: []
composes: []
failure_modes:
  - id: missing_context
    mitigation: request the missing issue_number, branch_name, or pr_number from the caller before generating output; do not guess or explore
---

# Complete Summary

Generate a structured completion summary for a PR comment. Fill in the template from data already available — do not explore.

## Rules

1. **Do NOT read source files.** The implementation is done. You don't need to understand the code.
2. **Do NOT run `git log`, `git diff`, or `git show`.** The diff is already reviewed. The PR already exists.
3. **Do NOT explore the repository.** No `ls`, no `find`, no `glob`.
4. **Fill in the template below** using only: the issue number, branch name, PR number, and any context provided in the prompt.
5. **Keep it concise.** 10-15 lines maximum. This is a PR comment, not a report.

## Template

```
## Implementation Complete
###### *Posted by `implement-issue-orchestrator`*

---
Issue #ISSUE has been implemented!

**Branch:** `BRANCH_NAME`
**PR:** #PR_NUMBER

### Changes
- [1-3 bullet points summarizing what was implemented, derived from the issue title/description]

### Quality Gates
- Tests: [passed/skipped/failed]
- Code review: [approved/changes requested + fixed]

---
*This PR is ready for human review and merge.*
```

## Process

```
1. Read the issue number, branch, and PR number from the prompt
2. Write a 1-3 bullet summary of what was implemented (from the issue title)
3. Note test and review outcomes if mentioned in the prompt
4. Output the completed template
```

**Target: 1-2 turns maximum.** Read prompt, produce output. Done.

## Why This Skill Exists

Without this skill, the complete stage agent reads files, runs git commands, and explores the repo to understand "what decisions were made" — wasting turns on a task that should take 10 seconds. The information needed is already in the prompt context.
