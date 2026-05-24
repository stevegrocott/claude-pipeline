---
name: pr-review
description: Review a pull request diff against issue requirements and return an approved or changes_requested verdict
inputs:
  - name: diff
    type: string
    required: true
    description: The PR diff to review, provided inline in the prompt
  - name: issue_number
    type: integer
    required: true
    description: GitHub issue number to fetch acceptance criteria and requirements from
outputs:
  - name: verdict
    type: string
    description: Review outcome — approved or changes_requested
  - name: issues
    type: array
    description: List of findings with severity (major or minor) and supporting evidence from the diff
side_effects: []
composes: []
failure_modes:
  - id: review_timeout
    mitigation: Stop exploring the codebase — review only the provided diff; complete in 3-5 turns maximum
  - id: issue_fetch_failed
    mitigation: Stop and report error — cannot review without fetching the requirements
---

# PR Review

Review a pull request diff against the issue requirements. Produce a verdict (approved / changes_requested) with evidence.

## Rules

1. **The diff is provided in the prompt. Do NOT run `git diff`.** Running git diff wastes 2-3 turns and 50K+ tokens re-reading what you already have.
2. **Do NOT read source files** unless the diff references a function whose behavior you cannot determine from the diff context alone. If you must read a file, read only the specific function — never the whole file.
3. **Do NOT explore the repository.** No `ls`, no `find`, no `glob`. The diff and issue description contain everything you need.
4. **Fetch the issue description** to understand the requirements. Use the platform CLI or MCP tool (one call). This is the ONLY external data you should fetch.
5. **Work from the diff, not the codebase.** Review what changed, not what exists.

## Process

```
1. Read the diff (provided inline in the prompt)
2. Fetch the issue description (1 tool call)
3. Spec review: Does the diff achieve the issue goals? Flag scope creep.
4. Code review: Check the diff for quality issues (see checklist)
5. Return structured verdict with evidence
```

**Target: 3-5 turns maximum.** Turn 1: fetch issue. Turns 2-4: analyze and respond.

## Spec Review Criteria

| Check | How to evaluate |
|---|---|
| Goal achievement | Compare diff changes against issue acceptance criteria |
| Completeness | Are all implementation tasks from the issue addressed in the diff? |
| Scope creep | Are there changes unrelated to the issue? Flag as major if they introduce risk |
| Missing files | Does the issue mention files that don't appear in the diff? |

## Multi-PR Issues

When the prompt contains a **Prior Merged PRs** section (injected by the orchestrator), the issue spans multiple pull requests. Apply these rules:

- **An AC is DONE if it is addressed by either this diff OR any PR listed in the Prior Merged PRs section.** Do not flag it as missing.
- Only flag an AC as missing if it is absent from both this diff and all prior merged PRs.
- A prior merged PR "addresses" an AC if its title or the files it touched plausibly cover that requirement.
- Never request changes for ACs already satisfied by prior merged PRs.

## Code Review Checklist

Apply only the items relevant to the technology in the diff. Skip items that don't apply.

**Universal:**
- Input validation at system boundaries (user input, API parameters)
- No hardcoded secrets, credentials, or environment-specific values
- Error handling is appropriate (not swallowing errors silently)
- Language strings used for user-facing text (no hardcoded UI text)

**Database/Backend:**
- No unbounded queries (pagination/limits applied)
- No N+1 query patterns
- Parameterized queries (no SQL injection risk)

**Frontend/JavaScript:**
- No XSS vectors (user content escaped before rendering)
- Event listeners cleaned up (no memory leaks)
- Accessible (aria labels, semantic HTML)

**API Routes:**
- Auth middleware on protected routes
- Response schemas declared
- Input validation on request bodies

**Tests:**
- Assertions check meaningful values (no hollow `expect(true).toBe(true)`)
- Test names describe the behavior being verified
- No test-only methods added to production code

## Severity Guide

| Severity | When to use | Examples |
|---|---|---|
| **major** | Blocks merge — functional bug, security issue, missing feature, scope creep introducing risk | Missing auth check, SQL injection, feature not implemented, unrelated code changes |
| **minor** | Improve but don't block — style, naming, minor inefficiency | Could use const instead of let, missing JSDoc, verbose code |

**Only `major` issues should trigger `changes_requested`.** If all issues are minor, approve with notes.

## Anti-Patterns

| Temptation | Why it wastes time | Do instead |
|---|---|---|
| `git diff` to see changes | Diff is already in the prompt | Read the prompt |
| Read every file touched | You have the diff context | Only read if a function call is opaque |
| Explore repo structure | Irrelevant to reviewing a diff | Focus on the diff |
| Run tests | Not your job — test stage handles this | Review the code |
| Suggest refactors | Review scope, not improvement scope | Only flag bugs and missing requirements |
| Review files not in the diff | Scope creep in your own review | Stick to changed files |

## Why This Skill Exists

Without this skill, review agents explore the full codebase before reviewing the diff they already have. On AGD-52, the PR review timed out twice on Sonnet (360s wasted), escalated to Opus, then requested changes that triggered a $0.98 fix cycle. Total review cost: $1.22 and 17 minutes. With focused review discipline, this should be ~$0.15 and ~2 minutes.
