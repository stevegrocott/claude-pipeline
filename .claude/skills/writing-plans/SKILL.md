---
name: writing-plans
description: Use when you have a spec or requirements for a multi-step task, before touching code
---

# Writing Plans

## Overview

Write comprehensive plans assuming the engineer has zero codebase context. Document: files to touch, code snippets, test commands, expected outputs. Bite-sized tasks. DRY. YAGNI. TDD. Frequent commits.

Assume skilled developer, unfamiliar with our toolset/domain, weak on test design.

**Announce:** "I'm using the writing-plans skill to create the implementation plan."

**Save to:** `docs/plans/YYYY-MM-DD-<feature-name>.md`

## Output Modes

**Local file (default):** Save to `docs/plans/YYYY-MM-DD-<feature-name>.md`

**GitHub Issue (`--github`):** Output the plan as a structured GH issue body with parseable task format. Used by the `/explore` skill.

### GitHub Issue Task Format

When outputting for GitHub, use this parseable task list in the `## Implementation Tasks` section:

```markdown
- [ ] `[agent-name]` Task description
```

Agent values should match your project's `.claude/agents/` directory. Common: `[backend-developer]`, `[frontend-developer]`, `[default]`.

## Bite-Sized Task Granularity

**Each step is one action (2-5 minutes):**
- "Write the failing test" - step
- "Run it to make sure it fails" - step
- "Implement the minimal code to make the test pass" - step
- "Run the tests and make sure they pass" - step
- "Commit" - step

## Plan Document Header

**Every plan MUST start with this header:**

```markdown
# [Feature Name] Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use executing-plans to implement this plan task-by-task.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

**Feature Branch:** `issue-XXX-feature-name` ← **CRITICAL: Include this. Subagents need it.**

---
```

**Why the branch is required:** Subagents have no memory of which branch they're on. When you dispatch an implementer, you must tell them the branch name explicitly. Having it in the plan header ensures it's always available.

## Task Structure

```markdown
### Task N: [Component Name]

**Files:**
- Create: `exact/path/to/file.py`
- Modify: `exact/path/to/existing.py:123-145`
- Test: `tests/exact/path/to/test.py`

**Step 1: Write the failing test**

```python
def test_specific_behavior():
    result = function(input)
    assert result == expected
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/path/test.py::test_name -v`
Expected: FAIL with "function not defined"

**Step 3: Write minimal implementation**

```python
def function(input):
    return expected
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/path/test.py::test_name -v`
Expected: PASS

**Step 5: Verify branch and commit**

```bash
# Verify on correct branch first
git branch --show-current  # Should show feature branch, NOT main/test/aw-next

git add tests/path/test.py src/path/file.py
git commit -m "feat: add specific feature"
```
```

## Remember
- Exact file paths, complete code snippets (not "add validation"), exact commands with expected output
- Reference relevant skills with @ syntax
- DRY, YAGNI, TDD, frequent commits

## Execution Handoff

**Local plan:**
"Plan complete and saved to `docs/plans/<filename>.md`. Proceeding with subagent-driven implementation."

**REQUIRED:** Use subagent-driven-development (fresh subagent per task, code review between tasks).

**Alternative:** If user requests, guide to executing-plans skill for parallel session with checkpoints.

**GitHub Issue plan:**
"Plan captured in GitHub Issue #NNN. Ready for implementation."

**Next step:** `/implement-issue NNN main`
