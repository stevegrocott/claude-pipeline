# Implementer Subagent Prompt Template

Use this template when dispatching an implementer subagent.

**CRITICAL:** Always include the feature branch name. Subagents have no memory of branch context.

## Context Minimization

Every token in the subagent prompt is re-read on each tool call the subagent makes. Keep prompts lean:

- **Include ONLY the task description and directly affected file paths** — not the full issue body.
- **Do NOT paste the full issue body** — the subagent can use `.claude/scripts/platform/read-issue.sh` if it needs broader context.
- **Reference specific files and line numbers** rather than "find the relevant code" — this prevents broad exploratory searches.
- **Shorter prompts = fewer input tokens re-read on every tool call** within the subagent session.
- **Truncate build/test output** — use `| tail -10` when running builds or test suites. Use `run_in_background: true` for builds >30s. Full build logs in context are re-read on every subsequent tool call.

**Agent selection:** Choose the appropriate `subagent_type` based on task, using the agents configured in `.claude/agents/` for this project.

```
Task tool (subagent_type: <project-specific agent>):
  description: "Implement Task N: [task name]"
  prompt: |
    You are implementing Task N: [task name]

    ## Task Description

    [FULL TEXT of task from plan - paste it here, don't make subagent read file]

    ## Context

    [Scene-setting: where this fits, dependencies, architectural context]

    ## CRITICAL: Branch Context

    **Feature branch:** [BRANCH_NAME]
    **Working directory:** [DIRECTORY]

    Before ANY work, verify you are on the correct branch:
    ```bash
    git branch --show-current
    ```

    If not on `[BRANCH_NAME]`, switch to it:
    ```bash
    git checkout [BRANCH_NAME]
    ```

    **All commits MUST go to the feature branch, not main/test/aw-next.**

    ## Before You Begin

    If you have questions about:
    - The requirements or acceptance criteria
    - The approach or implementation strategy
    - Dependencies or assumptions
    - Anything unclear in the task description

    **Ask them now.** Raise any concerns before starting work.

    ## Research Tools

    Before implementing, use available tools to understand existing patterns:
    - **Context7:** Framework/library API docs — check before making assumptions about APIs
    - **Serena:** Code structure — understand class hierarchies and method relationships before adding new code
    - **Grep/Glob:** Text search and file discovery

    If a tool is unavailable (call fails), fall back to manual exploration. Do not block on missing tools.

    ## Scope Enforcement

    If the task description includes scope constraint fields, respect them strictly:

    - **`Scope: N files`** — do not modify more than N files. If you find you need to touch more, stop and ask before proceeding.
    - **`Done when: [criterion]`** — stop working as soon as this criterion is met. Do not continue to "clean up" or "improve" beyond it.
    - **`Affected files: [list]`** — read and modify only these files. Do not explore adjacent files or modules unless the task explicitly requires it.

    These constraints exist to prevent context bloat. If a field is absent, apply reasonable defaults: limit exploration to directly relevant files and stop when the stated goal is achieved.

    ## Your Job

    Once you're clear on requirements:
    1. **Verify you're on the feature branch** (see above)
    2. Implement exactly what the task specifies
    3. Write tests (following TDD if task says to)
    4. Run targeted tests before committing (see below)
    5. Verify implementation works
    6. Complete the Pre-Submission Checklist (see below)
    7. Commit your work to the feature branch
    8. Self-review (see below)
    9. Report back

    ### Run Targeted Tests Before Committing

    Before committing, run tests relevant to your changes — not the full suite:
    ```bash
    npm test -- --testPathPattern='relevant-test-file-or-pattern'
    ```
    Replace `relevant-test-file-or-pattern` with the test file or directory that covers your changes.
    If tests fail, fix the failures before proceeding. Do not commit code with failing tests.

    Work from: [directory]

    **While you work:** If you encounter something unexpected or unclear, **ask questions**.
    It's always OK to pause and clarify. Don't guess or make assumptions.

    ## Pre-Submission Checklist

    Before committing, verify ALL of the following:

    - [ ] **Tests pass:** Ran targeted tests (`npm test -- --testPathPattern='...'`) and they pass
    - [ ] **TypeScript compiles:** Ran `npx tsc --noEmit` (or project build) with no errors
    - [ ] **No unrelated changes:** `git diff --stat` shows only files relevant to the task
    - [ ] **All imports are used:** No unused imports left behind (TypeScript compiler will flag these)
    - [ ] **No debug statements:** No `console.log`, `console.debug`, or debugging code left in production files
    - [ ] **Changes match task description:** Re-read the task spec and confirm every requirement is addressed
    - [ ] **No commented-out code:** Removed any commented-out code blocks added during development

    If any item fails, fix it before committing. These items directly correspond to what the code quality reviewer checks — addressing them now avoids revision cycles.

    ## Before Reporting Back: Self-Review

    Review your work with fresh eyes. Ask yourself:

    **Completeness:**
    - Did I fully implement everything in the spec?
    - Did I miss any requirements?
    - Are there edge cases I didn't handle?

    **Quality:**
    - Is this my best work?
    - Are names clear and accurate (match what things do, not how they work)?
    - Is the code clean and maintainable?

    **Discipline:**
    - Did I avoid overbuilding (YAGNI)?
    - Did I only build what was requested?
    - Did I follow existing patterns in the codebase?

    **Testing:**
    - Do tests actually verify behavior (not just mock behavior)?
    - Did I follow TDD if required?
    - Are tests comprehensive?

    If you find issues during self-review, fix them now before reporting.

    ## Report Format

    When done, report:
    - What you implemented
    - What you tested and test results
    - Files changed
    - Self-review findings (if any)
    - Any issues or concerns
```
