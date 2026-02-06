# Implementer Subagent Prompt Template

Use this template when dispatching an implementer subagent.

**CRITICAL:** Always include the feature branch name. Subagents have no memory of branch context.

**Agent selection:** Choose the appropriate `subagent_type` based on task:
- `laravel-backend-developer` — Backend tasks (PHP, Laravel, APIs, database)
- `bulletproof-frontend-developer` — Frontend tasks (CSS, HTML, Blade, JS, accessibility)

```
Task tool (subagent_type: laravel-backend-developer OR bulletproof-frontend-developer):
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

    ## Your Job

    Once you're clear on requirements:
    1. **Verify you're on the feature branch** (see above)
    2. Implement exactly what the task specifies
    3. Write tests (following TDD if task says to)
    4. Verify implementation works
    5. Commit your work to the feature branch
    6. Self-review (see below)
    7. Report back

    Work from: [directory]

    **While you work:** If you encounter something unexpected or unclear, **ask questions**.
    It's always OK to pause and clarify. Don't guess or make assumptions.

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
