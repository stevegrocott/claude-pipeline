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
    mitigation: Stop exploring the codebase — review only the provided diff (and the saved full-diff file if named); complete in 3-5 turns maximum
  - id: issue_fetch_failed
    mitigation: Stop and report error — cannot review without fetching the requirements
---

# PR Review

Review a pull request diff against the issue requirements. Produce a verdict (approved / changes_requested) with evidence.

## Rules

1. **The diff is provided in the prompt. Do NOT run `git diff`.** Running git diff wastes 2-3 turns and 50K+ tokens re-reading what you already have.
2. **Do NOT read source files** unless the diff references a function whose behavior you cannot determine from the diff context alone. If you must read a file, read only the specific function — never the whole file.
3. **Do NOT explore the repository.** No `ls`, no `find`, no `glob`. The diff and issue description contain everything you need.
4. **The criteria are in the prompt.** When the prompt has an **Issue Requirements** section (Implementation Tasks and Acceptance Criteria), review against it and do NOT fetch the issue again. Only if that section is absent or reports the criteria as unavailable, fetch the issue description (one platform CLI or MCP call).
5. **If the diff is truncated, the full diff is in the named file.** When the prompt's NOTE names a saved full-diff file, read that file for the remainder (use offsets for large files). Never judge a criterion "missing" from a truncated diff without reading the file.
6. **Never read the remote branch.** The local working tree is the source of truth; the remote branch may be behind local commits. Do not use `gh api`, `git show origin/...`, or any fetch of file contents from the remote branch.
7. **Work from the diff, not the codebase.** Review what changed, not what exists.

## Process

```
1. Read the diff (provided inline in the prompt)
2. Read the criteria from the prompt's Issue Requirements section (fetch the issue only if absent)
3. Spec review: Does the diff achieve the issue goals? Flag scope creep.
4. Code review: Check the diff for quality issues (see checklist)
5. Return structured verdict with evidence
```

**Target: 3-5 turns maximum.** Turn 1: read the saved full diff if the prompt names one. Turns 2-4: analyze and respond.

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
- Mock-timing perf — `performance.now()` threshold inside a `jest.mock`/`vi.mock` file; e.g., `expect(delta).toBeLessThan(200)` where the timed function is mocked — the mock runs in nanoseconds so the threshold is never falsified
- Constant-arithmetic tautology — `expect(<constant expr>).toBe(<constant>)` asserts compile-time arithmetic, not behaviour; e.g., `expect(30000 / 5).toBe(6000)` always passes and verifies nothing about the system under test
- Self-referential matcher — `toBe`/`toEqual` compares the same property from two objects derived from the same source; e.g., `expect(result1.userThreshold).toBe(result2.userThreshold)` when both share the same seed — both could be wrong and the test still passes

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
| Read the remote branch (`gh api`, `origin/...`) | It can be behind local commits and produce phantom findings | Use the prompt diff and the named diff file |
| Explore repo structure | Irrelevant to reviewing a diff | Focus on the diff |
| Run tests | Not your job — test stage handles this | Review the code |
| Suggest refactors | Review scope, not improvement scope | Only flag bugs and missing requirements |
| Review files not in the diff | Scope creep in your own review | Stick to changed files |

## Why This Skill Exists

Without this skill, review agents explore the full codebase before reviewing the diff they already have. On AGD-52, the PR review timed out twice on Sonnet (360s wasted), escalated to Opus, then requested changes that triggered a $0.98 fix cycle. Total review cost: $1.22 and 17 minutes. With focused review discipline, this should be ~$0.15 and ~2 minutes.
