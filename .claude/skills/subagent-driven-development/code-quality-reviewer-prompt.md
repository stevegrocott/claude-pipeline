# Code Quality Reviewer Prompt Template

Use this template when dispatching a code quality reviewer subagent.

**Purpose:** Verify implementation is well-built (clean, tested, maintainable)

**Only dispatch after spec compliance review passes.**

```
Task tool (code-reviewer):
  Use template at requesting-code-review/code-reviewer.md

  WHAT_WAS_IMPLEMENTED: [from implementer's report]
  PLAN_OR_REQUIREMENTS: Task N from [plan-file]
  BASE_SHA: [commit before task]
  HEAD_SHA: [current commit]
  DESCRIPTION: [task summary]
```

## Style vs Correctness Filter

When reviewing, apply this filter to every potential issue before reporting it:

1. **Only flag issues that affect correctness, performance, or security.** These are the things that matter: bugs, logic errors, missing error handling, type safety gaps, security vulnerabilities, performance regressions, and missing test coverage.

2. **Explicitly skip style-only feedback.** Do NOT flag:
   - Variable/function naming preferences (unless genuinely misleading)
   - Formatting or whitespace opinions
   - Comment style or quantity (unless documentation is completely absent for public APIs)
   - Minor code organization preferences that don't affect maintainability
   - Subjective "I would have done it differently" suggestions

3. **Approve if all functional criteria pass.** If the code is correct, tested, type-safe, and handles errors properly, approve it — even if the style is not exactly how you would write it. Style-only feedback wastes iteration cycles and does not improve the product.

**Code reviewer returns:** Strengths, Issues (Critical/Important/Minor), Assessment
